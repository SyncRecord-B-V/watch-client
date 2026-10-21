# frozen_string_literal: true

require 'test_helper'
require 'watch_client/crash_reporter'
require 'watch_client/outer_middleware'
require 'watch_client/rake_reporting'

# Errors that never pass through Rails' error reporter: a crashing process, middleware in front of
# Rails' error handling (a Redis-backed store that can't connect), and rake tasks.
class CrashAndRakeTest < Minitest::Test
  include WatchTestHelpers

  class RedisDown < StandardError; end

  def setup
    @hub = FakeHub.new
    configure_for(@hub, app_root: '/srv/app')
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def notice
    WatchClient.flush
    request = @hub.next_request
    refute_nil request, 'expected a request to the hub'
    assert_equal '/api/v1/errors', request.path
    request.errors.first
  end

  def rack_env(path, query = '')
    { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => path, 'QUERY_STRING' => query, 'rack.input' => StringIO.new }
  end

  def failure
    raise RedisDown, 'Connection refused - connect(2) for 127.0.0.1:6379'
  rescue RedisDown => e
    e
  end

  def test_a_crash_that_ends_the_process_is_reported
    assert WatchClient::CrashReporter.report(failure)

    sent = notice
    assert_equal 'CrashAndRakeTest::RedisDown', sent['exception_class']
    assert_equal false, sent['handled']
    assert_equal true, sent.dig('context', 'process_crash')
  end

  def test_an_exit_that_carries_the_real_error_reports_that_error
    # `rescue => e; warn e; exit 1`, like bin/sidekiq when Redis is down at start.
    exit_error = begin
      begin
        raise failure
      rescue RedisDown
        exit 1
      end
    rescue SystemExit => e
      e
    end
    assert WatchClient::CrashReporter.report(exit_error)
    assert_equal 'CrashAndRakeTest::RedisDown', notice['exception_class']
  end

  def test_shutdown_during_a_retry_wait_still_sends_the_error
    @hub.respond_with(503, 202)
    assert WatchClient.notify(failure, handled: false)
    first = @hub.next_request # the 503: the worker now waits about a second before retrying
    refute_nil first
    sleep 0.1

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    WatchClient.error_client.shutdown(timeout: 3)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9, 'shutdown woke the waiting worker'
    retried = @hub.next_request
    refute_nil retried, 'the error was sent by shutdown'
    assert_equal 'CrashAndRakeTest::RedisDown', retried.errors.first['exception_class']
  end

  def test_normal_exits_and_signals_are_not_errors
    refute WatchClient::CrashReporter.report(SystemExit.new(1))
    refute WatchClient::CrashReporter.report(SignalException.new('TERM'))
    refute WatchClient::CrashReporter.report(nil)
  end

  def test_errors_from_middleware_in_front_of_rails_are_reported_and_raised_again
    app = WatchClient::OuterMiddleware.new(->(_env) { raise failure })
    raised = assert_raises(RedisDown) { app.call(rack_env('/orders', 'page=2')) }
    assert_equal 'Connection refused - connect(2) for 127.0.0.1:6379', raised.message

    assert_equal 'CrashAndRakeTest::RedisDown', notice['exception_class']
  end

  def test_an_error_already_reported_by_rails_is_not_sent_twice
    error = failure
    assert WatchClient.notify(error, handled: false)
    app = WatchClient::OuterMiddleware.new(->(_env) { raise error })
    assert_raises(RedisDown) { app.call(rack_env('/')) }

    WatchClient.flush
    first = @hub.next_request
    assert_equal 1, first.errors.size
    assert_nil @hub.next_request(timeout: 0.3)
  end

  def test_a_failing_rake_task_is_reported_right_away
    assert WatchClient::RakeReporting.report(failure, ['invoices:send'])

    request = @hub.next_request # sent by report itself, no flush needed
    refute_nil request
    sent = request.errors.first
    assert_equal 'rake invoices:send', sent['component']
    assert_equal ['invoices:send'], sent.dig('context', 'rake_tasks')
  end

  def test_rake_reporting_hooks_into_rakes_error_output
    WatchClient::RakeReporting.install!
    $stderr = StringIO.new
    rake = Rake::Application.new
    rake.instance_variable_set(:@top_level_tasks, ['db:seed'])
    rake.options.trace_output = $stderr
    rake.display_error_message(failure)
    assert_match(/Connection refused/, $stderr.string, 'rake still prints the error')

    assert_equal 'rake db:seed', @hub.next_request.errors.first['component']
  ensure
    $stderr = STDERR
  end
end
