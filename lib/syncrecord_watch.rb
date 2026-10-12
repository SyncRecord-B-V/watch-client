require "syncrecord_watch/version"
require "syncrecord_watch/configuration"
require "syncrecord_watch/context"
require "syncrecord_watch/entry"
require "syncrecord_watch/transport"
require "syncrecord_watch/client"
require "syncrecord_watch/logger"
require "syncrecord_watch/breadcrumbs"
require "syncrecord_watch/app_env"
require "syncrecord_watch/notice"
require "syncrecord_watch/net_http_propagation"
require "syncrecord_watch/browser_tag"
require "syncrecord_watch/check_in"
require "syncrecord_watch/database_monitor"
require "syncrecord_watch/metrics"
require "syncrecord_watch/dependencies"

# Sends a Rails app's logs to Sync Record Watch.
#
#   SyncRecordWatch.configure do |c|
#     c.url      = ENV["SYNCRECORD_WATCH_URL"]
#     c.api_key  = ENV["SYNCRECORD_WATCH_API_KEY"]
#     c.app_name = "billing-api"
#   end
#
# In a Rails app the Railtie does the rest (see README).
module SyncRecordWatch
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

    # Structured log line, e.g. SyncRecordWatch.log(:info, "invoice.sent", invoice_id: 7)
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

    # Reports an exception to Sync Record Watch's error tracking. Returns true when queued.
    #
    #   rescue Stripe::APIError => e
    #     SyncRecordWatch.notify(e, context: { order_id: order.id })
    #
    # fingerprint: errors with the same fingerprint are grouped together in Sync Record Watch.
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

    # Records a deploy so Sync Record Watch can show which version an error started in.
    # Sent right away (not queued). Returns true on success.
    def notify_deploy(version: configuration.app_version, environment: configuration.environment,
                      revision: nil, deployed_by: nil)
      return false unless enabled? && version

      result = Transport.new(configuration, **Transport::DEPLOYS).post(
        "version" => version.to_s, "environment" => environment.to_s,
        "revision" => revision, "deployed_by" => deployed_by
      )
      diagnose("deploy not recorded: #{result.error || "HTTP #{result.code}"}") unless result.ok?
      result.ok?
    end

    # Heartbeat check-in for a cron job or worker (see Uptime → Heartbeats in Sync Record Watch).
    # Pass the heartbeat's token (joined to SYNCRECORD_WATCH_URL) or its full ping URL.
    #
    #   SyncRecordWatch.check_in("Xk2...")                       # the job ran
    #   SyncRecordWatch.check_in("Xk2...") { InvoiceExport.run } # pings when the block succeeds,
    #                                                         # /fail (with the error) when it raises
    #
    # Synchronous with a short timeout; never raises its own errors. Returns true when
    # Sync Record Watch accepted the ping (with a block: the block's result).
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
      configuration.diagnostics&.puts("[syncrecord_watch] #{message}")
    rescue StandardError
      nil
    end

    # Sends one test line right away and reports the result. Use from a console:
    #   SyncRecordWatch.test!
    def test!(out: $stdout)
      problems = configuration.validate!
      unless problems.empty?
        out.puts "Sync Record Watch is not configured: #{problems.join('; ')}"
        return false
      end

      entry = Entry.build(configuration, severity: :info,
                                         message: "syncrecord_watch test from #{configuration.app_name || 'app'}",
                                         payload: { "event" => "syncrecord_watch.test" })
      result = Transport.new(configuration).post([ entry ])
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

# The gem used to be called loghub_client: existing code using LoghubClient keeps working.
LoghubClient = SyncRecordWatch unless defined?(LoghubClient)

require "syncrecord_watch/railtie" if defined?(Rails::Railtie)
