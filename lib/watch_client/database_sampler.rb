require "time"
require "watch_client/sql_normalizer"

module WatchClient
  # Reads PostgreSQL's own statistics over one of the app's pooled connections:
  # health (every minute), top queries (pg_stat_statements) and tables (hourly).
  #
  # Only SELECTs on statistics views, a 2-second statement timeout per group of queries, and nothing at
  # all while the pool is busy, so sampling can never take a connection from the app.
  # `pool` is an ActiveRecord connection pool (anything with #with_connection and #stat).
  class DatabaseSampler
    STATEMENT_TIMEOUT_MS = 2_000
    TOP_QUERIES = 20
    TABLES = 30

    HEALTH_SQL = <<~SQL.freeze
      SELECT
        current_setting('max_connections')::int AS max_connections,
        count(*) FILTER (WHERE backend_type = 'client backend') AS connections,
        count(*) FILTER (WHERE datname = current_database() AND backend_type = 'client backend') AS database_connections,
        count(*) FILTER (WHERE datname = current_database() AND state = 'active') AS active,
        count(*) FILTER (WHERE datname = current_database() AND state = 'idle') AS idle,
        count(*) FILTER (WHERE datname = current_database() AND state LIKE 'idle in transaction%') AS idle_in_transaction,
        count(*) FILTER (WHERE datname = current_database() AND wait_event_type = 'Lock') AS waiting_on_locks,
        coalesce(max(extract(epoch FROM now() - query_start)) FILTER (
          WHERE datname = current_database() AND state = 'active' AND backend_type = 'client backend' AND pid <> pg_backend_pid()), 0) AS longest_query_s,
        coalesce(max(extract(epoch FROM now() - xact_start)) FILTER (
          WHERE datname = current_database() AND state LIKE 'idle in transaction%'), 0) AS longest_idle_transaction_s
      FROM pg_stat_activity
    SQL

    LONGEST_QUERY_SQL = <<~SQL.freeze
      SELECT query FROM pg_stat_activity
      WHERE datname = current_database() AND state = 'active' AND backend_type = 'client backend'
        AND pid <> pg_backend_pid() AND query_start < now() - interval '1 second'
      ORDER BY query_start LIMIT 1
    SQL

    COUNTERS_SQL = <<~SQL.freeze
      SELECT xact_commit, xact_rollback, blks_hit, blks_read, deadlocks, temp_bytes,
             pg_database_size(current_database()) AS size_bytes,
             CASE WHEN pg_is_in_recovery() THEN extract(epoch FROM now() - pg_last_xact_replay_timestamp()) END AS replica_lag_s
      FROM pg_stat_database WHERE datname = current_database()
    SQL

    TOP_QUERIES_SQL = <<~SQL.freeze
      SELECT queryid::text AS queryid, query, calls, %<total>s AS total_ms, %<mean>s AS mean_ms, rows
      FROM pg_stat_statements
      WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        AND query NOT ILIKE '%%pg_stat_statements%%'
      ORDER BY %<total>s DESC LIMIT #{TOP_QUERIES}
    SQL

    TABLES_SQL = <<~SQL.freeze
      SELECT n.nspname AS schema, c.relname AS name,
             pg_total_relation_size(c.oid) AS total_bytes, pg_relation_size(c.oid) AS table_bytes,
             pg_indexes_size(c.oid) AS index_bytes,
             s.n_live_tup AS live_rows, s.n_dead_tup AS dead_rows, s.seq_scan, s.idx_scan,
             greatest(s.last_vacuum, s.last_autovacuum) AS last_vacuum_at,
             greatest(s.last_analyze, s.last_autoanalyze) AS last_analyze_at
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
      WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
      ORDER BY pg_total_relation_size(c.oid) DESC LIMIT #{TABLES}
    SQL

    UNUSED_INDEXES_SQL = <<~SQL.freeze
      SELECT s.schemaname AS schema, s.relname AS table, s.indexrelname AS name,
             pg_relation_size(s.indexrelid) AS bytes, s.idx_scan AS scans
      FROM pg_stat_user_indexes s
      JOIN pg_index i ON i.indexrelid = s.indexrelid
      WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
        AND pg_relation_size(s.indexrelid) > 1048576
      ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT #{TABLES}
    SQL

    def initialize(pool)
      @pool = pool
      @previous = nil
    end

    # Rails connection pool numbers for this process.
    def pool_stats
      stat = @pool.stat
      { "size" => stat[:size], "connections" => stat[:connections], "busy" => stat[:busy], "idle" => stat[:idle],
        "waiting" => stat[:waiting], "dead" => stat[:dead] }.compact
    rescue StandardError
      nil
    end

    def pool_free?
      stat = @pool.stat
      stat[:waiting].to_i.zero? && stat[:busy].to_i < stat[:size].to_i
    rescue StandardError
      false
    end

    def postgresql?
      @postgresql = @pool.db_config.adapter.to_s.match?(/postg/i) if @postgresql.nil?
      @postgresql
    rescue StandardError
      @postgresql = false
    end

    def health(now: Time.now)
      return nil unless postgresql? && pool_free?

      activity, counters, longest = read_only do |connection|
        [ select_one(connection, HEALTH_SQL), select_one(connection, COUNTERS_SQL), select_one(connection, LONGEST_QUERY_SQL) ]
      end
      return nil unless activity && counters

      result = {
        "max_connections" => int(activity["max_connections"]), "connections" => int(activity["connections"]),
        "database_connections" => int(activity["database_connections"]), "active" => int(activity["active"]),
        "idle" => int(activity["idle"]), "idle_in_transaction" => int(activity["idle_in_transaction"]),
        "waiting_on_locks" => int(activity["waiting_on_locks"]),
        "longest_query_s" => float(activity["longest_query_s"])&.round(1),
        "longest_idle_transaction_s" => float(activity["longest_idle_transaction_s"])&.round(1),
        "size_bytes" => int(counters["size_bytes"]), "replica_lag_s" => float(counters["replica_lag_s"])&.round(1)
      }
      result["longest_query"] = SqlNormalizer.normalize(longest["query"])[0, 500] if longest && result["longest_query_s"].to_f >= 1
      result.merge!(rates(counters, now))
      result.compact
    end

    # The heaviest queries since PostgreSQL's statistics were last reset.
    def top_queries
      return nil unless postgresql? && pool_free?

      read_only do |connection|
        installed = select_one(connection, "SELECT 1 AS ok FROM pg_extension WHERE extname = 'pg_stat_statements'")
        next { "available" => false, "reason" => "The pg_stat_statements extension is not installed in this database." } unless installed

        # PostgreSQL 13+ calls the columns total_exec_time / mean_exec_time; 12 and older total_time / mean_time.
        modern = select_one(connection, "SELECT 1 AS ok FROM information_schema.columns " \
                                        "WHERE table_name = 'pg_stat_statements' AND column_name = 'total_exec_time'")
        columns = modern ? { total: "total_exec_time", mean: "mean_exec_time" } : { total: "total_time", mean: "mean_time" }
        rows = select_all(connection, format(TOP_QUERIES_SQL, **columns))
        queries = rows.map do |row|
          { "queryid" => row["queryid"].to_s, "sql" => SqlNormalizer.normalize(row["query"]), "calls" => int(row["calls"]),
            "total_ms" => float(row["total_ms"])&.round(1), "mean_ms" => float(row["mean_ms"])&.round(2), "rows" => int(row["rows"]) }
        end
        { "available" => true, "queries" => queries }
      end
    rescue StandardError => e
      { "available" => false, "reason" => e.message.lines.first.to_s.strip[0, 300] }
    end

    def tables
      return nil unless postgresql? && pool_free?

      read_only do |connection|
        tables = select_all(connection, TABLES_SQL).map do |row|
          { "schema" => row["schema"], "name" => row["name"], "total_bytes" => int(row["total_bytes"]),
            "table_bytes" => int(row["table_bytes"]), "index_bytes" => int(row["index_bytes"]),
            "live_rows" => int(row["live_rows"]), "dead_rows" => int(row["dead_rows"]), "seq_scan" => int(row["seq_scan"]),
            "idx_scan" => int(row["idx_scan"]), "last_vacuum_at" => time(row["last_vacuum_at"]),
            "last_analyze_at" => time(row["last_analyze_at"]) }.compact
        end
        unused = select_all(connection, UNUSED_INDEXES_SQL).map do |row|
          { "schema" => row["schema"], "table" => row["table"], "name" => row["name"], "bytes" => int(row["bytes"]),
            "scans" => int(row["scans"]) }
        end
        { "tables" => tables, "unused_indexes" => unused }
      end
    end

    private

    # Per-second rates and ratios since the previous sample of this process.
    def rates(counters, now)
      current = { at: now.to_f, commits: int(counters["xact_commit"]), rollbacks: int(counters["xact_rollback"]),
                  hits: int(counters["blks_hit"]), reads: int(counters["blks_read"]),
                  deadlocks: int(counters["deadlocks"]), temp_bytes: int(counters["temp_bytes"]) }
      previous = @previous
      @previous = current
      return {} unless previous

      elapsed = current[:at] - previous[:at]
      delta = ->(key) { (current[key] || 0) - (previous[key] || 0) }
      # Counters went backwards: statistics were reset. Skip this round.
      return {} if elapsed <= 0 || %i[commits rollbacks hits reads deadlocks].any? { |key| delta.call(key).negative? }

      blocks = delta.call(:hits) + delta.call(:reads)
      { "commits_per_s" => (delta.call(:commits) / elapsed).round(2), "rollbacks_per_s" => (delta.call(:rollbacks) / elapsed).round(2),
        "cache_hit_ratio" => blocks.positive? ? (delta.call(:hits).to_f / blocks).round(4) : nil,
        "deadlocks" => delta.call(:deadlocks), "temp_bytes" => [ delta.call(:temp_bytes), 0 ].max }
    end

    # One short read-only transaction with a statement timeout; our own queries are
    # marked internal so they never show up as the app's slow queries or breadcrumbs.
    def read_only
      Thread.current[:watch_client_internal] = true
      @pool.with_connection do |connection|
        connection.transaction(requires_new: true) do
          connection.execute("SET LOCAL statement_timeout = #{STATEMENT_TIMEOUT_MS}")
          yield connection
        end
      end
    ensure
      Thread.current[:watch_client_internal] = nil
    end

    def select_all(connection, sql)
      connection.select_all(sql, "WatchClient").to_a
    end

    def select_one(connection, sql)
      select_all(connection, sql).first
    end

    def int(value)
      value.nil? ? nil : value.to_i
    end

    def float(value)
      value.nil? ? nil : value.to_f
    end

    def time(value)
      return nil if value.nil?

      value.respond_to?(:utc) ? value.utc.iso8601 : value.to_s
    end
  end
end
