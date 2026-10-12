require "test_helper"

class CheckInTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    configure_for(@hub)
  end

  def teardown
    SyncRecordWatch.reset!
    @hub.stop
  end

  def test_pings_the_token_url
    assert SyncRecordWatch.check_in("tok_abc123", message: "exported 12")
    request = @hub.next_request
    assert_equal "POST", request.method
    assert_equal "/ping/tok_abc123", request.path
    assert_equal "exported 12", request.body
  end

  def test_full_url_is_used_as_is
    assert SyncRecordWatch.check_in("#{@hub.url}/ping/other_token")
    assert_equal "/ping/other_token", @hub.next_request.path
  end

  def test_block_pings_after_success_and_returns_the_result
    assert_equal 42, SyncRecordWatch.check_in("tok_abc123") { 42 }
    assert_equal "/ping/tok_abc123", @hub.next_request.path
  end

  def test_block_reports_failure_and_reraises
    error = assert_raises(RuntimeError) { SyncRecordWatch.check_in("tok_abc123") { raise "disk full" } }
    assert_equal "disk full", error.message
    request = @hub.next_request
    assert_equal "/ping/tok_abc123/fail", request.path
    assert_equal "RuntimeError: disk full", request.body
  end

  def test_returns_false_on_http_error_without_raising
    @hub.respond_with(404)
    refute SyncRecordWatch.check_in("unknown_token")
    assert_includes SyncRecordWatch.configuration.diagnostics.string, "HTTP 404"
  end

  def test_unreachable_hub_returns_false
    SyncRecordWatch.configuration.url = "http://127.0.0.1:1"
    refute SyncRecordWatch.check_in("tok_abc123")
  end

  def test_off_in_test_environment
    SyncRecordWatch.configuration.environment = "test"
    refute SyncRecordWatch.check_in("tok_abc123")
    assert_nil @hub.next_request(timeout: 0.2)
  end

  def test_token_needs_a_configured_url
    SyncRecordWatch.configuration.url = nil
    refute SyncRecordWatch.check_in("tok_abc123")
  end
end
