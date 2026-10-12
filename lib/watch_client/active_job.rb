require "time"

module WatchClient
  # ActiveJob (Solid Queue, Sidekiq, any adapter):
  # - remembers the request ID at enqueue time and stores it with the job,
  # - while the job runs, every log line carries request_id, job_id and job_class.
  module ActiveJobExtension
    SERIALIZED_KEY = "watch_request_id".freeze

    def self.install(base)
      return if base.ancestors.include?(Serialization)

      base.prepend(Serialization)
      base.around_perform do |job, block|
        WatchClient::Context.with(
          request_id: job.watch_request_id || WatchClient::Context.request_id,
          job_id: job.job_id,
          job_class: job.class.name,
          queue: job.queue_name
        ) do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          wait_ms = WatchClient::ActiveJobExtension.wait_ms(job)
          failed = false
          WatchClient::Breadcrumbs.with do
            block.call
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Rails reports unhandled job errors after this context has ended; keep it on the error.
            failed = true
            WatchClient::Notice.attach_context(e)
            WatchClient::Breadcrumbs.attach(e)
            raise
          ensure
            WatchClient::Metrics.record_job(job_class: job.class.name, queue: job.queue_name, failed: failed, wait_ms: wait_ms,
                                             duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
          end
        end
      end
    end

    # Milliseconds between enqueue (or the scheduled time, when later) and now; nil when unknown.
    def self.wait_ms(job)
      enqueued = job.respond_to?(:enqueued_at) ? job.enqueued_at : nil
      scheduled = job.respond_to?(:scheduled_at) ? job.scheduled_at : nil
      from = [ time_of(enqueued), time_of(scheduled) ].compact.max
      from ? [ (Time.now - from) * 1000, 0 ].max : nil
    rescue StandardError
      nil
    end

    def self.time_of(value)
      case value
      when nil then nil
      when Time then value
      when Numeric then Time.at(value)
      else Time.parse(value.to_s)
      end
    rescue ArgumentError
      nil
    end

    module Serialization
      attr_writer :watch_request_id

      def watch_request_id
        @watch_request_id
      end

      def serialize
        @watch_request_id ||= WatchClient::Context.request_id
        data = super
        @watch_request_id ? data.merge(SERIALIZED_KEY => @watch_request_id) : data
      end

      def deserialize(job_data)
        super
        @watch_request_id = job_data[SERIALIZED_KEY]
      end
    end
  end
end
