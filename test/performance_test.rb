require "test_helper"
require "tmpdir"

class HistogramTest < Minitest::Test
  def test_bucket_index
    assert_equal 0, WatchClient::Histogram.index(3)
    assert_equal 0, WatchClient::Histogram.index(5)
    assert_equal 1, WatchClient::Histogram.index(5.1)
    assert_equal WatchClient::Histogram::BOUNDS.size, WatchClient::Histogram.index(60_000)
    assert_equal 20, WatchClient::Histogram.empty.size
  end
end

class MetricsTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    configure_for(@hub)
    @metrics = WatchClient::Metrics.new(WatchClient.configuration)
    @metrics.define_singleton_method(:ensure_running) { nil } # no background thread in tests
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def test_requests_per_endpoint
    @metrics.record_request(endpoint: "InvoicesController#index", duration_ms: 40, status: 200, db_ms: 12.5, view_ms: 20, http_ms: 0)
    @metrics.record_request(endpoint: "InvoicesController#index", duration_ms: 900, status: 500, db_ms: 300, view_ms: nil)
    payload = @metrics.build_payload
    row = payload["requests"].first
    assert_equal "InvoicesController#index", row["endpoint"]
    assert_equal 2, row["count"]
    assert_equal 1, row["errors"]
    assert_equal 940.0, row["total_ms"]
    assert_equal 900.0, row["max_ms"]
    assert_equal 312.5, row["db_ms"]
    assert_equal 1, row["buckets"][WatchClient::Histogram.index(40)]
    assert_equal 1, row["buckets"][WatchClient::Histogram.index(900)]
    assert_empty @metrics.build_payload["requests"], "buffers are emptied"
  end

  def test_outside_calls_per_host
    @metrics.record_http(host: "api.exactonline.nl", duration_ms: 120, status: "200")
    @metrics.record_http(host: "api.exactonline.nl", duration_ms: 30, status: "404")
    @metrics.record_http(host: "api.exactonline.nl", duration_ms: 10_000, failure: "timeout")
    row = @metrics.build_payload["http"].first
    assert_equal({ "host" => "api.exactonline.nl", "count" => 3, "errors" => 1, "client_errors" => 1, "failures" => 1, "timeouts" => 1 },
                 row.slice("host", "count", "errors", "client_errors", "failures", "timeouts"))
  end

  def test_sends_to_the_hub
    @metrics.record_request(endpoint: "HomeController#show", duration_ms: 12)
    assert @metrics.send_once
    request = @hub.next_request
    assert_equal "/api/v1/metrics", request.path
    assert_equal "HomeController#show", request.json["requests"].first["endpoint"]
  end

  def test_nothing_sent_when_idle_and_process_health_is_off
    WatchClient.configuration.process_monitoring = false
    assert @metrics.send_once
    assert_nil @hub.next_request(timeout: 0.2)
  end
end

class NetHTTPTimingTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    @target = FakeHub.new
    configure_for(@hub)
    WatchClient::NetHTTPPropagation.install!
    @metrics = WatchClient::Metrics.install!
    @metrics.define_singleton_method(:ensure_running) { nil }
  end

  def teardown
    WatchClient.reset!
    @hub.stop
    @target.stop
  end

  def test_outgoing_calls_are_timed_per_host
    Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY] = 0.0
    uri = URI("#{@target.url}/orders")
    Net::HTTP.start(uri.host, uri.port) { |http| http.get(uri.path) }
    row = @metrics.build_payload["http"].first
    assert_equal "127.0.0.1:#{uri.port}", row["host"]
    assert_equal 1, row["count"]
    assert_operator Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY], :>, 0
  ensure
    Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY] = nil
  end

  def test_connection_failures_count
    port = TCPServer.new("127.0.0.1", 0).tap(&:close).addr[1] rescue 1
    assert_raises(Errno::ECONNREFUSED) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }
    # The connection never started, so the call isn't counted (no host was reached).
    assert_empty @metrics.build_payload["http"]
  end

  def test_log_hub_delivery_is_not_counted
    WatchClient.log(:info, "hello")
    WatchClient.flush(timeout: 2)
    assert_empty @metrics.build_payload["http"]
  end
end

class DependenciesTest < Minitest::Test
  LOCKFILE = <<~LOCK.freeze
    GEM
      remote: https://rubygems.org/
      specs:
        actionpack (7.1.3)
          rack (>= 2.2.4)
        nokogiri (1.15.4-arm64-darwin)
        rack (2.2.8)

    PLATFORMS
      arm64-darwin

    DEPENDENCIES
      rack

    BUNDLED WITH
       2.5.6
  LOCK

  def test_payload_from_a_lockfile
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Gemfile.lock")
      File.write(path, LOCKFILE)
      payload = WatchClient::Dependencies.payload(WatchClient::Configuration.new, lockfile: path)
      names = payload["gems"].map { |gem| [ gem["name"], gem["version"] ] }
      assert_includes names, [ "rack", "2.2.8" ]
      assert_includes names, [ "nokogiri", "1.15.4" ]
      assert_equal RUBY_VERSION, payload["ruby"]
      assert_match(/\A\h{64}\z/, payload["digest"])
    end
  end

  def test_no_lockfile
    assert_nil WatchClient::Dependencies.payload(WatchClient::Configuration.new, lockfile: "/nope/Gemfile.lock")
  end
end
