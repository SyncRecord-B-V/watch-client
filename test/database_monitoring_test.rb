require "test_helper"

class SqlNormalizerTest < Minitest::Test
  def normalize(sql) = WatchClient::SqlNormalizer.normalize(sql)

  def test_removes_values
    assert_equal "SELECT * FROM users WHERE email = ? AND id IN (?) LIMIT ?",
                 normalize("SELECT * FROM users WHERE email = 'a@b.c' AND id IN (1, 2, 3) LIMIT 10")
  end

  def test_bind_params_numbers_booleans_and_comments
    sql = %(SELECT "invoices".* FROM "invoices" /*application:Billing,controller:invoices*/ WHERE "invoices"."account_id" = $1 AND paid = TRUE AND total > 10.5 -- note)
    assert_equal %(SELECT "invoices".* FROM "invoices" WHERE "invoices"."account_id" = ? AND paid = ? AND total > ?), normalize(sql)
  end

  def test_keeps_identifiers_with_digits_and_collapses_value_rows
    assert_equal %(INSERT INTO "table_2023" ("v1", "v2") VALUES (?)),
                 normalize(%(INSERT INTO "table_2023" ("v1", "v2") VALUES (1, 'a'), (2, 'b'), (3, 'it''s')))
  end

  def test_tagged_dollar_quotes
    assert_equal "SELECT ? AS body, ? AS other",
                 normalize("SELECT $body$jan@example.nl$body$ AS body, $$secret$$ AS other")
  end

  def test_cut_off_value_is_dropped
    # pg_stat_activity stops at 1 KB, sometimes inside a string: its tail must not leak.
    assert_equal "SELECT * FROM users WHERE email = ?…",
                 normalize("SELECT * FROM users WHERE email = 'jan@exam")
    assert_equal "DO ?…", normalize("DO $fn$ BEGIN RAISE NOTICE 'jan@example.nl")
  end

  def test_same_shape_same_fingerprint
    a = WatchClient::SqlNormalizer.fingerprint(normalize("SELECT * FROM t WHERE id = 1"))
    b = WatchClient::SqlNormalizer.fingerprint(normalize("select *  from t where id = 99"))
    assert_equal a, b
  end

  def test_transaction_statements
    assert WatchClient::SqlNormalizer.transaction_statement?("COMMIT")
    assert WatchClient::SqlNormalizer.transaction_statement?("  SAVEPOINT active_record_1")
    refute WatchClient::SqlNormalizer.transaction_statement?("SELECT 1")
  end
end

class SlowQueriesTest < Minitest::Test
  def setup
    @config = WatchClient::Configuration.new
    @config.slow_query_ms = 100
    @config.app_root = File.expand_path("..", __dir__)
    @slow = WatchClient::SlowQueries.new(@config)
  end

  def test_groups_slow_queries_and_ignores_fast_ones
    refute @slow.record(sql: "SELECT * FROM users WHERE id = 1", duration_ms: 5)
    assert @slow.record(sql: "SELECT * FROM users WHERE id = 1", duration_ms: 150, name: "User Load")
    WatchClient::Context.with(request_id: "req-9") do
      assert @slow.record(sql: "SELECT * FROM users WHERE id = 2", duration_ms: 400, name: "User Load")
    end
    groups = @slow.take
    assert_equal 1, groups.size
    group = groups.first
    assert_equal "SELECT * FROM users WHERE id = ?", group["sql"]
    assert_equal 2, group["count"]
    assert_equal 550.0, group["total_ms"]
    assert_equal 400.0, group["max_ms"]
    assert_equal "req-9", group["request_id"]
    assert_match %r{\Atest/database_monitoring_test\.rb:\d+:in}, group["location"]
    assert_empty @slow.take
  end

  def test_skips_schema_cached_transactions_and_internal_queries
    refute @slow.record(sql: "SELECT a.attname FROM pg_attribute", duration_ms: 500, name: "SCHEMA")
    refute @slow.record(sql: "SELECT 1", duration_ms: 500, cached: true)
    refute @slow.record(sql: "COMMIT", duration_ms: 500)
    Thread.current[:watch_client_internal] = true
    refute @slow.record(sql: "SELECT 1", duration_ms: 500)
  ensure
    Thread.current[:watch_client_internal] = nil
  end

  def test_before_send_query_can_drop
    @config.before_send_query = ->(query) { query["sql"].include?("secrets") ? nil : query }
    @slow.record(sql: "SELECT * FROM secrets", duration_ms: 200)
    @slow.record(sql: "SELECT * FROM invoices", duration_ms: 200)
    assert_equal [ "SELECT * FROM invoices" ], @slow.take.map { |query| query["sql"] }
  end
end

# A stand-in for an ActiveRecord pool + PostgreSQL connection that answers by SQL.
class FakePool
  DbConfig = Struct.new(:adapter)
  attr_accessor :stat, :answers, :executed

  def initialize(answers)
    @answers = answers
    @stat = { size: 5, connections: 2, busy: 1, idle: 1, waiting: 0, dead: 0 }
    @executed = []
  end

  def db_config = DbConfig.new("postgresql")
  def with_connection = yield(self)
  def transaction(**) = yield
  def execute(sql) = @executed << sql

  def select_all(sql, _name = nil)
    @answers.each { |pattern, rows| return rows.respond_to?(:call) ? rows.call : rows if sql.include?(pattern) }
    []
  end
