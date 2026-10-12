require "logger"

module SyncRecordWatch
  # A ::Logger that sends every line to Sync Record Watch instead of writing to an IO.
  # The Railtie adds it to Rails.logger with `broadcast_to`, so the app's own
  # log output (stdout, files) keeps working exactly as before.
  class Logger < ::Logger
    SILENCE_KEY = :syncrecord_watch_silence

    def initialize(level: :info)
      super(nil)
      self.level = level
      @progname = nil
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= UNKNOWN
      return true if severity < level
      return true if (silenced = Thread.current[SILENCE_KEY]) && severity < silenced
      return true unless SyncRecordWatch.enabled?

      if message.nil?
        if block
          message = yield
        else
          message = progname
          progname = nil
        end
      end

      if severity >= WARN && Breadcrumbs.recording?
        Breadcrumbs.add("log", message.is_a?(Exception) ? "#{message.class}: #{message.message}" : message.to_s,
                        "level" => Entry.level_name(severity))
      end
      return true unless SyncRecordWatch.configuration.send_logs

      SyncRecordWatch.enqueue(severity, message, payload: progname ? { "progname" => progname.to_s } : nil)
      true
    rescue StandardError
      true
    end
    alias log add

    # Same contract as ActiveSupport::LoggerSilence#silence, so Rails.logger.silence
    # (used e.g. for asset requests) also quiets what goes to Sync Record Watch.
    def silence(severity = ::Logger::ERROR)
      previous = Thread.current[SILENCE_KEY]
      Thread.current[SILENCE_KEY] = severity
      yield self
    ensure
      Thread.current[SILENCE_KEY] = previous
    end
  end
end
