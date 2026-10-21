# frozen_string_literal: true

require 'test_helper'

# WatchClient.start! outside Rails (Sinatra, Rack, scripts, workers).
class StartTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
  end

  def teardown
    WatchClient::Metrics.uninstall!
    WatchClient.reset!
    @hub.stop
  end

  def test_does_nothing_when_watch_is_not_configured
    WatchClient.reset!
    WatchClient.configuration.environment = 'production'
    refute WatchClient.start!
    refute WatchClient.started?
    assert_nil WatchClient::Metrics.instance
  end

  def test_installs_the_integrations_once
    configure_for(@hub)
    assert WatchClient.start!
    assert WatchClient.started?
    assert WatchClient::Metrics.instance
    assert Net::HTTP.ancestors.include?(WatchClient::NetHTTPPropagation)
    refute_nil WatchClient.configuration.filter_keys
    assert WatchClient.start! # a second call is harmless
  end

  def test_rack_middleware_reports_escaping_errors_after_start
    configure_for(@hub)
    WatchClient.start!
    app = ->(_env) { raise ArgumentError, 'boom in a Rack app' }
    middleware = WatchClient::RackMiddleware.new(app)
    assert_raises(ArgumentError) { middleware.call({}) }
    WatchClient.flush
    request = @hub.next_request
    refute_nil request
    assert_equal 'ArgumentError', request.errors.first['exception_class']
  end

  def test_rack_middleware_leaves_reporting_to_rails_without_start
    configure_for(@hub)
    middleware = WatchClient::RackMiddleware.new(->(_env) { raise ArgumentError, 'boom' })
    assert_raises(ArgumentError) { middleware.call({}) }
    WatchClient.flush
    assert_nil @hub.next_request(timeout: 0.3)
  end

  def test_a_short_script_delivers_its_last_metrics_and_stops_the_worker
    configure_for(@hub)
    WatchClient.start!
    metrics = WatchClient::Metrics.instance
    metrics.record_http(host: 'api.example.com', duration_ms: 12, status: '200')
    assert metrics.running?

    WatchClient.shutdown(timeout: 3)
    request = @hub.next_request
    refute_nil request
    assert_equal '/api/v1/metrics', request.path
    assert_equal 'api.example.com', request.json['http'].first['host']
    refute metrics.running?
    refute WatchClient.started?
  end

  def test_flush_sends_buffered_metrics_too
    configure_for(@hub)
    WatchClient.start!
    WatchClient::Metrics.instance.record_http(host: 'api.example.com', duration_ms: 5, status: '200')
    WatchClient.flush(timeout: 3)
    assert_equal '/api/v1/metrics', @hub.next_request&.path
  end

  # A Watch that never answers: flushes time out, but only one delivery thread exists, and shutdown
  # leaves none behind.
  class BlockedTransport
    attr_reader :calls

    def initialize
      @calls = 0
      @gate = Queue.new
    end

    def post(_payload)
      @calls += 1
      @gate.pop # never answers
    end
  end

  def test_slow_delivery_never_piles_up_threads
    configure_for(@hub)
    transport = BlockedTransport.new
    metrics = WatchClient::Metrics.new(WatchClient.configuration, transport: transport)
    metrics.define_singleton_method(:ensure_running) { nil }
    flush_threads = -> { Thread.list.count { |thread| thread.alive? && thread.name == 'watch-metrics-flush' } }

    5.times do
      metrics.record_http(host: 'slow.example', duration_ms: 1, status: '200')
      refute metrics.flush(timeout: 0.05)
    end
    assert_equal 1, transport.calls, 'a flush waits for the running delivery instead of starting another'
    assert_equal 1, flush_threads.call

    metrics.shutdown(timeout: 0.05)
    refute metrics.sending?
    assert_equal 0, flush_threads.call
  end

  # A Watch that holds the first delivery until released, then accepts everything.
  class GatedTransport
    attr_reader :payloads

    def initialize
      @payloads = []
      @gate = Queue.new
    end

    def release = @gate << :go

    def post(payload)
      @gate.pop if @payloads.empty?
      @payloads << payload
      WatchClient::Transport::Result.new(status: :ok, code: 202)
    end
  end

  def test_metrics_recorded_during_a_slow_delivery_are_sent_before_shutdown_succeeds
    configure_for(@hub)
    transport = GatedTransport.new
    metrics = WatchClient::Metrics.new(WatchClient.configuration, transport: transport)
    metrics.define_singleton_method(:ensure_running) { nil }

    metrics.record_http(host: 'first.example', duration_ms: 1, status: '200')
    refute metrics.flush(timeout: 0.05) # blocked
    4.times { metrics.record_http(host: 'later.example', duration_ms: 1, status: '200') }
    assert metrics.pending?

    Thread.new do
      sleep 0.1
      transport.release
    end
    assert metrics.shutdown(timeout: 3)
    refute metrics.pending?
    hosts = transport.payloads.map { |payload| payload['http'].map { |row| row['host'] } }
    assert_equal [['first.example'], ['later.example']], hosts
    assert_equal 4, transport.payloads.last['http'].first['count']
  end
end
