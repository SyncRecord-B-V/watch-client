# frozen_string_literal: true

require 'net/http'
require 'uri'

module WatchClient
  # Heartbeat check-ins for cron jobs and workers: calls Watch's ping URL
  # (/ping/<token>, or /ping/<token>/fail for a failed run). Synchronous, short
  # timeout, never raises; returns true when Watch accepted the ping.
  module CheckIn
    MESSAGE_LIMIT = 250

    module_function

    def ping(config, token_or_url, failed: false, message: nil)
      return false unless config.check_ins_enabled?

      uri = ping_uri(config, token_or_url, failed)
      return false unless uri

      unless config.secure_url?(uri.to_s)
        WatchClient.diagnose('check-in not sent: the ping URL must use https:// (http:// only for localhost / *.test)')
        return false
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = config.timeout
      http.read_timeout = config.timeout
      http.write_timeout = config.timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'text/plain; charset=utf-8'
      request['User-Agent'] = "watch_client/#{VERSION} ruby/#{RUBY_VERSION}"
      request.body = message.to_s[0, MESSAGE_LIMIT]

      Thread.current[:watch_client_internal] = true
      response = http.start { |connection| connection.request(request) }
      return true if response.code.to_i.between?(200, 299)

      WatchClient.diagnose("check-in not accepted: HTTP #{response.code}")
      false
    rescue StandardError => e
      WatchClient.diagnose("check-in failed: #{e.class}: #{e.message}")
      false
    ensure
      Thread.current[:watch_client_internal] = nil
    end

    # A full ping URL is used as is; a token is joined to the configured Watch URL.
    def ping_uri(config, token_or_url, failed)
      value = token_or_url.to_s.strip
      return nil if value.empty?

      base = if value.start_with?('http://', 'https://')
               value.sub(%r{/(fail|success)\z}, '')
             else
               return nil if config.url.to_s.empty?

               "#{config.url.to_s.chomp('/')}/ping/#{URI.encode_www_form_component(value)}"
             end
      URI(failed ? "#{base}/fail" : base)
    end
  end
end
