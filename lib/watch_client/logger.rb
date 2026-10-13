# frozen_string_literal: true

require 'logger'

module WatchClient
  # A ::Logger that sends every line to Watch instead of writing to an IO.
  # The Railtie adds it to Rails.logger with `broadcast_to`, so the app's own
  # log output (stdout, files) keeps working exactly as before.
  class Logger < ::Logger
    SILENCE_KEY = :watch_client_silence

    def initialize(level: :info)
      super(nil)
      self.level = level
      @progname = nil
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= UNKNOWN
      return true if severity < level
      return true if (silenced = Thread.current[SILENCE_KEY]) && severity < silenced
      return true unless WatchClient.enabled?

      if message.nil?
        if block
          message = yield
        else
          message = progname
          progname = nil
        end
      end

      if severity >= WARN && Breadcrumbs.recording?
        # Same text as the log line: a structured message is filtered before it becomes text.
        text, = Entry.split_message(message, WatchClient.configuration.filter_keys)
        Breadcrumbs.add('log', text, 'level' => Entry.level_name(severity))
      end
      return true unless WatchClient.configuration.send_logs

      WatchClient.enqueue(severity, message, payload: progname ? { 'progname' => progname.to_s } : nil)
      true
    rescue StandardError
      true
    end
    alias log add

    # Same contract as ActiveSupport::LoggerSilence#silence, so Rails.logger.silence
    # (used e.g. for asset requests) also quiets what goes to Watch.
    def silence(severity = ::Logger::ERROR)
      previous = Thread.current[SILENCE_KEY]
      Thread.current[SILENCE_KEY] = severity
      yield self
    ensure
      Thread.current[SILENCE_KEY] = previous
    end
  end
end
