# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require 'uri'

module WatchClient
  # watch.js through the app's own website, so browser errors and page speed still arrive where
  # Watch's domain is blocked (company firewalls, ad blockers, some countries), and a slow Watch
  # never slows the page. Rack middleware, first in a Rails app's stack:
  #
  #   <browser_path>/watch.js         the bundled watch.js (cached by the browser for a year per version)
  #   <browser_path>/browser_errors   a report from watch.js: checked, queued, answered at once
  #   <browser_path>/browser_vitals   the same for page speed
  #
  # Queued reports go to Watch's /api/v1/browser_reports from a background thread, with the server
  # key, at most once a minute in batches of 200 reports or about 1 MB. Like Watch itself, the relay
  # always answers 204, also when it refuses a report (the reason is in the X-Watch-Refused header),
  # so a refused report never shows as an error in the visitor's console.
  class BrowserRelay
    SCRIPT = File.expand_path('watch.js', __dir__)
    MAX_BYTES = { 'error' => 64 * 1024, 'vitals' => 4 * 1024 }.freeze
    # Per visitor IP and per process (or per app with a shared Rails.cache), per minute: the same
    # limits as Watch's own browser endpoints.
    LIMITS = { 'error' => { ip: 60, total: 600 }, 'vitals' => { ip: 120, total: 6_000 } }.freeze
    BATCH_SIZE = 200
    BATCH_BYTES = 1024 * 1024
    FLUSH_INTERVAL = 60

    class << self
      # The bundled watch.js, or nil when the gem was installed without it.
      def script_source
        @script_source ||= File.read(SCRIPT, encoding: 'UTF-8')
      rescue SystemCallError
        nil
      end

      # The version in the bundled watch.js ("2.1.0"), so its URL changes with every update.
      def script_version
        @script_version ||= script_source.to_s[/watch\.js (\d+\.\d+\.\d+)/, 1] || '0'
      end

      # Its own queue and thread: reports wait up to a minute and go in big batches.
      def client
        @client ||= Client.new(WatchClient.configuration,
                               transport: Transport.new(WatchClient.configuration, **Transport::BROWSER_REPORTS),
                               batch_size: BATCH_SIZE, flush_interval: FLUSH_INTERVAL, batch_bytes: BATCH_BYTES)
      end

      # For tests and WatchClient.reset!.
      def reset!(timeout: 0)
        @client&.shutdown(timeout: timeout)
        @client = nil
        @counts = nil
      end

      # Counts a report against the visitor's and the total budget for the minute. Uses Rails.cache
      # when it can count (shared by all processes), else a counter in this process.
      def within_limits?(kind, visitor_ip, now: Time.now, cache: rails_cache)
        minute = now.to_i / 60
        limits = LIMITS.fetch(kind)
        total = increment("watch-relay:#{kind}:#{minute}", cache)
        visitor = increment("watch-relay:#{kind}:#{minute}:#{Digest::SHA256.hexdigest(visitor_ip.to_s)[0, 16]}", cache)
        total <= limits[:total] && visitor <= limits[:ip]
      end

      private

      def rails_cache
        cache = defined?(::Rails) && ::Rails.respond_to?(:cache) ? ::Rails.cache : nil
        cache unless defined?(::ActiveSupport::Cache::NullStore) && cache.is_a?(::ActiveSupport::Cache::NullStore)
      end

      def increment(key, cache)
        if cache
          value = cache.increment(key, 1, expires_in: 120)
          return value.to_i if value
        end
        (@counts_mutex ||= Mutex.new).synchronize do
          minute = key[/:(\d+)/, 1]
          @counts = {} if @counts.nil? || @counts_minute != minute
          @counts_minute = minute
          @counts[key] = @counts.fetch(key, 0) + 1
        end
      end
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      route = route(env)
      route ? answer(route, env) : @app.call(env)
    end

    private

    def route(env)
      config = WatchClient.configuration
      return unless config.browser_relay?

      case env['PATH_INFO']
      when "#{config.browser_path}/watch.js" then 'script'
      when "#{config.browser_path}/browser_errors" then 'error'
      when "#{config.browser_path}/browser_vitals" then 'vitals'
      end
    end

    def answer(route, env)
      route == 'script' ? script(env) : report(route, env)
    rescue StandardError => e
      WatchClient.diagnose("browser relay failed: #{e.class}: #{e.message}")
      refused('failed')
    end

    def script(env)
      source = self.class.script_source
      return [404, { 'content-type' => 'text/plain' }, ["watch.js not found\n"]] unless source

      etag = %("watch-js-#{Digest::SHA256.hexdigest(source)[0, 16]}")
      versioned = Rack::Utils.parse_query(env['QUERY_STRING'].to_s)['v'] == self.class.script_version
      headers = {
        'content-type' => 'application/javascript; charset=utf-8',
        'cache-control' => versioned ? 'public, max-age=31536000, immutable' : 'public, max-age=3600',
        'etag' => etag,
        'x-content-type-options' => 'nosniff'
      }
      return [304, headers, []] if env['HTTP_IF_NONE_MATCH'] == etag

      [200, headers, env['REQUEST_METHOD'] == 'HEAD' ? [] : [source]]
    end

    def report(kind, env)
      method = env['REQUEST_METHOD']
      return refused(nil) if method == 'OPTIONS'
      return refused('method-not-allowed', 405) unless method == 'POST'

      request = Rack::Request.new(env)
      # Only the website's own pages (scheme left out: behind a TLS proxy the app may see http).
      origin = env['HTTP_ORIGIN'].to_s.downcase.delete_suffix('/')
      return refused('origin-not-allowed') if origin.empty? || host_of(origin) != host_of(request.base_url.downcase)

      key = Rack::Utils.parse_query(env['QUERY_STRING'].to_s)['key'].to_s
      browser_key = WatchClient.configuration.browser_key.to_s
      return refused('unknown-key') unless key.bytesize == browser_key.bytesize && Rack::Utils.secure_compare(key, browser_key)

      body = env['rack.input']&.read(MAX_BYTES.fetch(kind) + 1).to_s
      return refused('too-large') if body.bytesize > MAX_BYTES.fetch(kind)

      data = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
      return refused('unreadable') unless data.is_a?(Hash)

      ip = visitor_ip(env, request)
      return refused('rate-limited') unless self.class.within_limits?(kind, ip)

      self.class.client.push('kind' => kind, 'received_at' => Time.now.utc.iso8601, 'origin' => origin, 'ip' => ip,
                             'user_agent' => env['HTTP_USER_AGENT']&.slice(0, 1000), 'body' => data)
      refused(nil)
    end

    # In Rails, remote_ip: it follows the app's trusted proxies (config.action_dispatch.trusted_proxies).
    def visitor_ip(env, request)
      defined?(::ActionDispatch::Request) ? ::ActionDispatch::Request.new(env).remote_ip : request.ip
    end

    def host_of(origin)
      uri = URI.parse(origin)
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ''
      "#{uri.host}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    def refused(reason, status = 204)
      headers = { 'cache-control' => 'no-store' }
      headers['x-watch-refused'] = reason if reason
      [status, headers, []]
    end
  end
end
