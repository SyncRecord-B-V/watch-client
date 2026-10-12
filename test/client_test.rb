require "test_helper"

class ClientTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    configure_for(@hub)
  end

  def teardown
    SyncRecordWatch.reset!
    @hub.stop
  end

  def test_sends_batches_as_gzip_json_with_api_key
    SyncRecordWatch.logger.info("Hello from the test")
    SyncRecordWatch.logger.error("Something broke")

    request = @hub.next_request
    refute_nil request, "expected a request to the hub"
    assert_equal "POST", request.method
    assert_equal "/api/v1/logs", request.path
    assert_equal "Bearer lh_test_key", request.headers["authorization"]
    assert_equal "gzip", request.headers["content-encoding"]
    assert_match(/\Asyncrecord_watch\//, request.headers["user-agent"])

    entries = request.entries
    entries += @hub.next_request(timeout: 0.5)&.entries.to_a if entries.size < 2
    assert_equal [ "Hello from the test", "Something broke" ], entries.map { |e| e["message"] }
    assert_equal %w[info error], entries.map { |e| e["level"] }
    first = entries.first
    assert_equal "production", first["environment"]
    assert_equal "web-1", first["host"]
    assert_equal "abc123", first["app_version"]
    assert first["timestamp"]
  end

  def test_skips_lines_below_min_level
    SyncRecordWatch.configuration.min_level = :warn
    SyncRecordWatch.logger.info("not sent")
    SyncRecordWatch.logger.warn("sent")

    assert_equal [ "sent" ], @hub.next_request.entries.map { |e| e["message"] }
  end

  def test_does_nothing_when_disabled
    SyncRecordWatch.configuration.enabled = false
    SyncRecordWatch.logger.error("nope")
    assert_nil @hub.next_request(timeout: 0.3)
    assert_empty SyncRecordWatch.stats
  end

  def test_retries_server_errors_then_succeeds
    SyncRecordWatch.configuration.max_retries = 2
    @hub.respond_with(503)
    SyncRecordWatch.logger.info("retry me")

    first = @hub.next_request
    second = @hub.next_request(timeout: 4)
    assert_equal [ "retry me" ], first.entries.map { |e| e["message"] }
    assert_equal [ "retry me" ], second.entries.map { |e| e["message"] }
    wait_until { SyncRecordWatch.stats[:sent] == 1 }
    assert_equal 1, SyncRecordWatch.stats[:retries]
  end

  def test_drops_batch_on_client_errors_without_retrying
    @hub.respond_with(401)
    SyncRecordWatch.logger.info("bad key")

    refute_nil @hub.next_request
    wait_until { SyncRecordWatch.stats[:dropped_delivery] == 1 }
    assert_nil @hub.next_request(timeout: 0.3)
    assert_match(/dropped 1 entries: HTTP 401/, SyncRecordWatch.configuration.diagnostics.string)
  end

  def test_caps_the_buffer_and_drops_oldest
    SyncRecordWatch.configuration.max_queue = 3
    SyncRecordWatch.configuration.flush_interval = 60
    client = SyncRecordWatch.client
    5.times { |i| client.push({ "message" => "m#{i}" }) }

    assert_equal 3, client.size
    assert_equal 2, client.stats[:dropped_queue_full]
  end

  def test_flush_sends_everything_now
    SyncRecordWatch.configuration.flush_interval = 60
    3.times { |i| SyncRecordWatch.logger.info("line #{i}") }
    SyncRecordWatch.flush

    assert_equal [ "line 0", "line 1", "line 2" ], @hub.next_request.entries.map { |e| e["message"] }
  end

  def test_shutdown_delivers_remaining_and_ignores_later_lines
    SyncRecordWatch.configuration.flush_interval = 60
    SyncRecordWatch.logger.info("last words")
    SyncRecordWatch.shutdown(timeout: 2)

    assert_equal [ "last words" ], @hub.next_request.entries.map { |e| e["message"] }
    refute SyncRecordWatch.client.push({ "message" => "too late" })
  end

  def test_network_errors_never_reach_the_app
    configure_for(@hub, url: "http://127.0.0.1:1", max_retries: 0)
    SyncRecordWatch.logger.info("nobody listens")
    SyncRecordWatch.flush(timeout: 1)
    wait_until { SyncRecordWatch.stats[:dropped_delivery].to_i >= 1 }
  end

  def test_test_bang_reports_success_and_failure
    out = StringIO.new
    assert SyncRecordWatch.test!(out: out)
    assert_match(/OK: test log accepted/, out.string)
    assert_equal "syncrecord_watch.test", @hub.next_request.entries.first["event"]

    @hub.respond_with(401)
    out = StringIO.new
    refute SyncRecordWatch.test!(out: out)
    assert_match(/FAILED: HTTP 401/, out.string)
  end

  def test_test_bang_explains_missing_configuration
    SyncRecordWatch.reset!
    SyncRecordWatch.configuration.url = nil
    SyncRecordWatch.configuration.api_key = nil
    out = StringIO.new
    refute SyncRecordWatch.test!(out: out)
    assert_match(/url is missing/, out.string)
  end

  private

  def wait_until(timeout: 4)
    deadline = Time.now + timeout
    until yield
      flunk "condition not met within #{timeout}s (stats: #{SyncRecordWatch.stats})" if Time.now > deadline
      sleep 0.02
    end
  end
end
