# frozen_string_literal: true

module WatchClient
  # One structured summary line per controller action:
  #   "GET /invoices/42 200 in 45ms (InvoicesController#show)"
  # with method, path, status, duration, controller, action, format,
  # view and DB time in the payload. 5xx responses are logged as errors.
  module RequestSubscriber
    EVENT = 'process_action.action_controller'

    module_function

    def subscribe!
      return if @subscribed

      @subscribed = true
      ActiveSupport::Notifications.subscribe(EVENT) { |event| handle(event) }
    end

    def handle(event)
      return unless WatchClient.enabled?

      payload = event.payload
      status = payload[:status] || (payload[:exception] ? 500 : nil)
      duration = event.duration.round(1)
      action = "#{payload[:controller]}##{payload[:action]}"
      Metrics.record_request(endpoint: action, duration_ms: duration, status: status, db_ms: payload[:db_runtime],
                             view_ms: payload[:view_runtime], http_ms: Thread.current[NetHTTPPropagation::HTTP_MS_KEY])
      return unless WatchClient.configuration.log_requests

      # Rails' filters first, then Watch's own (filter_keys, procs, personal query values).
      path = Filter.url(filtered_path(payload), WatchClient.configuration.filter_keys)

      WatchClient.enqueue(
        status.to_i >= 500 ? :error : :info,
        "#{payload[:method]} #{path} #{status} in #{duration.round}ms (#{action})",
        payload: {
          'event' => 'request',
          'method' => payload[:method],
          'path' => path,
          'status' => status,
          'duration_ms' => duration,
          'controller' => payload[:controller],
          'action' => payload[:action],
          'format' => payload[:format]&.to_s,
          'view_ms' => payload[:view_runtime]&.round(1),
          'db_ms' => payload[:db_runtime]&.round(1),
          'exception' => payload[:exception]&.first
        }.reject { |_, value| value.nil? }
      )
    rescue StandardError
      nil
    end

    # Rails passes the request object (7.1+): use its filtered path so
    # secrets in query strings are masked like in the Rails log.
    def filtered_path(payload)
      request = payload[:request]
      return request.filtered_path if request.respond_to?(:filtered_path)

      payload[:path].to_s.split('?').first
    end
  end
end
