# frozen_string_literal: true

require 'net/http'
require 'openssl'

module WatchClient
  # Adds X-Request-ID to outgoing Net::HTTP requests (Faraday's default adapter
  # uses Net::HTTP too) while handling a request or job, so another Rails app
  # that receives the call logs under the same request ID.
  module NetHTTPPropagation
    HEADER = 'X-Request-ID'

    # Installed for request ID propagation and/or HTTP breadcrumbs.
    def self.install!
      return if Net::HTTP.ancestors.include?(self)

      Net::HTTP.prepend(self)
    end

    def self.propagate?(host)
      config = WatchClient.configuration
      return false unless config.propagate_request_id
      return true if config.propagate_to.nil?

      Array(config.propagate_to).any? do |rule|
        rule.is_a?(Regexp) ? rule.match?(host.to_s) : rule.to_s.casecmp?(host.to_s)
      end
    end

    HTTP_MS_KEY = :watch_client_http_ms
    TIMEOUTS = [Net::OpenTimeout, Net::ReadTimeout, Timeout::Error].freeze
    TIMEOUTS_WITH_WRITE = (defined?(Net::WriteTimeout) ? TIMEOUTS + [Net::WriteTimeout] : TIMEOUTS).freeze

    def request(req, body = nil, &block)
      internal = Thread.current[:watch_client_internal]
      request_id = WatchClient::Context.request_id
      req[HEADER] = request_id if request_id && !internal && req[HEADER].nil? && WatchClient::NetHTTPPropagation.propagate?(address)
      return super if internal || !started?

      breadcrumbs = WatchClient::Breadcrumbs.recording?
      metrics = WatchClient::Metrics.instance
      return super unless breadcrumbs || metrics

      # Net::HTTP calls #request again from #start; only the inner call (started) records.
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = nil
      failure = nil
      begin
        response = super
      rescue *TIMEOUTS_WITH_WRITE
        failure = 'timeout'
        raise
      rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError # EOFError is an IOError
        failure = 'connection'
        raise
      ensure
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
        default_port = use_ssl? ? 443 : 80
        host = port == default_port ? address : "#{address}:#{port}"
        Thread.current[HTTP_MS_KEY] += duration if Thread.current[HTTP_MS_KEY]
        metrics&.record_http(host: host, duration_ms: duration, status: response&.code, failure: failure)
        if breadcrumbs && response
          WatchClient::Breadcrumbs.add(
            'http', "#{req.method} #{use_ssl? ? 'https' : 'http'}://#{host}#{req.path.to_s.split('?').first} #{response.code}",
            'duration_ms' => duration.round(1)
          )
        end
      end
      response
    end
  end
end
