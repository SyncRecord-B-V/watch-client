# frozen_string_literal: true

require 'digest'
require 'time'

module WatchClient
  # Tells Watch which gem versions the app runs (from Gemfile.lock), plus Ruby and
  # Rails, so it can warn about gems with known vulnerabilities. Sent once per boot
  # of a server or worker process (POST /api/v1/dependencies); Watch ignores
  # reports it has already seen.
  module Dependencies
    module_function

    def payload(config = WatchClient.configuration, lockfile: default_lockfile)
      gems = parse(lockfile)
      return nil if gems.empty?

      {
        'environment' => config.environment.to_s, 'host' => config.host.to_s, 'version' => config.app_version,
        'ruby' => RUBY_VERSION, 'rails' => (defined?(::Rails) && ::Rails.respond_to?(:version) ? ::Rails.version : nil),
        'gems' => gems, 'digest' => digest(gems)
      }.compact
    end

    # Changes only when a gem or version changes (order doesn't matter).
    def digest(gems)
      Digest::SHA256.hexdigest(gems.map { |gem| "#{gem['name']} #{gem['version']}" }.sort.join("\n"))
    end

    # [{ "name" => "rack", "version" => "3.1.8" }, ...] from a Gemfile.lock (the GEM / GIT / PATH specs).
    def parse(lockfile)
      return [] unless lockfile && File.file?(lockfile)

      text = File.read(lockfile)
      if defined?(::Bundler::LockfileParser)
        ::Bundler::LockfileParser.new(text).specs.map do |spec|
          { 'name' => spec.name, 'version' => spec.version.to_s }
        end.uniq
      else
        # "    nokogiri (1.15.4-arm64-darwin)": the platform after the first "-" isn't part of the version.
        text.scan(/^    ([A-Za-z0-9_.-]+) \(([^)\s,]+)\)$/).map do |name, version|
          { 'name' => name, 'version' => version.split('-').first }
        end.uniq
      end
    rescue StandardError
      []
    end

    def default_lockfile
      defined?(::Bundler) && ::Bundler.respond_to?(:default_lockfile) ? ::Bundler.default_lockfile.to_s : nil
    rescue StandardError
      nil
    end

    def report!(config = WatchClient.configuration)
      body = payload(config)
      return false unless body

      result = Transport.new(config, **Transport::DEPENDENCIES).post(body)
      WatchClient.diagnose("dependencies not sent: #{result.error || "HTTP #{result.code}"}") unless result.ok?
      result.ok?
    rescue StandardError => e
      WatchClient.diagnose("dependencies failed: #{e.class}: #{e.message}")
      false
    end

    # In the background a little after boot, only in server / worker processes
    # (not consoles, rake tasks or tests).
    def report_later(config = WatchClient.configuration, delay: 20)
      return unless config.report_dependencies && server_process?

      Thread.new do
        sleep(delay)
        report!(config)
      end
    end

    def server_process?
      defined?(::Rails::Server) || defined?(::Puma::Server) || defined?(::Sidekiq::CLI) ||
        defined?(::SolidQueue::Supervisor) && $PROGRAM_NAME.include?('jobs')
    end
  end
end
