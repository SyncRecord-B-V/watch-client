require "time"
require "watch_client/sql_normalizer"
require "watch_client/context"

module WatchClient
  # Collects queries slower than `slow_query_ms` (from ActiveSupport's
  # "sql.active_record" events), grouped by normalized SQL, until the database
  # monitor takes them (once a minute). Cheap for fast queries: one comparison.
  class SlowQueries
    MAX_GROUPS = 200
    GEM_LIB = File.expand_path("..", __dir__)

    def initialize(config)
      @config = config
      @mutex = Mutex.new
      @groups = {}
      @dropped = 0
    end

    # Called for every SQL event; only slow ones do any work.
    def record(sql:, duration_ms:, name: nil, cached: false, at: Time.now)
      return false if duration_ms < @config.slow_query_ms.to_f
      return false if cached || name.to_s == "SCHEMA" || name.to_s == "CACHE"
      return false if Thread.current[:watch_client_internal]
      return false if SqlNormalizer.transaction_statement?(sql)

      normalized = SqlNormalizer.normalize(sql)
      key = SqlNormalizer.fingerprint(normalized)
      request_id = Context.request_id
      @mutex.synchronize do
        group = @groups[key]
        unless group
          if @groups.size >= MAX_GROUPS
            @dropped += 1
            return false
          end
          group = @groups[key] = { "fingerprint" => key, "sql" => normalized, "name" => name.to_s[0, 100],
                                   "count" => 0, "total_ms" => 0.0, "max_ms" => 0.0,
                                   "location" => app_location, "first_at" => at.utc.iso8601(3) }
        end
        group["count"] += 1
        group["total_ms"] += duration_ms
        group["last_at"] = at.utc.iso8601(3)
        if duration_ms >= group["max_ms"]
          group["max_ms"] = duration_ms
          group["request_id"] = request_id
        end
      end
      true
    rescue StandardError
      false
    end

    # The collected groups (rounded), emptying the buffer.
    def take
      groups = @mutex.synchronize do
        taken = @groups.values
        @groups = {}
        taken
      end
      groups.filter_map do |group|
        group["total_ms"] = group["total_ms"].round(1)
        group["max_ms"] = group["max_ms"].round(1)
        group.compact!
        @config.before_send_query ? @config.before_send_query.call(group) : group
      end
    rescue StandardError
      []
    end

    def size
      @mutex.synchronize { @groups.size }
    end

    private

    # The first line of the app's own code that ran the query ("app/models/invoice.rb:42:in 'overdue'").
    def app_location
      root = @config.app_root.to_s
      return nil if root.empty?

      caller_locations(3, 200)&.each do |location|
        path = location.absolute_path || location.path
        next unless path&.start_with?(root)
        next if path.start_with?(GEM_LIB)

        relative = path.delete_prefix(root).delete_prefix("/")
        next if relative.start_with?("vendor/", "bin/", "config/initializers/watch_client")

        return "#{relative}:#{location.lineno}:in '#{location.label}'"
      end
      nil
    end
  end
end
