# frozen_string_literal: true

require 'watch_client/version'
require 'watch_client/configuration'
require 'watch_client/context'
require 'watch_client/filter'
require 'watch_client/entry'
require 'watch_client/transport'
require 'watch_client/client'
require 'watch_client/logger'
require 'watch_client/breadcrumbs'
require 'watch_client/app_env'
require 'watch_client/notice'
require 'watch_client/net_http_propagation'
require 'watch_client/job_timer'
require 'watch_client/browser_tag'
require 'watch_client/check_in'
require 'watch_client/database_monitor'
require 'watch_client/metrics'
require 'watch_client/dependencies'

# Sends a Rails app's logs to Watch.
#
#   WatchClient.configure do |c|
#     c.url      = ENV["WATCH_URL"]
#     c.api_key  = ENV["WATCH_API_KEY"]
#     c.app_name = "billing-api"
#   end
#
# In a Rails app the Railtie does the rest (see README).
module WatchClient
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
      configuration
    end

    def enabled?
      configuration.enabled?
    end

    def client
      @client ||= Client.new(configuration)
    end

    # Errors go out quickly and in small batches, on their own thread and queue.
    def error_client
      @error_client ||= Client.new(configuration, transport: Transport.new(configuration, **Transport::ERRORS),
                                                  batch_size: 20, flush_interval: 1)
    end

    # The logger the Railtie adds to Rails.logger. Usable on its own too.
    def logger
      @logger ||= Logger.new(level: configuration.min_level)
    end

    # Structured log line, e.g. WatchClient.log(:info, "invoice.sent", invoice_id: 7)
    def log(level, message, **payload)
      enqueue(level, message, payload: payload.empty? ? nil : payload)
    end

    # Adds fields to every line logged inside the block (on this thread).
    def with_context(**fields, &block)
      Context.with(fields, &block)
    end

    # Internal: builds and buffers one entry. Never raises.
    def enqueue(severity, message, payload: nil)
      return false unless enabled?
      return false if Entry.level_index(severity) < configuration.min_level_index

      entry = Entry.build(configuration, severity: severity, message: message, payload: payload)
      entry = configuration.before_send.call(entry) if configuration.before_send
      return false unless entry

      client.push(entry)
    rescue StandardError
      false
    end

    # Reports an exception to Watch's error tracking. Returns true when queued.
    #
    #   rescue Stripe::APIError => e
    #     WatchClient.notify(e, context: { order_id: order.id })
    #
    # fingerprint: errors with the same fingerprint are grouped together in Watch.
    def notify(exception, context: nil, fingerprint: nil, handled: true, component: nil, request: nil)
      return false unless exception.is_a?(Exception)
      return false unless enabled? && configuration.send_errors
      return false if Notice.ignored?(configuration, exception)
      return false unless Notice.first_report?(exception)

      notice = Notice.build(configuration, exception, handled: handled, context: context,
                                                      fingerprint: fingerprint, component: component, request: request)
      notice = configuration.before_notify.call(notice, exception) if configuration.before_notify
      return false unless notice

      error_client.push(notice)
    rescue StandardError => e
      diagnose("could not report #{exception.class}: #{e.class}: #{e.message}")
      false
    end

    # Records a deploy so Watch can show which version an error started in.
    # Sent right away (not queued). Returns true on success.
    def notify_deploy(version: configuration.app_version, environment: configuration.environment,
                      revision: nil, deployed_by: nil)
      return false unless enabled? && version

      result = Transport.new(configuration, **Transport::DEPLOYS).post(
        'version' => version.to_s, 'environment' => environment.to_s,
        'revision' => revision, 'deployed_by' => deployed_by
      )
      diagnose("deploy not recorded: #{result.error || "HTTP #{result.code}"}") unless result.ok?
      result.ok?
    end

    # Heartbeat check-in for a cron job or worker (see Uptime → Heartbeats in Watch).
    # Pass the heartbeat's token (joined to WATCH_URL) or its full ping URL.
    #
    #   WatchClient.check_in("Xk2...")                       # the job ran
    #   WatchClient.check_in("Xk2...") { InvoiceExport.run } # pings when the block succeeds,
    #                                                         # /fail (with the error) when it raises
    #
    # Synchronous with a short timeout; never raises its own errors. Returns true when
    # Watch accepted the ping (with a block: the block's result).
    def check_in(token_or_url, message: nil)
      return CheckIn.ping(configuration, token_or_url, message: message) unless block_given?

      begin
        result = yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- report, then re-raise as is
        CheckIn.ping(configuration, token_or_url, failed: true, message: "#{e.class}: #{e.message}")
        raise
      end
      CheckIn.ping(configuration, token_or_url, message: message)
      result
    end

    def flush(timeout: configuration.shutdown_timeout)
      @client&.flush(timeout: timeout)
      @error_client&.flush(timeout: timeout)
    end

    def shutdown(timeout: configuration.shutdown_timeout)
      @error_client&.shutdown(timeout: timeout)
      @client&.shutdown(timeout: timeout)
    end

    # Counters: queued, sent, batches_sent, retries, dropped_queue_full, dropped_delivery, buffered.
    def stats
      result = @client ? @client.stats : {}
      result = result.merge(errors: @error_client.stats) if @error_client
      result
    end

    def diagnose(message)
      configuration.diagnostics&.puts("[watch_client] #{message}")
    rescue StandardError
      nil
    end

    # Sends one test line right away and reports the result. Use from a console:
    #   WatchClient.test!
    def test!(out: $stdout)
      problems = configuration.validate!
      unless problems.empty?
        out.puts "Watch is not configured: #{problems.join('; ')}"
        return false
      end

      entry = Entry.build(configuration, severity: :info,
                                         message: "watch_client test from #{configuration.app_name || 'app'}",
                                         payload: { 'event' => 'watch_client.test' })
      result = Transport.new(configuration).post([entry])
      if result.ok?
        out.puts "OK: test log accepted by #{configuration.url} (HTTP #{result.code})"
        true
      else
        out.puts "FAILED: #{result.error || "HTTP #{result.code}"}"
        false
      end
    end

    # For tests: forget configuration and stop the client.
    def reset!
      DatabaseMonitor.uninstall!
      Metrics.uninstall!
      @client&.shutdown(timeout: 0)
      @error_client&.shutdown(timeout: 0)
      @client = nil
      @error_client = nil
      @logger = nil
      @configuration = nil
      Context.clear!
    end
  end
end

require 'watch_client/railtie' if defined?(Rails::Railtie)
