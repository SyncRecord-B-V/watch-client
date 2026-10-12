require "test_helper"

class ContextTest < Minitest::Test
  include WatchTestHelpers

  def teardown
    SyncRecordWatch.reset!
  end

  def test_nested_context_merges_and_restores
    SyncRecordWatch.with_context(request_id: "r1") do
      SyncRecordWatch.with_context(tenant: "acme") do
        assert_equal({ request_id: "r1", tenant: "acme" }, SyncRecordWatch::Context.current)
      end
      assert_equal({ request_id: "r1" }, SyncRecordWatch::Context.current)
    end
    assert_equal({}, SyncRecordWatch::Context.current)
  end

  def test_context_is_per_thread
    SyncRecordWatch.with_context(request_id: "main") do
      other = Thread.new { SyncRecordWatch::Context.request_id }.value
      assert_nil other
    end
  end

  def test_rack_middleware_sets_request_id
    require "syncrecord_watch/rack_middleware"
    seen = nil
    app = ->(_env) { seen = SyncRecordWatch::Context.request_id; [ 200, {}, [ "ok" ] ] }
    SyncRecordWatch::RackMiddleware.new(app).call("action_dispatch.request_id" => "req-9")
    assert_equal "req-9", seen
    assert_nil SyncRecordWatch::Context.request_id
  end

  def test_net_http_gets_request_id_header_inside_a_request
    hub = FakeHub.new
    configure_for(hub)
    SyncRecordWatch::NetHTTPPropagation.install!
    uri = URI("#{hub.url}/anything")

    SyncRecordWatch.with_context(request_id: "req-42") { Net::HTTP.get_response(uri) }
    assert_equal "req-42", hub.next_request.headers["x-request-id"]

    Net::HTTP.get_response(uri)
    assert_nil hub.next_request.headers["x-request-id"]
  ensure
    hub&.stop
  end

  def test_propagation_respects_host_allowlist
    SyncRecordWatch.configuration.propagate_to = [ /\.example\.com\z/ ]
    assert SyncRecordWatch::NetHTTPPropagation.propagate?("api.example.com")
    refute SyncRecordWatch::NetHTTPPropagation.propagate?("api.stripe.com")
  end

  def test_delivery_requests_never_carry_the_request_id
    hub = FakeHub.new
    configure_for(hub)
    SyncRecordWatch::NetHTTPPropagation.install!
    SyncRecordWatch.with_context(request_id: "req-7") do
      SyncRecordWatch.logger.info("inside request")
      SyncRecordWatch.flush
    end
    request = hub.next_request
    assert_nil request.headers["x-request-id"]
    assert_equal "req-7", request.entries.first["request_id"]
  ensure
    hub&.stop
  end
end
