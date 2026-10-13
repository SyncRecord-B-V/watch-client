# frozen_string_literal: true

require 'test_helper'

class ClientTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    configure_for(@hub)
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def test_sends_batches_as_gzip_json_with_api_key
    WatchClient.logger.info('Hello from the test')
    WatchClient.logger.error('Something broke')

    request = @hub.next_request
    refute_nil request, 'expected a request to the hub'
    assert_equal 'POST', request.method
    assert_equal '/api/v1/logs', request.path
    assert_equal 'Bearer lh_test_key', request.headers['authorization']
    assert_equal 'gzip', request.headers['content-encoding']
    assert_match(%r{\Awatch_client/}, request.headers['user-agent'])

    entries = request.entries
    entries += @hub.next_request(timeout: 0.5)&.entries.to_a if entries.size < 2
    assert_equal(['Hello from the test', 'Something broke'], entries.map { |e| e['message'] })
    assert_equal(%w[info error], entries.map { |e| e['level'] })
    first = entries.first
    assert_equal 'production', first['environment']
    assert_equal 'web-1', first['host']
    assert_equal 'abc123', first['app_version']
    assert first['timestamp']
  end

  def test_skips_lines_below_min_level
    WatchClient.configuration.min_level = :warn
    WatchClient.logger.info('not sent')
    WatchClient.logger.warn('sent')

    assert_equal(['sent'], @hub.next_request.entries.map { |e| e['message'] })
  end

  def test_does_nothing_when_disabled
    WatchClient.configuration.enabled = false
    WatchClient.logger.error('nope')
    assert_nil @hub.next_request(timeout: 0.3)
    assert_empty WatchClient.stats
  end

  def test_retries_server_errors_then_succeeds
    WatchClient.configuration.max_retries = 2
    @hub.respond_with(503)
    WatchClient.logger.info('retry me')

    first = @hub.next_request
    second = @hub.next_request(timeout: 4)
    assert_equal(['retry me'], first.entries.map { |e| e['message'] })
    assert_equal(['retry me'], second.entries.map { |e| e['message'] })
    wait_until { WatchClient.stats[:sent] == 1 }
    assert_equal 1, WatchClient.stats[:retries]
  end

  def test_drops_batch_on_client_errors_without_retrying
    @hub.respond_with(401)
    WatchClient.logger.info('bad key')

    refute_nil @hub.next_request
    wait_until { WatchClient.stats[:dropped_delivery] == 1 }
    assert_nil @hub.next_request(timeout: 0.3)
    assert_match(/dropped 1 entries: HTTP 401/, WatchClient.configuration.diagnostics.string)
  end

  def test_caps_the_buffer_and_drops_oldest
    WatchClient.configuration.max_queue = 3
    WatchClient.configuration.flush_interval = 60
    client = WatchClient.client
    5.times { |i| client.push({ 'message' => "m#{i}" }) }

    assert_equal 3, client.size
    assert_equal 2, client.stats[:dropped_queue_full]
  end

  def test_flush_sends_everything_now
    WatchClient.configuration.flush_interval = 60
    3.times { |i| WatchClient.logger.info("line #{i}") }
    WatchClient.flush

    assert_equal(['line 0', 'line 1', 'line 2'], @hub.next_request.entries.map { |e| e['message'] })
  end

  def test_shutdown_delivers_remaining_and_ignores_later_lines
    WatchClient.configuration.flush_interval = 60
    WatchClient.logger.info('last words')
    WatchClient.shutdown(timeout: 2)

    assert_equal(['last words'], @hub.next_request.entries.map { |e| e['message'] })
    refute WatchClient.client.push({ 'message' => 'too late' })
  end

  def test_network_errors_never_reach_the_app
    configure_for(@hub, url: 'http://127.0.0.1:1', max_retries: 0)
    WatchClient.logger.info('nobody listens')
    WatchClient.flush(timeout: 1)
    wait_until { WatchClient.stats[:dropped_delivery].to_i >= 1 }
  end

  def test_test_bang_reports_success_and_failure
    out = StringIO.new
    assert WatchClient.test!(out: out)
    assert_match(/OK: test log accepted/, out.string)
    assert_equal 'watch_client.test', @hub.next_request.entries.first['event']

    @hub.respond_with(401)
    out = StringIO.new
    refute WatchClient.test!(out: out)
    assert_match(/FAILED: HTTP 401/, out.string)
  end

  def test_test_bang_explains_missing_configuration
    WatchClient.reset!
    WatchClient.configuration.url = nil
    WatchClient.configuration.api_key = nil
    out = StringIO.new
    refute WatchClient.test!(out: out)
    assert_match(/url is missing/, out.string)
  end

  private

  def wait_until(timeout: 4)
    deadline = Time.now + timeout
    until yield
      flunk "condition not met within #{timeout}s (stats: #{WatchClient.stats})" if Time.now > deadline
      sleep 0.02
    end
  end
end
