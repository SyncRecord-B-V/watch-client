require "socket"

module WatchClient
  # Facts about the running app sent with each error: host, process, versions, memory and load.
  module AppEnv
    module_function

    def snapshot(config)
      {
        "environment_name" => config.environment.to_s,
        "hostname" => config.host,
        "project_root" => (config.app_root.to_s.empty? ? nil : config.app_root.to_s),
        "revision" => config.app_version,
        "pid" => Process.pid,
        "ruby_version" => RUBY_VERSION,
        "rails_version" => (defined?(Rails) && Rails.respond_to?(:version) ? Rails.version : nil),
        "stats" => stats
      }.compact
    rescue StandardError
      {}
    end

    # Memory (MB) and load average, where the OS exposes them (Linux /proc).
    def stats
      out = {}
      if File.readable?("/proc/self/status") && (rss = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1])
        out["rss_mb"] = (rss.to_i / 1024.0).round(1)
      end
      if File.readable?("/proc/loadavg")
        out["load"] = File.read("/proc/loadavg").split.first(3).map(&:to_f)
      end
      out.empty? ? nil : out
    rescue StandardError
      nil
    end
  end
end
