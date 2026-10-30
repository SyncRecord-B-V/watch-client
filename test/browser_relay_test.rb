# frozen_string_literal: true

require 'test_helper'
require 'rack'
require 'rack/mock'

class BrowserRelayTest < Minitest::Test
  include WatchTestHelpers

  REPORT = '{"name":"TypeError","message":"x is undefined","url":"https://shop.example.com/cart"}'

  def setup
    @hub = FakeHub.new
    configure_for(@hub)
    WatchClient.configuration.browser_key = 'lhb_public'
    @app_calls = 0
    @relay = WatchClient::BrowserRelay.new(lambda { |_env|
      @app_calls += 1
      [200, {}, ['app']]
    })
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def get(path, headers = {})
    Rack::MockRequest.new(@relay).get(path, { 'HTTP_HOST' => 'shop.example.com', 'HTTPS' => 'on' }.merge(headers))
  end

  def send_report(body = REPORT, path: '/watch/browser_errors?key=lhb_public', **headers)
    env = { 'HTTP_HOST' => 'shop.example.com', 'HTTPS' => 'on', 'HTTP_ORIGIN' => 'https://shop.example.com',
            'HTTP_USER_AGENT' => 'Mozilla/5.0 Chrome/141.0', 'REMOTE_ADDR' => '81.2.69.142', input: body }
    Rack::MockRequest.new(@relay).post(path, env.merge(headers))
  end

  def test_serves_the_bundled_watch_js_cached_per_version
    version = WatchClient::BrowserRelay.script_version
    assert_match(/\A\d+\.\d+\.\d+\z/, version)

    response = get("/watch/watch.js?v=#{version}")
    assert_equal 200, response.status
    assert_includes response.body, "watch.js #{version}"
    assert_equal 'application/javascript; charset=utf-8', response.headers['content-type']
    assert_includes response.headers['cache-control'], 'immutable'
    assert_equal 'public, max-age=3600', get('/watch/watch.js').headers['cache-control']

    again = get("/watch/watch.js?v=#{version}", 'HTTP_IF_NONE_MATCH' => response.headers['etag'])
    assert_equal 304, again.status
    assert_equal 0, @app_calls
  end

  def test_passes_everything_else_to_the_app
    assert_equal 'app', get('/invoices/7').body
    assert_equal 'app', get('/watch').body

    WatchClient.configuration.browser_relay = false
    assert_equal 'app', get('/watch/watch.js').body
  end

  def test_queues_reports_from_the_websites_own_pages_and_sends_them_with_the_server_key
    response = send_report
    assert_equal 204, response.status
    assert_nil response.headers['x-watch-refused']
    assert_equal 0, @app_calls

    WatchClient::BrowserRelay.client.flush(timeout: 3)
    request = @hub.next_request
    assert_equal '/api/v1/browser_reports', request.path
    assert_equal 'Bearer lh_test_key', request.headers['authorization']
    report = request.json.fetch('reports').first
    assert_equal 'error', report['kind']
    assert_equal 'https://shop.example.com', report['origin']
    assert_equal '81.2.69.142', report['ip']
    assert_equal 'TypeError', report.dig('body', 'name')
  end

  def test_refuses_quietly
    {
      'origin-not-allowed' => -> { send_report('HTTP_ORIGIN' => 'https://evil.example.com') },
      'unknown-key' => -> { send_report(path: '/watch/browser_errors?key=lhb_other') },
      'unreadable' => -> { send_report('[1,2]') },
      'too-large' => -> { send_report(%({"m":"#{'x' * 5000}"}), path: '/watch/browser_vitals?key=lhb_public') }
    }.each do |reason, call|
      response = call.call
      assert_equal 204, response.status, reason
      assert_equal reason, response.headers['x-watch-refused']
    end
    assert_equal 405, get('/watch/browser_errors').status
    assert_equal 0, WatchClient::BrowserRelay.client.size
  end

  def test_accepts_the_same_host_behind_a_tls_proxy
    assert_nil send_report('HTTPS' => 'off').headers['x-watch-refused']
  end

  def test_limits_reports_per_visitor_per_minute
    limit = WatchClient::BrowserRelay::LIMITS['error'][:ip]
    now = Time.at(1_800_000_000)
    limit.times { assert WatchClient::BrowserRelay.within_limits?('error', '81.2.69.142', now: now, cache: nil) }
    refute WatchClient::BrowserRelay.within_limits?('error', '81.2.69.142', now: now, cache: nil)
    assert WatchClient::BrowserRelay.within_limits?('error', '8.8.4.4', now: now, cache: nil), 'another visitor has their own budget'
    assert WatchClient::BrowserRelay.within_limits?('vitals', '81.2.69.142', now: now, cache: nil), 'page speed has its own budget'
    assert WatchClient::BrowserRelay.within_limits?('error', '81.2.69.142', now: now + 60, cache: nil), 'a new minute starts over'
  end

  def test_batches_stop_at_about_a_megabyte
    client = WatchClient::BrowserRelay.client
    big = { 'kind' => 'error', 'body' => { 'message' => 'x' * (60 * 1024) } }
    40.times { client.push(big) }
    client.flush(timeout: 5)

    sizes = []
    while (request = @hub.next_request(timeout: 1))
      sizes << request.json.fetch('reports').size
    end
    assert_equal 40, sizes.sum
    assert(sizes.all? { |size| size <= 17 }, "batches: #{sizes.inspect}")
  end

  def test_the_tag_points_at_the_relay
    html = WatchClient::BrowserTag.html
    assert_includes html, %(src="/watch/watch.js?v=#{WatchClient::BrowserRelay.script_version}")
    assert_includes html, %(data-endpoint="/watch/browser_errors")

    WatchClient.configuration.browser_relay = false
    assert_includes WatchClient::BrowserTag.html, %(src="#{@hub.url}/watch.js")
  end

  def test_browser_path_is_a_plain_path
    config = WatchClient::Configuration.new
    { nil => '/watch', '/assets/watch/' => '/assets/watch', 'x y' => '/watch', '/../etc' => '/watch' }.each do |given, path|
      config.browser_path = given
      assert_equal path, config.browser_path, given.inspect
    end
  end
end
