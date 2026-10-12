require "test_helper"
require "watch_client/error_subscriber"
require "watch_client/sidekiq"

class NotifyTest < Minitest::Test
  include WatchTestHelpers

  class PaymentError < StandardError; end

  def setup
    @hub = FakeHub.new
    configure_for(@hub, app_root: "/srv/app")
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def raise_error(klass = PaymentError, message = "card declined")
    raise klass, message
  rescue klass => e
    e.set_backtrace([
      "/srv/app/app/models/payment.rb:12:in 'charge'",
      "/srv/app/vendor/bundle/ruby/3.4.0/gems/stripe-12.0.0/lib/stripe.rb:5:in 'request'",
      "/srv/app/app/controllers/payments_controller.rb:8:in 'create'"
    ])
    e
  end

  def next_notice
    WatchClient.flush
    request = @hub.next_request
    refute_nil request, "expected a request to the hub"
    assert_equal "/api/v1/errors", request.path
    body = JSON.parse(Zlib.gunzip(request.body))
    body.fetch("errors").first
  end

  def test_notify_sends_a_notice_with_relative_app_frames
    assert WatchClient.notify(raise_error, context: { order_id: 7 })

    notice = next_notice
    assert_equal "NotifyTest::PaymentError", notice["exception_class"]
    assert_equal "card declined", notice["message"]
    assert_equal "app/models/payment.rb:12:in 'charge'", notice["backtrace"][0]
    assert_match(%r{\A/srv/app/vendor/bundle}, notice["backtrace"][1], "gem frames stay absolute")
    assert_equal true, notice["handled"]
    assert_equal "production", notice["environment"]
    assert_equal "abc123", notice["app_version"]
    assert_equal({ "order_id" => 7 }, notice["context"])
  end

  def test_same_exception_object_is_reported_once
    error = raise_error
    assert WatchClient.notify(error)
    refute WatchClient.notify(error)
  end

  def test_ignored_classes_and_subclasses_are_skipped
    WatchClient.configuration.ignore_errors = [ "NotifyTest::PaymentError" ]
    refute WatchClient.notify(raise_error)

    subclass = Class.new(PaymentError)
    refute WatchClient.notify(raise_error(subclass))
  end

  def test_includes_request_id_and_job_context_saved_on_the_exception
    error = nil
    WatchClient.with_context(request_id: "req-1", job_id: "j-1", job_class: "ChargeJob") do
      error = raise_error
      WatchClient::Notice.attach_context(error)
    end
    # Reported after the job's context has ended, like Rails.error does.
    WatchClient.notify(error, handled: false)

    notice = next_notice
    assert_equal "req-1", notice["request_id"]
    assert_equal "ChargeJob", notice["component"]
    assert_equal false, notice["handled"]
    assert_equal "j-1", notice["context"]["job_id"]
  end

  def test_causes_are_included
    error = begin
      begin
        raise KeyError, "missing :amount"
      rescue KeyError
        raise PaymentError, "could not charge"
      end
    rescue PaymentError => e
      e
    end
    WatchClient.notify(error)

    causes = next_notice["causes"]
    assert_equal "KeyError", causes.first["exception_class"]
    assert_equal "missing :amount", causes.first["message"]
  end

  def test_custom_fingerprint_and_before_notify
    WatchClient.configuration.before_notify = ->(notice, _exception) { notice.merge("context" => { "patched" => true }) }
    WatchClient.notify(raise_error, fingerprint: "stripe-declines")

    notice = next_notice
    assert_equal "stripe-declines", notice["fingerprint"]
    assert_equal({ "patched" => true }, notice["context"])
  end

  def test_before_notify_can_drop
    WatchClient.configuration.before_notify = ->(_notice, _exception) { nil }
    refute WatchClient.notify(raise_error)
  end

  def test_masks_filtered_keys_in_context
    WatchClient.configuration.filter_keys = [ :token ]
    WatchClient.notify(raise_error, context: { api_token: "secret", order_id: 1 })
    assert_equal({ "api_token" => "[FILTERED]", "order_id" => 1 }, next_notice["context"])
  end

  def test_disabled_or_send_errors_off_sends_nothing
    WatchClient.configuration.send_errors = false
    refute WatchClient.notify(raise_error)
    WatchClient.configuration.send_errors = true
    WatchClient.configuration.enabled = false
    refute WatchClient.notify(raise_error)
  end

  def test_rails_error_subscriber
    subscriber = WatchClient::ErrorSubscriber.new
    subscriber.report(raise_error, handled: false, severity: :error, context: { tenant: "acme", record: Object.new },
                                   source: "application.active_job")

    notice = next_notice
    assert_equal false, notice["handled"]
    assert_equal "acme", notice["context"]["tenant"]
    assert_equal "application.active_job", notice["context"]["source"]
    assert_kind_of String, notice["context"]["record"]
  end

  def test_rails_error_subscriber_can_skip_handled_errors
    WatchClient.configuration.report_handled_errors = false
    WatchClient::ErrorSubscriber.new.report(raise_error, handled: true)
    WatchClient.flush
    assert_nil @hub.next_request(timeout: 0.3)
  end

  def test_sidekiq_error_handler
    job = { "class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "ChargeJob", "jid" => "abc", "queue" => "default",
            "retry_count" => 2, "watch_request_id" => "req-5" }
    WatchClient::SidekiqIntegration::ErrorHandler.call(raise_error, { job: job })

    notice = next_notice
    assert_equal "ChargeJob", notice["component"]
    assert_equal "req-5", notice["request_id"]
    assert_equal 2, notice["context"]["sidekiq"]["retry_count"]
  end

  def test_rack_middleware_keeps_request_context_on_errors
    require "watch_client/rack_middleware"
    app = ->(_env) { raise PaymentError, "boom" }
    error = assert_raises(PaymentError) do
      WatchClient::RackMiddleware.new(app).call("action_dispatch.request_id" => "req-77")
    end
    WatchClient.notify(error, handled: false)
    assert_equal "req-77", next_notice["request_id"]
  end

  def test_notify_deploy
    assert WatchClient.notify_deploy(version: "a1b2c3", deployed_by: "ferdinand")
    request = @hub.next_request
    assert_equal "/api/v1/deploys", request.path
    body = JSON.parse(Zlib.gunzip(request.body))
    assert_equal "a1b2c3", body["version"]
    assert_equal "ferdinand", body["deployed_by"]
    assert_equal "production", body["environment"]
  end
end
