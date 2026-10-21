# frozen_string_literal: true

module WatchClient
  # One at_exit hook for the whole process: reports the exception that ends it (a crash while the
  # app boots, a Sidekiq process that can't reach Redis at start, `rails runner`, a script), then
  # sends whatever is still queued. Registered early, so it also covers errors raised before the
  # rest of the gem is set up. A normal exit, `exit 1` and signals (deploys, Ctrl-C) are not errors.
  module CrashReporter
    module_function

    def install!
      return if @installed

      @installed = true
      at_exit { WatchClient::CrashReporter.on_exit($!) } # rubocop:disable Style/SpecialGlobalVars
    end

    def installed?
      @installed ? true : false
    end

    def on_exit(error)
      report(error)
    ensure
      WatchClient.shutdown
    end

    def report(error)
      return false unless error.is_a?(Exception)

      # `rescue => e; warn e; exit 1` (Sidekiq's bin/sidekiq when Redis is down at start, `rails runner`):
      # the exit carries the real error as its cause.
      error = error.cause if error.is_a?(SystemExit) && !error.success? && error.cause.is_a?(StandardError)
      return false if error.is_a?(SystemExit) || error.is_a?(SignalException)

      config = WatchClient.configuration
      # Set up later during boot; a crash before that still gets filtered, relative paths.
      config.filter_keys ||= Configuration::DEFAULT_FILTER_KEYS.dup
      config.app_root ||= ::Rails.root.to_s if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
      WatchClient.notify(error, handled: false, context: { 'process_crash' => true, 'program' => $PROGRAM_NAME.to_s[0, 200] })
    rescue StandardError
      false
    end
  end
end
