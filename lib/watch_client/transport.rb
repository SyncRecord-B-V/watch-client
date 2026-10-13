# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'zlib'

module WatchClient
  # Sends one batch to Watch over HTTPS (gzip JSON; plain HTTP only to local hosts). Keeps one persistent
  # connection per transport. Returns a Result telling the caller what to do.
  class Transport
    Result = Struct.new(:status, :code, :error, keyword_init: true) do
      def ok? = status == :ok
      def retry? = status == :retry
      def drop? = status == :drop
    end

    RETRYABLE_CODES = [408, 425, 429, 500, 502, 503, 504].freeze
    NETWORK_ERRORS = [
      IOError, EOFError, SocketError, SystemCallError, Timeout::Error,
      Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, Zlib::Error
    ].freeze

    LOGS = { path: '/api/v1/logs', key: 'entries' }.freeze
    ERRORS = { path: '/api/v1/errors', key: 'errors' }.freeze
    DEPLOYS = { path: '/api/v1/deploys', key: nil }.freeze
    DATABASE = { path: '/api/v1/database', key: nil }.freeze
    METRICS = { path: '/api/v1/metrics', key: nil }.freeze
    DEPENDENCIES = { path: '/api/v1/dependencies', key: nil }.freeze

    # path: API path on the hub; key: the JSON key that wraps a batch (nil = send the object as is).
    def initialize(config, path: LOGS[:path], key: LOGS[:key])
      @config = config
      @path = path
      @key = key
      @mutex = Mutex.new
      @http = nil
    end

    class InsecureURL < StandardError; end

    # items: an Array (batch, wrapped in { key => items }) or a Hash sent as is.
    def post(items)
      body = encode(@key ? { @key => items } : items)
      return Result.new(status: :drop, error: 'could not encode batch') unless body

      response = @mutex.synchronize { send_request(body) }
      classify(response)
    rescue *NETWORK_ERRORS => e
      reset_connection
      Result.new(status: :retry, error: "#{e.class}: #{e.message}")
    rescue InsecureURL => e
      Result.new(status: :drop, error: e.message)
    end

    def close
      reset_connection
    end

    # A new transport with the same settings (after a fork the old connection belongs to the parent).
    def fresh
      self.class.new(@config, path: @path, key: @key)
    end

    private

    def encode(object)
      json = JSON.generate(object)
      Zlib.gzip(json)
    rescue JSON::GeneratorError, Encoding::UndefinedConversionError, ArgumentError
      nil
    end

    def send_request(body)
      uri = endpoint
      # Never send the API key unencrypted to a remote host (see Configuration#secure_url?).
      unless @config.secure_url?(uri.to_s)
        raise InsecureURL,
              "refusing to send to #{uri.scheme}://#{uri.host}: use https://"
      end

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['Content-Encoding'] = 'gzip'
      request['Authorization'] = "Bearer #{@config.api_key}"
      request['User-Agent'] = "watch_client/#{VERSION} ruby/#{RUBY_VERSION}"
      request.body = body

      # Never propagate a request ID onto our own delivery requests.
      Thread.current[:watch_client_internal] = true
      connection(uri).request(request)
    ensure
      Thread.current[:watch_client_internal] = nil
    end

    def classify(response)
      code = response.code.to_i
      if code.between?(200, 299)
        Result.new(status: :ok, code: code)
      elsif RETRYABLE_CODES.include?(code)
        Result.new(status: :retry, code: code, error: "HTTP #{code}")
      else
        # 400, 401, 413, 422...: retrying the same batch won't help.
        Result.new(status: :drop, code: code, error: "HTTP #{code}: #{response.body.to_s[0, 200]}")
      end
    end

    def endpoint
      @endpoint ||= URI("#{@config.url.to_s.chomp('/')}#{@path}")
    end

    def connection(uri)
      return @http if @http&.started?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @config.timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30
      http.start
      @http = http
    end

    def reset_connection
      @http&.finish if @http&.started?
    rescue StandardError
      nil
    ensure
      @http = nil
    end
  end
end
