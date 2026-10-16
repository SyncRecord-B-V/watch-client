# frozen_string_literal: true

module WatchClient
  # Where a background job's time goes: time in SQL queries (and how many), time in outgoing HTTP
  # calls, the rest is Ruby. Measured per run on the job's thread (ActiveJob and native Sidekiq) and
  # sent with the job numbers, like requests get from Rails' db_runtime.
  #
  # A job run inline inside another job or a request (perform_now) is measured on its own, and its
  # numbers are added to the outer one afterwards (its time is part of the outer run too).
  #
  #   run = JobTimer.start
  #   begin ... ensure numbers = JobTimer.stop(run) end   # => { db_ms:, queries:, http_ms: }
  module JobTimer
    KEY = :watch_client_job_timer
    Run = Struct.new(:timer, :outer, :outer_http)

    module_function

    def start
      run = Run.new({ db_ms: 0.0, queries: 0, http_ms: 0.0 }, Thread.current[KEY], Thread.current[http_key])
      Thread.current[KEY] = run.timer
      Thread.current[http_key] = 0.0
      run
    end

    def stop(run)
      timer = run.timer
      timer[:http_ms] = Thread.current[http_key].to_f
      Thread.current[KEY] = run.outer
      Thread.current[http_key] = run.outer_http.nil? ? nil : run.outer_http + timer[:http_ms]
      if run.outer
        run.outer[:db_ms] += timer[:db_ms]
        run.outer[:queries] += timer[:queries]
      end
      timer
    rescue StandardError
      {}
    end

    # One SQL query (sql.active_record). Schema queries and query-cache hits don't count.
    def sql(duration_ms, payload)
      timer = Thread.current[KEY]
      return unless timer
      return if payload[:cached] || payload[:name].to_s == 'SCHEMA'

      timer[:db_ms] += duration_ms.to_f
      timer[:queries] += 1
    rescue StandardError
      nil
    end

    def subscribe!
      return if @subscribed || !defined?(::ActiveSupport::Notifications)

      @subscribed = true
      ::ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
        sql(event.duration, event.payload) if Thread.current[KEY]
      end
    end

    def http_key
      NetHTTPPropagation::HTTP_MS_KEY
    end
  end
end
