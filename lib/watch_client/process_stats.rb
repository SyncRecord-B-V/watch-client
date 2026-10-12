require "time"

module WatchClient
  # Health of this process, sampled once a minute: memory (RSS), garbage collection
  # since the last sample, threads, uptime and, in Puma, busy threads and backlog.
  class ProcessStats
    STARTED_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class << self
      # Puma's server for this process, seen by the Rack middleware during a request.
      attr_accessor :puma_server
    end

    def initialize
      @previous_gc = nil
    end

    def sample
      gc = gc_counters
      previous = @previous_gc
      @previous_gc = gc
      delta = ->(key) { previous ? [ gc[key] - previous[key], 0 ].max : nil }
      {
        "role" => role, "rss_mb" => rss_mb, "threads" => Thread.list.size,
        "uptime_s" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - STARTED_AT).round,
        "gc_count" => delta.call(:count), "gc_major" => delta.call(:major), "gc_time_ms" => delta.call(:time_ms),
        "heap_live_slots" => GC.stat[:heap_live_slots], "puma" => puma
      }.compact
    rescue StandardError
      { "role" => role }
    end

    # Resident memory in MB: /proc on Linux, ps elsewhere (macOS).
    def rss_mb
      if File.readable?("/proc/self/status")
        line = File.foreach("/proc/self/status").find { |l| l.start_with?("VmRSS:") }
        return (line.split[1].to_i / 1024.0).round(1) if line
      end
      kb = `ps -o rss= -p #{Process.pid} 2>/dev/null`.to_i
      kb.positive? ? (kb / 1024.0).round(1) : nil
    rescue StandardError
      nil
    end

    def role
      return "web" if self.class.puma_server || defined?(::Rails::Server)
      return "worker" if defined?(::Sidekiq) && ::Sidekiq.respond_to?(:server?) && ::Sidekiq.server?
      return "worker" if $PROGRAM_NAME.to_s.match?(/solid.?queue|jobs|good_job|delayed/i)

      "other"
    end

    private

    def gc_counters
      stat = GC.stat
      time = stat[:time] || (GC.respond_to?(:total_time) ? GC.total_time / 1_000_000 : 0) # ms (Ruby 3.1+)
      { count: stat[:count].to_i, major: stat[:major_gc_count].to_i, time_ms: time.to_i }
    end

    def puma
      server = self.class.puma_server
      return nil unless server.respond_to?(:stats)

      stats = server.stats
      { "running" => stats[:running], "max_threads" => stats[:max_threads], "pool_capacity" => stats[:pool_capacity],
        "backlog" => stats[:backlog], "requests_count" => stats[:requests_count] }.compact
    rescue StandardError
      nil
    end
  end
end
