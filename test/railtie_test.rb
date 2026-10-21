# frozen_string_literal: true

require 'test_helper'

begin
  require 'rails'
  require 'action_controller/railtie'
  require 'active_job/railtie'
rescue LoadError
  # Rails is optional for the gem; run `bundle exec rake test` to include this test.
end

if defined?(Rails::Application)
  ENV['WATCH_ENVIRONMENT'] = 'production' # the Railtie would otherwise use Rails.env
  require 'watch_client/railtie'

  # One small Rails app for the whole file (Rails apps can only boot once per process).
  module WatchDummy
    HUB = FakeHub.new

    # Stands in for a Redis-backed middleware in front of Rails' error pages (a session or
    # rate-limit store) when Redis is down.
    class RedisBackedMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        raise IOError, 'Error connecting to Redis on 127.0.0.1:6379 (Errno::ECONNREFUSED)' if env['PATH_INFO'] == '/redis-down'

        @app.call(env)
      end
    end

    class Application < Rails::Application
      config.root = File.expand_path('../tmp/dummy', __dir__)
      config.eager_load = false
      config.logger = ActiveSupport::Logger.new(StringIO.new)
      config.log_level = :debug
      config.secret_key_base = 'x' * 64
      config.hosts.clear
      config.active_job.queue_adapter = :inline
      config.filter_parameters += %i[password token]
      config.consider_all_requests_local = true
      config.action_dispatch.show_exceptions = :none
      config.middleware.insert_before 0, WatchDummy::RedisBackedMiddleware # in front of Rails' executor

      routes.append do
        get '/hello' => 'watch_dummy/hello#show'
        get '/boom' => 'watch_dummy/hello#boom'
      end
    end

    class HelloController < ActionController::Base
      def show
        logger.info('inside the action')
        GreetJob.perform_later('Ada')
        render plain: 'hi'
      end

      def boom
        raise 'kaboom'
      end
    end

    class GreetJob < ActiveJob::Base
      def perform(name)
        logger.info("greeting #{name}")
      end
    end

    class FailJob < ActiveJob::Base
      def perform
        raise ArgumentError, 'job failed'
      end
    end
  end

  def configure_dummy_hub
    WatchClient.reset!
    WatchClient.configure do |c|
      c.url = WatchDummy::HUB.url
      c.api_key = 'lh_test_key'
      c.environment = 'production'
      c.flush_interval = 60
      c.diagnostics = StringIO.new
      c.current_user_id = -> { 'u-1' }
    end
  end

  configure_dummy_hub
  WatchDummy::Application.initialize!
  FILTER_KEYS_AFTER_BOOT = WatchClient.configuration.filter_keys

  class RailtieTest < Minitest::Test
    # Other test files reset the global configuration, so set it up again.
    def setup
      configure_dummy_hub
    end

    def app
      WatchDummy::Application
    end

    def requests_after(path)
      env = Rack::MockRequest.env_for(path, 'HTTP_X_REQUEST_ID' => 'incoming-req-1',
                                            'HTTP_X_FORWARDED_FOR' => '198.51.100.7')
      begin
        _status, _headers, body = app.call(env)
        # Closing the body ends the Rails executor run, like a real server does.
        body.close if body.respond_to?(:close)
      rescue StandardError
        nil
      end
      collect_requests
    end

    def collect_requests
      WatchClient.flush
      collected = []
      while (request = WatchDummy::HUB.next_request(timeout: 0.5))
        collected << request
      end
      collected
    end

    def entries_after(path)
      requests_after(path).flat_map(&:entries)
    end

    def test_unhandled_request_errors_are_reported_once_with_request_details
      notices = requests_after('/boom?token=secret').flat_map(&:errors)
      assert_equal 1, notices.size, "expected exactly one notice, got #{notices.map { |n| n['exception_class'] }}"
      notice = notices.first
      assert_equal 'RuntimeError', notice['exception_class']
      assert_equal 'kaboom', notice['message']
      assert_equal false, notice['handled']
      assert_equal 'incoming-req-1', notice['request_id']
      assert_equal 'WatchDummy::HelloController#boom', notice['component']
      assert_equal 'GET', notice['request']['method']
      assert_includes notice['request']['url'], '/boom'
      refute_includes notice['request']['url'], 'secret'

      # Richer details (0.3.0)
      assert_includes notice['breadcrumbs'].map { |c| c['message'] }, 'WatchDummy::HelloController#boom'
      assert_equal 'GET', notice['cgi_env']['REQUEST_METHOD']
      assert_equal 'incoming-req-1', notice['cgi_env']['HTTP_X_REQUEST_ID']
      # The visitor's IP is sent once (remote_ip), not again in forwarding headers.
      assert_equal '[FILTERED]', notice['cgi_env']['HTTP_X_FORWARDED_FOR']
      assert_equal 'watch_client', notice['notifier']['name']
      assert notice['app_env']['rails_version']
    end

    def test_errors_from_middleware_in_front_of_rails_error_handling_are_reported
      assert_equal WatchClient::OuterMiddleware, app.middleware.first.klass, 'runs in front of every other middleware'
      notices = requests_after('/redis-down').flat_map(&:errors)
      assert_equal 1, notices.size
      assert_equal 'IOError', notices.first['exception_class']
      assert_equal false, notices.first['handled']
    end

    def test_errors_rails_handles_itself_like_a_failing_redis_cache_are_reported
      # What Rails' Redis cache store does when Redis is down: it keeps the app running and
      # reports the error as handled, with severity warning.
      Rails.error.report(IOError.new('Redis cache unreachable'), handled: true, severity: :warning,
                                                                 source: 'redis_cache_store.active_support')
      notice = collect_requests.flat_map(&:errors).find { |n| n['message'] == 'Redis cache unreachable' }
      refute_nil notice
      assert_equal true, notice['handled']
      assert_equal 'warning', notice['context']['severity']
    end

    def test_job_errors_are_reported_through_rails_error
      begin
        WatchDummy::FailJob.perform_later
      rescue ArgumentError
        nil
      end
      notice = collect_requests.flat_map(&:errors).find { |n| n['exception_class'] == 'ArgumentError' }
      refute_nil notice
      assert_equal 'WatchDummy::FailJob', notice['component']
      assert notice['context']['job_id']
    end

    def test_handled_errors_reported_with_rails_error_handle
      Rails.error.handle(context: { order_id: 5 }) { raise KeyError, 'handled one' }
      notice = collect_requests.flat_map(&:errors).find { |n| n['message'] == 'handled one' }
      refute_nil notice
      assert_equal true, notice['handled']
      assert_equal 5, notice['context']['order_id']
    end

    def test_rails_logger_lines_reach_the_hub_with_request_id_and_user
      entries = entries_after('/hello')
      line = entries.find { |e| e['message'] == 'inside the action' }
      refute_nil line, "expected the controller's log line; got #{entries.map { |e| e['message'] }}"
      assert_equal 'incoming-req-1', line['request_id']
      assert_equal 'u-1', line['user_id']
    end

    def test_request_summary_line
      summary = entries_after('/hello').find { |e| e['event'] == 'request' }
      refute_nil summary
      assert_equal 'GET', summary['method']
      assert_equal 200, summary['status']
      assert_equal 'WatchDummy::HelloController', summary['controller']
      assert_match(%r{\AGET /hello 200 in \d+ms}, summary['message'])
    end

    def test_server_errors_are_logged_as_errors
      summary = entries_after('/boom').find { |e| e['event'] == 'request' }
      refute_nil summary
      assert_equal 'error', summary['level']
      assert_equal 500, summary['status']
    end

    def test_jobs_carry_the_request_id_and_job_fields
      line = entries_after('/hello').find { |e| e['message'] == 'greeting Ada' }
      refute_nil line
      assert_equal 'incoming-req-1', line['request_id']
      assert_equal 'WatchDummy::GreetJob', line['job_class']
      assert line['job_id']
    end

    def test_uses_the_apps_filter_parameters
      assert_includes FILTER_KEYS_AFTER_BOOT, :password
      assert_includes FILTER_KEYS_AFTER_BOOT, :iban # the gem's own floor is always added
    end
  end
end
