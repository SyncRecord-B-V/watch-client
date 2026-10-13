# frozen_string_literal: true

require 'test_helper'

# Secrets and personal data must never reach Watch: log fields, log context, error requests,
# SQL text, and nothing is sent over plain HTTP to a remote host.
class SecurityTest < Minitest::Test
  include WatchTestHelpers

  FakeRequest = Struct.new(:env, :path, :filtered_path, keyword_init: true) do
    def filtered_parameters = {}
    def request_method = 'GET'
    def base_url = 'https://app.example'
    def remote_ip = '203.0.113.9'
    def get_header(name) = env[name]
    def session = nil
    def cookies = {}
  end

  def setup
    WatchClient.reset!
    @config = WatchClient.configuration
    @config.environment = 'production'
    @config.diagnostics = StringIO.new
  end

  def teardown
    WatchClient.reset!
  end

  def entry(**args)
    WatchClient::Entry.build(@config, **{ severity: :info, message: 'hi', context: {} }.merge(args))
  end

  # 1. Structured logs: the fallback message is built from filtered fields.
  def test_structured_log_without_message_never_shows_secrets_in_the_text
    built = entry(message: { password: 'hunter2', user_token: 'tok-123', step: 'login' })
    refute_includes built['message'], 'hunter2'
    refute_includes built['message'], 'tok-123'
    assert_includes built['message'], 'password=[FILTERED]'
    assert_includes built['message'], 'step=login'
    assert_equal '[FILTERED]', built['password']
  end

  def test_structured_event_name_is_filtered_too
    @config.filter_keys = [:event]
    built = entry(message: { event: 'secret-value', other: 1 })
    refute_includes built['message'], 'secret-value'
  end

  # 2. with_context fields go through the filter.
  def test_context_fields_are_filtered
    built = entry(context: { request_id: 'req-1', api_key: 'sk_live_123', customer_email: 'a@b.test' })
    assert_equal 'req-1', built['request_id']
    assert_equal '[FILTERED]', built['api_key']
    assert_equal '[FILTERED]', built['customer_email']
  end

  def test_with_context_api_key_is_masked_end_to_end
    WatchClient.with_context(api_key: 'sk_live_123') do
      built = WatchClient::Entry.build(@config, severity: :info, message: 'hi')
      assert_equal '[FILTERED]', built['api_key']
    end
  end

  # 5. Rails filter rules: procs, dotted rules, arrays at every level (both with and without
  # ActiveSupport::ParameterFilter).
  def filter_both_ways(hash, keys)
    all = WatchClient::Filter.rules(keys)
    results = [WatchClient::Filter.filter_hash(hash, all, nil)]
    results << WatchClient::Filter.hash(hash, keys) if defined?(::ActiveSupport::ParameterFilter)
    results
  end

  def test_dotted_rules_match_the_nested_path_only
    hash = { 'account' => { 'credential' => 'c-1', 'name' => 'Acme' }, 'credential' => 'top' }
    filter_both_ways(hash, ['account.credential']).each do |out|
      assert_equal '[FILTERED]', out['account']['credential']
      assert_equal 'Acme', out['account']['name']
    end
  end

  def test_hashes_inside_nested_arrays_are_filtered
    hash = { 'rows' => [[{ 'password' => 'p1', 'ok' => 1 }], [[{ 'token' => 't1' }]]] }
    filter_both_ways(hash, []).each do |out|
      assert_equal '[FILTERED]', out['rows'][0][0]['password']
      assert_equal 1, out['rows'][0][0]['ok']
      assert_equal '[FILTERED]', out['rows'][1][0][0]['token']
    end
  end

  def test_proc_rules_are_applied
    masker = ->(key, value) { value.replace('***') if key == 'card' && value.is_a?(String) }
    hash = { 'card' => '4111111111111111', 'nested' => [{ 'card' => '5500' }], 'ok' => 'fine' }
    filter_both_ways(hash, [masker]).each do |out|
      assert_equal '***', out['card']
      assert_equal '***', out['nested'][0]['card']
      assert_equal 'fine', out['ok']
    end
    assert_equal '4111111111111111', hash['card'], 'the original is never changed'
  end

  def test_a_failing_rule_hides_everything
    broken = ->(_key, _value) { raise 'boom' }
    out = WatchClient::Filter.hash({ 'a' => '1' }, [broken])
    assert_equal({ 'a' => '[FILTERED]' }, out)
  end

  # 4. URLs: referrer, Referer header, query string and request URL.
  def test_error_requests_mask_secrets_in_every_url
    env = {
      'HTTP_REFERER' => 'https://other.example/reset?token=abc123&email=a%40b.test&page=2#frag',
      'QUERY_STRING' => 'token=abc123&page=2',
      'REQUEST_URI' => '/orders?token=abc123&page=2',
      'ORIGINAL_FULLPATH' => '/orders?token=abc123&page=2'
    }
    request = FakeRequest.new(env: env, path: '/orders?token=abc123&page=2',
                              filtered_path: '/orders?token=abc123&page=2')
    notice = WatchClient::Notice.build(@config, RuntimeError.new('x'), handled: true, request: request)
    dump = JSON.generate(notice)

    refute_includes dump, 'abc123'
    refute_includes dump, 'a%40b.test'
    refute_includes dump, 'frag'
    assert_equal 'https://app.example/orders?token=[FILTERED]&page=2', notice['request']['url']
    assert_equal 'https://other.example/reset?token=[FILTERED]&email=[FILTERED]&page=2', notice['request']['referrer']
    assert_equal notice['request']['referrer'], notice['request']['headers']['Referer']
    assert_equal 'token=[FILTERED]&page=2', notice['cgi_env']['QUERY_STRING']
    assert_equal '/orders?token=[FILTERED]&page=2', notice['cgi_env']['REQUEST_URI']
  end

  def test_url_filter_uses_the_app_rules_too
    @config.filter_keys = [:coupon]
    assert_equal 'https://a.example/?coupon_ref=[FILTERED]&q=1',
                 WatchClient::Filter.url('https://a.example/?coupon_ref=X1&q=1', @config.filter_keys)
  end

  # 3. SQL: one SQL-aware sanitizer for breadcrumbs and slow / top queries.
  def sanitize(sql) = WatchClient::Breadcrumbs.sanitize_sql(sql)

  def test_sql_escaped_strings_do_not_leak
    sql = "SELECT * FROM users WHERE note = E'prefix\\'alice@example.test' AND id = 4"
    assert_equal 'SELECT * FROM users WHERE note = ? AND id = ?', sanitize(sql)
    assert_equal sanitize(sql), WatchClient::SqlNormalizer.normalize(sql)
  end

  def test_sql_dollar_quotes_and_comments_do_not_leak_into_breadcrumbs
    sql = "SELECT $$alice@example.test$$, $t$bob's secret$t$ /* user carol@example.test */ FROM t -- dave@example.test"
    out = sanitize(sql)
    refute_match(/example\.test|bob|secret|carol|dave/, out)
    assert_equal 'SELECT ?, ? FROM t', out
  end

  def test_sql_cut_off_values_are_dropped
    assert_equal 'SELECT * FROM t WHERE email = ?…', sanitize("SELECT * FROM t WHERE email = 'alice@exa")
    assert_equal 'SELECT * FROM t WHERE x = ?…', sanitize("SELECT * FROM t WHERE x = E'a\\'b")
    assert_equal 'SELECT ? …', sanitize('SELECT 1 /* never closed alice@example.test')
  end

  def test_sql_keeps_identifiers
    assert_equal %(SELECT "users"."email" FROM "users" WHERE "users"."id" = ?),
                 sanitize(%(SELECT "users"."email" FROM "users" WHERE "users"."id" = $1))
  end

  # 6. HTTPS for anything that carries the API key or a ping token.
  def test_https_is_required_for_remote_hosts
    @config.api_key = 'key'
    @config.url = 'http://watch.example.com'
    refute @config.secure_url?
    refute @config.enabled?
    assert_match(/https/, @config.diagnostics.string)
    assert(@config.validate!.any? { |problem| problem.include?('https') })

    @config.url = 'https://watch.example.com'
    assert @config.secure_url?
    assert @config.enabled?
  end

  def test_http_is_allowed_for_local_development_hosts
    %w[http://localhost:3000 http://127.0.0.1:3000 http://[::1]:3000 http://watch.localhost
       http://watch.test].each do |url|
      assert @config.secure_url?(url), url
    end
    refute @config.secure_url?('http://watch.localhost.example.com')
    refute @config.secure_url?('http://127.evil.example')
    refute @config.secure_url?('ftp://watch.example.com')
    refute @config.secure_url?('not a url')
  end

  def test_allow_http_is_an_explicit_opt_in
    @config.allow_http = true
    assert @config.secure_url?('http://watch.internal')
  end

  def test_transport_refuses_plain_http_to_a_remote_host
    @config.url = 'http://watch.example.com'
    @config.api_key = 'key'
    result = WatchClient::Transport.new(@config).post([{ 'message' => 'x' }])
    assert result.drop?
    assert_match(/https/, result.error)
  end

  def test_check_in_refuses_plain_http_ping_urls
    @config.check_ins_enabled = true
    refute WatchClient::CheckIn.ping(@config, 'http://watch.example.com/ping/tok_1')
    assert_match(/https/, @config.diagnostics.string)
  end
end