end

class DatabaseSamplerTest < Minitest::Test
  def setup
    @counters = { "xact_commit" => 1_000, "xact_rollback" => 10, "blks_hit" => 9_000, "blks_read" => 1_000,
                  "deadlocks" => 0, "temp_bytes" => 0, "size_bytes" => 52_428_800, "replica_lag_s" => nil }
    @pool = FakePool.new(
      "max_connections" => [ { "max_connections" => "100", "connections" => "12", "database_connections" => "9",
                              "active" => "2", "idle" => "6", "idle_in_transaction" => "1", "waiting_on_locks" => "0",
                              "longest_query_s" => "3.25", "longest_idle_transaction_s" => "12" } ],
      "pg_stat_database" => -> { [ @counters ] },
      "ORDER BY query_start" => [ { "query" => "SELECT * FROM reports WHERE month = '2026-10'" } ],
      "pg_extension" => [],
      "pg_total_relation_size" => [ { "schema" => "public", "name" => "log_entries", "total_bytes" => "1000", "table_bytes" => "800",
                                     "index_bytes" => "200", "live_rows" => "10", "dead_rows" => "1" } ],
      "pg_stat_user_indexes" => [ { "schema" => "public", "table" => "log_entries", "name" => "idx_old", "bytes" => "2000000", "scans" => "0" } ]
    )
    @sampler = WatchClient::DatabaseSampler.new(@pool)
  end

  def test_health_with_rates_from_the_second_sample
    first = @sampler.health(now: Time.at(1_000))
    assert_equal 100, first["max_connections"]
    assert_equal 12, first["connections"]
    assert_equal 3.3, first["longest_query_s"]
    assert_equal "SELECT * FROM reports WHERE month = ?", first["longest_query"]
    refute first.key?("commits_per_s")
    assert_includes @pool.executed, "SET LOCAL statement_timeout = 2000"

    @counters = @counters.merge("xact_commit" => 1_600, "blks_hit" => 9_900, "blks_read" => 1_100, "deadlocks" => 1)
    second = @sampler.health(now: Time.at(1_060))
    assert_equal 10.0, second["commits_per_s"]
    assert_equal 0.9, second["cache_hit_ratio"]
    assert_equal 1, second["deadlocks"]
  end

  def test_nothing_while_the_pool_is_busy
    @pool.stat = @pool.stat.merge(busy: 5)
    assert_nil @sampler.health
    assert_equal 5, @sampler.pool_stats["busy"]
  end

  def test_top_queries_without_the_extension
    result = @sampler.top_queries
    refute result["available"]
    assert_includes result["reason"], "not installed"
  end

  def test_top_queries
    @pool.answers["pg_extension"] = [ { "ok" => 1 } ]
    @pool.answers["information_schema.columns"] = [ { "ok" => 1 } ]
    @pool.answers["FROM pg_stat_statements"] = [ { "queryid" => "42", "query" => "SELECT * FROM t WHERE a = $1", "calls" => "7",
                                                  "total_ms" => "1234.567", "mean_ms" => "176.36", "rows" => "70" } ]
    result = @sampler.top_queries
    assert result["available"]
    assert_equal({ "queryid" => "42", "sql" => "SELECT * FROM t WHERE a = ?", "calls" => 7, "total_ms" => 1234.6,
                   "mean_ms" => 176.36, "rows" => 70 }, result["queries"].first)
  end

  def test_tables
    result = @sampler.tables
    assert_equal "log_entries", result["tables"].first["name"]
    assert_equal 1000, result["tables"].first["total_bytes"]
    assert_equal "idx_old", result["unused_indexes"].first["name"]
  end
end

class DatabaseMonitorTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    configure_for(@hub, slow_query_ms: 100)
    @pool = FakePool.new({})
    @monitor = WatchClient::DatabaseMonitor.new(WatchClient.configuration, pool: @pool)
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def test_sends_pool_health_and_slow_queries
    @monitor.slow_queries.record(sql: "SELECT * FROM invoices WHERE id = 7", duration_ms: 250)
    assert @monitor.send_once
    request = @hub.next_request
    assert_equal "/api/v1/database", request.path
    body = request.json
    assert_equal "web-1", body["host"]
    assert_equal 5, body["pool"]["size"]
    assert_equal "SELECT * FROM invoices WHERE id = ?", body["slow_queries"].first["sql"]
    assert body.key?("top_queries"), "first round includes top queries"
    refute body.key?("tables")
  end

  def test_observes_active_support_style_events
    event = Struct.new(:payload, :duration).new({ sql: "SELECT pg_sleep(1)", name: "SQL" }, 1000.0)
    @monitor.define_singleton_method(:ensure_running) { nil } # no background thread in this test
    @monitor.observe(event)
    assert_equal 1, @monitor.slow_queries.size
  end
end
