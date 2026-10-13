# frozen_string_literal: true

require 'test_helper'
require 'watch_client/request_subscriber'

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

  # Second review (commit 4505593).

  def enable_without_sending
    @config.url = 'http://127.0.0.1:9'
    @config.api_key = 'key'
    @config.enabled = true
  end

  def test_warning_breadcrumbs_filter_structured_messages_even_without_send_logs
    enable_without_sending
    @config.send_logs = false
    WatchClient::Breadcrumbs.with do
      WatchClient.logger.warn(password: 'demo-secret', step: 'login')
      crumb = WatchClient::Breadcrumbs.current.last
      refute_includes crumb['message'], 'demo-secret'
      assert_includes crumb['message'], 'password=[FILTERED]'
    end
  end

  def test_breadcrumb_metadata_is_filtered
    WatchClient::Breadcrumbs.with do
      WatchClient::Breadcrumbs.add('custom', 'x', 'api_token' => 'tok-1', 'nested' => [{ 'password' => 'p' }], 'ok' => 1)
      metadata = WatchClient::Breadcrumbs.current.last['metadata']
      assert_equal '[FILTERED]', metadata['api_token']
      assert_equal '[FILTERED]', metadata['nested'][0]['password']
      assert_equal 1, metadata['ok']
    end
  end

  def test_mysql_strings_are_sanitized
    mysql = ->(sql) { WatchClient::SqlNormalizer.normalize(sql, dialect: :mysql) }
    assert_equal 'SELECT * FROM `users` WHERE name = ? AND note = ?',
                 mysql.call(%q(SELECT * FROM `users` WHERE name = "bob@example.test" AND note = 'it''s' # carol@example.test))
    refute_includes mysql.call(%q(SELECT * FROM t WHERE a = 'O\'alice@example.test' AND b = 1)), 'alice'
    assert_equal :mysql, WatchClient::SqlNormalizer.dialect_for('Mysql2')
    assert_equal :mysql, WatchClient::SqlNormalizer.dialect_for('Trilogy')
    assert_equal :standard, WatchClient::SqlNormalizer.dialect_for('PostgreSQL')
  end

  def test_backslash_quotes_never_leak_whatever_the_server_setting
    [%q(SELECT * FROM t WHERE a = 'O\'alice@example.test' AND b = 1),
     %q(SELECT 'C:\' , 'secret@example.test')].each do |sql|
      %i[standard mysql].each do |dialect|
        refute_match(/alice|secret/, WatchClient::SqlNormalizer.normalize(sql, dialect: dialect), "#{dialect}: #{sql}")
      end
    end
  end

  def test_request_summaries_use_watch_url_filters
    enable_without_sending
    @config.filter_keys = [:voucher]
    sent = []
    @config.before_send = ->(line) { sent << line && nil }
    request = Struct.new(:filtered_path).new('/orders?voucher=V-123&page=2')
    event = Struct.new(:payload, :duration).new(
      { method: 'GET', status: 200, controller: 'OrdersController', action: 'index', request: request }, 12.0
    )
    WatchClient::RequestSubscriber.handle(event)
    line = sent.last
    refute_includes JSON.generate(line), 'V-123'
    assert_equal '/orders?voucher=[FILTERED]&page=2', line['path']
  end

  def test_url_filters_apply_procs_and_dotted_rules
    masker = ->(key, value) { value.replace('***') if key == 'credential' && value.is_a?(String) }
    url = 'https://a.example/?credential=c1&account[credential]=c2&account[name_x]=n&q=1'
    out = WatchClient::Filter.url(url, [masker])
    refute_match(/c1|c2/, out)
    dotted = WatchClient::Filter.url('https://a.example/?account[pin]=1234&pin=ok', ['account.pin'])
    assert_equal 'https://a.example/?account[pin]=[FILTERED]&pin=ok', dotted
  end

  def test_huge_fields_are_truncated_per_entry
    built = entry(message: { event: 'import', blob: 'a' * 2_000_000, rows: 3 })
    assert_operator JSON.generate(built).bytesize, :<=, WatchClient::Entry::MAX_ENTRY_BYTES
    assert_equal '[TRUNCATED: 2000002 bytes]', built['blob']
    assert_equal 3, built['rows']
  end

  def test_buffer_is_bounded_by_bytes
    @config.max_queue_bytes = 50_000
    client = WatchClient::Client.new(@config, flush_interval: 3600, batch_size: 1000)
    client.define_singleton_method(:ensure_thread!) { nil }
    40.times { client.push({ 'message' => 'x' * 5_000 }) }
    stats = client.stats
    assert_operator stats[:buffered_bytes], :<=, 50_000
    assert_operator stats[:dropped_queue_full], :>, 0
    refute client.push({ 'message' => 'y' * 60_000 })
    assert_equal 1, client.stats[:dropped_too_large]
  end

  # Third review.

  def test_unencodable_entries_are_dropped_without_touching_the_queue
    client = WatchClient::Client.new(@config, flush_interval: 3600, batch_size: 1000)
    client.define_singleton_method(:ensure_thread!) { nil }
    assert client.push({ 'message' => 'ok' })
    before = client.stats
    refute client.push({ 'message' => 'x', 'ratio' => Float::NAN, 'blob' => 'a' * 4_000_000 })
    after = client.stats
    assert_equal 1, after[:dropped_unencodable]
    assert_equal before[:buffered], after[:buffered]
    assert_equal before[:buffered_bytes], after[:buffered_bytes]
  end

  def test_conditional_proc_filters_see_the_whole_query
    rule = lambda do |key, value, params|
      value.replace('***') if key == 'credential' && params && params['sensitive'] == '1' && value.is_a?(String)
    end
    out = WatchClient::Filter.url('https://a.example/?sensitive=1&credential=demo-secret', [rule])
    refute_includes out, 'demo-secret'
    assert_equal 'https://a.example/?sensitive=1&credential=[FILTERED]', out
    kept = WatchClient::Filter.url('https://a.example/?sensitive=0&credential=fine', [rule])
    assert_equal 'https://a.example/?sensitive=0&credential=fine', kept
  end

  def test_query_arrays_and_repeats_follow_rack
    out = WatchClient::Filter.url('https://a.example/?ids[]=1&ids[]=2&tag=a&tag=b&account[pin]=9', ['account.pin'])
    assert_equal 'https://a.example/?ids[]=1&ids[]=2&tag=a&tag=b&account[pin]=[FILTERED]', out
  end

  def test_names_rack_would_read_differently_mask_every_value
    out = WatchClient::Filter.url('https://a.example/?a=1&a[b]=2&page=3', [])
    assert_equal 'https://a.example/?a=[FILTERED]&a[b]=[FILTERED]&page=[FILTERED]', out
    out = WatchClient::Filter.url('https://a.example/?list[][id]=1&page=3', [])
    assert_equal 'https://a.example/?list[][id]=[FILTERED]&page=[FILTERED]', out
  end

  def test_repeated_parameters_use_the_last_value_and_mask_every_occurrence
    rule = lambda do |key, value, params|
      value.replace('***') if key == 'credential' && params && params['sensitive'] == '1' && value.is_a?(String)
    end
    out = WatchClient::Filter.url('https://a.example/?sensitive=0&sensitive=1&credential=old&credential=demo-secret', [rule])
    assert_equal 'https://a.example/?sensitive=0&sensitive=1&credential=[FILTERED]&credential=[FILTERED]', out
  end

  def test_deep_long_or_crowded_queries_are_left_out
    deep = "https://a.example/p?x#{'[a]' * 2_000}=1"
    assert_equal 'https://a.example/p', WatchClient::Filter.url(deep, [])
    assert_equal 'https://a.example/p', WatchClient::Filter.url("https://a.example/p?q=#{'a' * 5_000}", [])
    crowded = "https://a.example/p?#{(1..150).map { |n| "p#{n}=1" }.join('&')}"
    assert_equal 'https://a.example/p', WatchClient::Filter.url(crowded, [])
  end

  def test_deeply_nested_referrer_reports_safely
    env = { 'HTTP_REFERER' => "https://other.example/?x#{'[a]' * 2_000}=1" }
    request = FakeRequest.new(env: env, path: '/', filtered_path: '/')
    notice = WatchClient::Notice.build(@config, RuntimeError.new('x'), handled: true, request: request)
    assert_equal 'https://other.example/', notice['request']['referrer']
  end

  def test_circular_and_deep_data_is_bounded
    loop_hash = { 'a' => 1 }
    loop_hash['self'] = loop_hash
    shared = { 'v' => 1 }
    deep = (1..100).reduce('end') { |inner, _| { 'n' => inner } }
    safe = WatchClient::Entry.json_safe('loop' => loop_hash, 'twice' => [shared, shared], 'deep' => deep, 'nan' => Float::NAN)
    JSON.generate(safe)
    assert_equal '[CIRCULAR]', safe['loop']['self']
    assert_equal [{ 'v' => 1 }, { 'v' => 1 }], safe['twice']
    assert_includes JSON.generate(safe['deep']), '[TOO DEEP]'
    assert_equal 'NaN', safe['nan']
  end

  def test_circular_data_from_callbacks_never_raises_into_the_app
    enable_without_sending
    @config.before_send = lambda do |line|
      line['self'] = line
      line
    end
    @config.before_notify = lambda do |notice, _error|
      notice['context'] = { 'loop' => notice }
      notice
    end
    refute WatchClient.enqueue(:info, 'hello')
    refute WatchClient.notify(RuntimeError.new('boom'))
  end

  def test_core_fields_are_bounded_too
    built = entry(context: { request_id: 'r' * 2_000_000, user_id: 'u' * 2_000_000 }, message: 'm' * 100_000)
    assert_operator JSON.generate(built).bytesize, :<=, WatchClient::Entry::MAX_ENTRY_BYTES
    assert_equal WatchClient::Entry::MAX_CORE_CHARS, built['request_id'].length
  end

  def test_entries_with_nan_still_build_and_encode
    built = entry(message: { event: 'calc', ratio: Float::NAN, inf: Float::INFINITY })
    JSON.generate(built)
    assert_equal 'NaN', built['ratio']
  end
end
