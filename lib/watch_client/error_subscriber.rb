# frozen_string_literal: true

module WatchClient
  # Receives everything reported through Rails' error reporter (Rails.error):
  # unhandled errors in jobs and in the Rails executor, plus anything the app reports
  # itself with Rails.error.report / Rails.error.handle.
  class ErrorSubscriber
    def report(error, handled:, severity: nil, context: {}, source: nil)
      return if handled && !WatchClient.configuration.report_handled_errors

      extra = {}
      extra['severity'] = severity.to_s if severity
      extra['source'] = source.to_s if source
      (context || {}).each { |key, value| extra[key.to_s] = simple(value) unless key.to_s == 'job' }

      # The job is taken from our own context first (set around each perform and restored after it,
      # also kept on the exception). Rails' context[:job] is not restored after a nested
      # perform_now (e.g. SolidCable::TrimJob running inside another job), so an error in the
      # outer job would be blamed on the inner one.
      component = nil
      if !Notice.context_for(error)[:job_class] && (job = context && context[:job]).respond_to?(:job_id)
        extra['job_id'] = job.job_id
        extra['queue'] = job.queue_name
        component = job.class.name
      end
      WatchClient.notify(error, handled: handled, context: extra, component: component)
    rescue StandardError
      nil
    end

    private

    # Rails context values can be whole objects (requests, records): keep plain data only.
    def simple(value)
      case value
      when nil, true, false, Numeric, String, Symbol then value
      when Hash then value.to_h { |k, v| [k.to_s, simple(v)] }
      when Array then value.first(20).map { |item| simple(item) }
      else value.to_s[0, 200]
      end
    end
  end
end
