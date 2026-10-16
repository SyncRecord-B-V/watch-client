# frozen_string_literal: true

require 'test_helper'

class ApiQuotaTest < Minitest::Test
  NOW = Time.utc(2026, 10, 15, 12, 0, 0)

  def parse(headers) = WatchClient::ApiQuota.parse(headers.transform_keys(&:downcase), now: NOW)

  def test_salesforce_daily_usage
    assert_equal [{ 'name' => 'day', 'limit' => 140_000, 'remaining' => 133_753, 'reset_at' => nil }],
                 parse('Sforce-Limit-Info' => 'api-usage=6247/140000')
  end

  def test_salesforce_over_the_limit_counts_as_nothing_left
    assert_equal 0, parse('Sforce-Limit-Info' => 'api-usage=146247/140000').first['remaining']
  end

  def test_github_style_with_unix_reset
    quota = parse('X-RateLimit-Limit' => '5000', 'X-RateLimit-Remaining' => '4990', 'X-RateLimit-Reset' => (NOW.to_i + 600).to_s).first
    assert_equal({ 'name' => 'default', 'limit' => 5000, 'remaining' => 4990, 'reset_at' => '2026-10-15T12:10:00Z' }, quota)
  end

  def test_ietf_headers_reset_in_seconds
    quota = parse('RateLimit-Limit' => '100', 'RateLimit-Remaining' => '7', 'RateLimit-Reset' => '30').first
    assert_equal '2026-10-15T12:00:30Z', quota['reset_at']
    assert_equal 7, quota['remaining']
  end

  def test_ietf_single_header
    quota = parse('RateLimit' => 'limit=100, remaining=50, reset=60').first
    assert_equal [100, 50, '2026-10-15T12:01:00Z'], quota.values_at('limit', 'remaining', 'reset_at')
  end

  def test_exact_online_minute_and_day_with_millisecond_resets
    quotas = parse('X-RateLimit-Minutely-Limit' => '60', 'X-RateLimit-Minutely-Remaining' => '12',
                   'X-RateLimit-Minutely-Reset' => ((NOW.to_i + 30) * 1000).to_s,
                   'X-RateLimit-Limit' => '5000', 'X-RateLimit-Remaining' => '4100',
                   'X-RateLimit-Reset' => ((NOW.to_i + 3600) * 1000).to_s)
    assert_equal({ 'minute' => 12, 'day' => 4100 }, quotas.to_h { |quota| [quota['name'], quota['remaining']] })
    assert_equal '2026-10-15T12:00:30Z', quotas.find { |quota| quota['name'] == 'minute' }['reset_at']
  end

  def test_shopify_bucket_and_hubspot_daily
    assert_equal 8, parse('X-Shopify-Shop-Api-Call-Limit' => '32/40').first['remaining']
    assert_equal({ 'name' => 'day', 'limit' => 250_000, 'remaining' => 1000, 'reset_at' => nil },
                 parse('X-HubSpot-RateLimit-Daily' => '250000', 'X-HubSpot-RateLimit-Daily-Remaining' => '1000').first)
  end

  def test_ignores_missing_or_odd_values
    assert_empty parse({})
    assert_empty parse('X-RateLimit-Limit' => 'lots', 'X-RateLimit-Remaining' => '5')
    assert_empty parse('X-RateLimit-Limit' => '0', 'X-RateLimit-Remaining' => '0')
    assert_empty parse('Sforce-Limit-Info' => 'api-usage=abc')
    assert_nil parse('X-RateLimit-Limit' => '10', 'X-RateLimit-Remaining' => '5', 'X-RateLimit-Reset' => 'not a date').first['reset_at']
    assert_empty WatchClient::ApiQuota.parse(nil)
  end

  def test_metrics_keep_the_latest_quota_and_count_429s
    config = WatchClient::Configuration.new
    metrics = WatchClient::Metrics.new(config)
    metrics.define_singleton_method(:ensure_running) { nil }
    first = parse('Sforce-Limit-Info' => 'api-usage=100/1000')
    latest = parse('Sforce-Limit-Info' => 'api-usage=900/1000')
    metrics.record_http(host: 'x.my.salesforce.com', duration_ms: 10, status: '200', quotas: first)
    metrics.record_http(host: 'x.my.salesforce.com', duration_ms: 10, status: '429', quotas: latest)
    row = metrics.build_payload['http'].first
    assert_equal 1, row['rate_limited']
    assert_equal 1, row['client_errors']
    assert_equal [{ 'name' => 'day', 'limit' => 1000, 'remaining' => 100, 'reset_at' => nil }], row['quotas']
  end

  def test_oversized_or_odd_headers_are_ignored_before_parsing
    huge = 'limit=100, remaining=5, ' * 150_000 # 3.6 MB
    assert_empty parse('RateLimit' => huge)
    assert_empty parse('Sforce-Limit-Info' => "api-usage=1/2#{' ' * 300}")
    assert_empty parse('X-RateLimit-Limit' => '9' * 40, 'X-RateLimit-Remaining' => '5')
    assert_empty parse('RateLimit' => Array.new(50) { |i| "x#{i}=1" }.join(', '))
    assert_equal 50, parse('RateLimit' => 'limit=100, remaining=50').first['remaining']
  end

  def test_a_huge_header_still_reaches_the_app_and_records_the_call
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      socket = server.accept
      socket.gets("\r\n\r\n")
      big = 'limit=100, remaining=5, ' * 150_000
      socket.write("HTTP/1.1 200 OK\r\nRateLimit: #{big}\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      socket.close
    end
    WatchClient::NetHTTPPropagation.install!
    metrics = WatchClient::Metrics.new(WatchClient::Configuration.new)
    metrics.define_singleton_method(:ensure_running) { nil }
    WatchClient::Metrics.instance_variable_set(:@instance, metrics)
    response = Net::HTTP.start('127.0.0.1', server.addr[1]) { |http| http.get('/') }
    assert_equal 'ok', response.body
    row = metrics.build_payload['http'].first
    assert_equal 1, row['count']
    assert_empty row['quotas']
  ensure
    WatchClient::Metrics.instance_variable_set(:@instance, nil)
    thread&.join(2)
    server&.close
  end
end
