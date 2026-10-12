require "time"
require "syncrecord_watch/histogram"
require "syncrecord_watch/process_stats"
require "syncrecord_watch/job_queues"

module SyncRecordWatch
  # Performance numbers, added up per minute and sent once a minute to
  # POST /api/v1/metrics by a background thread (one per process, started by the
  # first request or outgoing call in that process):
  #   requests: per controller action: count, 5xx errors, total / slowest time,
  #             time in the database, views and outgoing HTTP, response-time histogram
  #   http:     per outside host the app calls: count, 5xx / 4xx, failures (timeouts,
  #             connection errors), total / slowest time, histogram
  #   jobs:     per job class: runs, failures, total / slowest time, histogram, time waited in the queue
  #   queues:   queue sizes and oldest job's wait, failed / retrying / dead / scheduled (job backend)
  #   process:  memory, garbage collection, threads, Puma busy threads and backlog
  class Metrics
    MAX_ENDPOINTS = 300
    MAX_HOSTS = 100
    MAX_JOB_CLASSES = 200
    MIN_INTERVAL = 15

    class << self
      attr_reader :instance

      def install!(config = SyncRecordWatch.configuration)
        @instance ||= new(config) if config.performance_monitoring
      end

      def uninstall!
        @instance&.stop
        @instance = nil
      end

      # Called from the request subscriber and the Net::HTTP hook; cheap when off.
      def record_request(**fields)
        @instance&.record_request(**fields)
      end

      def record_http(**fields)
        @instance&.record_http(**fields)
      end

      def record_job(**fields)
        @instance&.record_job(**fields)
      end
    end

    def initialize(config, transport: nil)
      @config = config
      @transport = transport
      @mutex = Mutex.new
      @requests = {}
      @http = {}
      @jobs = {}
      @process = ProcessStats.new
      @thread = nil
      @pid = nil
    end

    def record_request(endpoint:, duration_ms:, status: nil, db_ms: nil, view_ms: nil, http_ms: nil)
      return if endpoint.to_s.empty?

      @mutex.synchronize do
        row = @requests[endpoint] ||= begin
          return if @requests.size >= MAX_ENDPOINTS

          new_row.merge("db_ms" => 0.0, "view_ms" => 0.0, "http_ms" => 0.0)
        end
        add(row, duration_ms)
        row["errors"] += 1 if status.to_i >= 500
        row["db_ms"] += db_ms.to_f
        row["view_ms"] += view_ms.to_f
        row["http_ms"] += http_ms.to_f
      end
      ensure_running
    rescue StandardError
      nil
    end

    # failure: "timeout" or "connection" when the call raised instead of answering.
    def record_http(host:, duration_ms:, status: nil, failure: nil)
      return if host.to_s.empty?

      @mutex.synchronize do
        row = @http[host] ||= begin
          return if @http.size >= MAX_HOSTS

          new_row.merge("client_errors" => 0, "timeouts" => 0, "failures" => 0)
        end
        add(row, duration_ms)
        code = status.to_i
        row["errors"] += 1 if code >= 500 || failure
        row["client_errors"] += 1 if code.between?(400, 499)
        row["failures"] += 1 if failure
        row["timeouts"] += 1 if failure == "timeout"
      end
      ensure_running
    rescue StandardError
      nil
    end

    # wait_ms: time between enqueue (or the scheduled time) and the start of the run.
    def record_job(job_class:, duration_ms:, queue: nil, failed: false, wait_ms: nil)
      return if job_class.to_s.empty?

      @mutex.synchronize do
        row = @jobs[job_class] ||= begin
          return if @jobs.size >= MAX_JOB_CLASSES

          new_row.merge("queue" => queue.to_s, "wait_ms" => 0.0, "wait_max_ms" => 0.0)
        end
        add(row, duration_ms)
        row["errors"] += 1 if failed
        if wait_ms
          wait = [ wait_ms.to_f, 0 ].max
          row["wait_ms"] += wait
          row["wait_max_ms"] = wait if wait > row["wait_max_ms"]
        end
      end
      ensure_running
    rescue StandardError
      nil
    end

    # The minute's numbers, emptying the buffers. Public for tests.
    def build_payload(now: Time.now)
      requests, http, jobs = @mutex.synchronize do
        taken = [ @requests, @http, @jobs ]
        @requests = {}
        @http = {}
        @jobs = {}
        taken
      end
      {
        "sampled_at" => now.utc.iso8601, "host" => @config.host.to_s, "pid" => Process.pid,
        "environment" => @config.environment.to_s, "version" => @config.app_version,
        "requests" => requests.map { |name, row| finish(row).merge("endpoint" => name) },
        "http" => http.map { |name, row| finish(row).merge("host" => name) },
        "jobs" => jobs.map { |name, row| finish(row).merge("job_class" => name) },
        "queues" => (@config.job_queue_monitoring ? JobQueues.sample : nil),
        "process" => (@config.process_monitoring ? @process.sample : nil)
      }.compact
    end

    def send_once(now: Time.now)
      payload = build_payload(now: now)
      return true if %w[requests http jobs].all? { |key| payload[key].empty? } && !payload["process"] && !payload["queues"]

      result = transport.post(payload)
      result = transport.post(payload) if result.retry?
      SyncRecordWatch.diagnose("metrics not sent: #{result.error || "HTTP #{result.code}"}") unless result.ok?
      result.ok?
    rescue StandardError => e
      SyncRecordWatch.diagnose("metrics failed: #{e.class}: #{e.message}")
      false
    end

    def ensure_running
      return if @pid == Process.pid && @thread&.alive?

      @mutex.synchronize do
        return if @pid == Process.pid && @thread&.alive?

        @pid = Process.pid
        @thread = Thread.new { run }
        @thread.name = "watch-metrics" if @thread.respond_to?(:name=)
      end
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    private

    def new_row
      { "count" => 0, "errors" => 0, "total_ms" => 0.0, "max_ms" => 0.0, "buckets" => Histogram.empty }
    end

    def add(row, duration_ms)
      ms = duration_ms.to_f
      row["count"] += 1
      row["total_ms"] += ms
      row["max_ms"] = ms if ms > row["max_ms"]
      row["buckets"][Histogram.index(ms)] += 1
    end

    def finish(row)
      row.transform_values { |value| value.is_a?(Float) ? value.round(1) : value }
    end

    def interval
      [ @config.database_interval.to_i, MIN_INTERVAL ].max
    end

    def run
      loop do
        sleep(interval)
        send_once
      end
    rescue StandardError => e
      SyncRecordWatch.diagnose("metrics thread stopped: #{e.class}: #{e.message}")
    end

    def transport
      @transport ||= Transport.new(@config, **Transport::METRICS)
    end
  end
end
