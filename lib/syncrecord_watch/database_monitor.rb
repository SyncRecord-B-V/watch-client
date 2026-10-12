require "time"
require "syncrecord_watch/slow_queries"
require "syncrecord_watch/database_sampler"

module SyncRecordWatch
  # Database monitoring: slow queries (from "sql.active_record"), plus a sample of
  # the database every `database_interval` seconds, sent to POST /api/v1/database.
  #
  # One background thread per process, started lazily by the first query in that
  # process (so forked Puma workers and Sidekiq processes each get their own).
  # Top queries are read every 5th sample and tables every 60th.
  class DatabaseMonitor
    TOP_QUERIES_EVERY = 5
    TABLES_EVERY = 60
    MIN_INTERVAL = 15

    class << self
      attr_reader :instance

      # Subscribes to ActiveRecord's SQL events. Safe to call more than once.
      def install!(config = SyncRecordWatch.configuration)
        return @instance if @instance
        return nil unless config.database_monitoring && defined?(::ActiveSupport::Notifications)

        @instance = new(config)
        @subscriber = ::ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          @instance&.observe(*args)
        end
        @instance
      end

      def uninstall!
        ::ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        @instance&.stop
        @instance = nil
        @subscriber = nil
      end
    end

    attr_reader :slow_queries, :ticks

    def initialize(config, pool: nil, transport: nil)
      @config = config
      @slow_queries = SlowQueries.new(config)
      @pool = pool
      @transport = transport
      @mutex = Mutex.new
      @thread = nil
      @pid = nil
      @ticks = 0
    end

    # Every SQL event (ActiveSupport::Notifications arguments: name, start, finish, id, payload).
    def observe(*args)
      event = args.first
      if event.respond_to?(:payload)
        payload = event.payload
        duration = event.duration
      else
        _name, started, finished, _id, payload = args
        duration = (finished - started) * 1000.0
      end
      @slow_queries.record(sql: payload[:sql], duration_ms: duration.to_f, name: payload[:name], cached: payload[:cached])
      ensure_running
    rescue StandardError
      nil
    end

    def ensure_running
      return if @pid == Process.pid && @thread&.alive?

      @mutex.synchronize do
        return if @pid == Process.pid && @thread&.alive?

        @pid = Process.pid
        @ticks = 0
        @sampler = nil # a forked child must not reuse the parent's counters
        @thread = Thread.new { run }
        @thread.name = "watch-database" if @thread.respond_to?(:name=)
      end
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    # One round: what is sent for this interval. Public for tests and `watch:database`.
    def build_payload(now: Time.now)
      @ticks += 1
      sampler = self.sampler
      payload = {
        "sampled_at" => now.utc.iso8601, "host" => @config.host.to_s, "pid" => Process.pid,
        "environment" => @config.environment.to_s, "interval_s" => interval
      }
      if sampler
        payload["pool"] = sampler.pool_stats
        payload["health"] = sampler.health(now: now)
        payload["top_queries"] = sampler.top_queries if (@ticks % TOP_QUERIES_EVERY) == 1
        payload["tables"] = sampler.tables if (@ticks % TABLES_EVERY) == 2
      end
      payload["slow_queries"] = @slow_queries.take
      payload.compact
    end

    def send_once(now: Time.now)
      payload = build_payload(now: now)
      result = transport.post(payload)
      result = transport.post(payload) if result.retry?
      SyncRecordWatch.diagnose("database sample not sent: #{result.error || "HTTP #{result.code}"}") unless result.ok?
      result.ok?
    rescue StandardError => e
      SyncRecordWatch.diagnose("database sample failed: #{e.class}: #{e.message}")
      false
    end

    def interval
      [ @config.database_interval.to_i, MIN_INTERVAL ].max
    end

    def sampler
      @sampler ||= begin
        pool = @pool || (defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connection_pool)
        pool ? DatabaseSampler.new(pool) : nil
      end
    rescue StandardError
      nil
    end

    private

    def run
      # Spread processes over the minute so they don't all query at the same second.
      sleep(rand * [ interval / 4.0, 10 ].min)
      loop do
        sleep(interval)
        send_once
      end
    rescue StandardError => e
      SyncRecordWatch.diagnose("database monitor stopped: #{e.class}: #{e.message}")
    end

    def transport
      @transport ||= Transport.new(@config, **Transport::DATABASE)
    end
  end
end
