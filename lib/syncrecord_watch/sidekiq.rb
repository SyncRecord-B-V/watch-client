module SyncRecordWatch
  # Native Sidekiq jobs (ActiveJob jobs on Sidekiq are covered by ActiveJobExtension too):
  # - client middleware stores the current request ID in the job,
  # - server middleware puts request_id, job_id and job_class in the log context.
  module SidekiqIntegration
    JOB_KEY = "loghub_request_id".freeze

    class ClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool = nil)
        request_id = SyncRecordWatch::Context.request_id
        job[JOB_KEY] ||= request_id if request_id
        yield
      end
    end

    class ServerMiddleware
      def call(_worker, job, queue)
        SyncRecordWatch::Context.with(
          request_id: job[JOB_KEY],
          job_id: job["jid"],
          job_class: job["wrapped"] || job["class"],
          queue: queue
        ) do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          failed = false
          SyncRecordWatch::Breadcrumbs.with do
            yield
          rescue Exception => e # rubocop:disable Lint/RescueException
            failed = true
            SyncRecordWatch::Notice.attach_context(e)
            SyncRecordWatch::Breadcrumbs.attach(e)
            raise
          ensure
            # ActiveJob jobs ("wrapped") are timed by the ActiveJob hook instead.
            unless job["wrapped"]
              SyncRecordWatch::Metrics.record_job(job_class: job["class"].to_s, queue: queue, failed: failed,
                                               wait_ms: SidekiqIntegration.wait_ms(job),
                                               duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
            end
          end
        end
      end
    end

    # Sidekiq calls error handlers for every failed attempt (retries included).
    module ErrorHandler
      module_function

      def call(exception, context, _config = nil)
        job = (context && context[:job]) || {}
        SyncRecordWatch.with_context(request_id: job[JOB_KEY], job_id: job["jid"]) do
          SyncRecordWatch.notify(
            exception,
            handled: false,
            component: job["wrapped"] || job["class"],
            context: {
              "sidekiq" => {
                "jid" => job["jid"], "queue" => job["queue"], "class" => job["class"],
                "wrapped" => job["wrapped"], "retry_count" => job["retry_count"]
              }.compact
            }
          )
        end
      rescue StandardError
        nil
      end
    end

    # enqueued_at is seconds (Sidekiq 7) or milliseconds (Sidekiq 8) since the epoch.
    def self.wait_ms(job)
      value = job["enqueued_at"]
      return nil unless value.is_a?(Numeric)

      seconds = value > 1e11 ? value / 1000.0 : value.to_f
      [ (Time.now.to_f - seconds) * 1000, 0 ].max
    end

    def self.install!
      return if @installed

      @installed = true
      ::Sidekiq.configure_client do |config|
        config.client_middleware { |chain| chain.add ClientMiddleware }
      end
      ::Sidekiq.configure_server do |config|
        config.client_middleware { |chain| chain.add ClientMiddleware }
        config.server_middleware { |chain| chain.add ServerMiddleware }
        config.error_handlers << ErrorHandler if SyncRecordWatch.configuration.send_errors
      end
    end
  end
end
