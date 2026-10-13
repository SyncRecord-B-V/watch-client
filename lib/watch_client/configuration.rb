# frozen_string_literal: true

require 'socket'
require 'uri'

module WatchClient
  # All settings, with defaults read from ENV so most apps only need:
  #   WATCH_URL, WATCH_API_KEY
  class Configuration
    LEVELS = %i[debug info warn error fatal unknown].freeze

    # Connection
    attr_accessor :url, :api_key, :app_name, :timeout
    # Plain http:// is only accepted for local development hosts (localhost, 127.0.0.1, ::1,
    # *.localhost, *.test). allow_http (WATCH_ALLOW_HTTP=true) accepts it for any host: only for
    # a private network you trust, the API key travels unencrypted.
    attr_accessor :allow_http
    # Browser error tracking (watch.js): the app's public browser key from Watch.
    attr_accessor :browser_key, :browser_enabled
    # Heartbeat check-ins (WatchClient.check_in): on outside the test environment.
    attr_writer :check_ins_enabled

    # What is sent
    attr_accessor :environment, :host, :app_version, :min_level, :send_logs,
                  :log_requests, :current_user_id, :filter_keys, :before_send

    # Request ID propagation to outgoing HTTP calls (Net::HTTP, so Faraday too).
    # propagate_to: nil = all hosts, or an array of host strings / regexps.
    attr_accessor :propagate_request_id, :propagate_to

    # Batching and delivery
    # max_queue: entries kept in memory per buffer; max_queue_bytes: their total JSON size.
    attr_accessor :batch_size, :flush_interval, :max_queue, :max_queue_bytes, :max_retries, :shutdown_timeout

    # Error tracking
    attr_accessor :send_errors, :report_handled_errors, :ignore_errors, :before_notify,
                  :app_root, :backtrace_lines,
                  :breadcrumbs, :breadcrumbs_max, :send_session, :send_cookie_values,
                  :source_frames, :source_lines

    # Exceptions never reported (class names; subclasses too). Mostly 4xx noise.
    DEFAULT_IGNORED_ERRORS = %w[
      ActionController::RoutingError
      AbstractController::ActionNotFound
      ActionController::MethodNotAllowed
      ActionController::UnknownHttpMethod
      ActionController::NotImplemented
      ActionController::UnknownFormat
      ActionController::InvalidAuthenticityToken
      ActionController::InvalidCrossOriginRequest
      ActionController::BadRequest
      ActionController::ParameterMissing
      ActionDispatch::Http::Parameters::ParseError
      ActionDispatch::Http::MimeNegotiation::InvalidType
      ActiveRecord::RecordNotFound
      Sidekiq::JobRetry::Skip
      SignalException
      Interrupt
    ].freeze

    # Database monitoring (PostgreSQL): slow queries, health, top queries, tables.
    # slow_query_ms: queries at least this slow are reported (grouped, values removed).
    # before_send_query: ->(query_hash) { ... } change a slow query, or return nil to drop it.
    # database_interval: seconds between samples (minimum 15).
    attr_accessor :database_monitoring, :slow_query_ms, :before_send_query, :database_interval

    # Performance monitoring: response times per controller action and calls to outside
    # services (Net::HTTP / Faraday), sent once a minute. Dependencies: gem versions for
    # vulnerability alerts, sent once per boot. Browser vitals: page speed from watch.js
    # (vitals_sample_rate: share of page views measured, 0.0-1.0).
    attr_accessor :performance_monitoring, :report_dependencies, :browser_vitals, :vitals_sample_rate
    # Background jobs: queue sizes from Solid Queue / Sidekiq. Process health: memory, GC, Puma.
    attr_accessor :job_queue_monitoring, :process_monitoring

    # Diagnostics: where the gem reports its own problems (never into the app's logger).
    attr_accessor :diagnostics

    attr_writer :enabled

    # Always masked in params, sessions and log fields, on top of the app's own filter_parameters
    # (the list a new Rails app starts with, plus IBAN).
    DEFAULT_FILTER_KEYS = %i[passw email secret token _key crypt salt certificate otp ssn cvv cvc iban].freeze

    DEFAULT_MAX_QUEUE_BYTES = 16 * 1024 * 1024

    ENV_PREFIX = 'WATCH_'
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
    LOCAL_SUFFIXES = %w[.localhost .test].freeze

    # WATCH_<name> (nil when unset or empty).
    def self.env(name)
      value = ENV["#{ENV_PREFIX}#{name}"]
      value.nil? || value.empty? ? nil : value
    end

    def initialize
      @url = self.class.env('URL')
      @api_key = self.class.env('API_KEY')
      @app_name = self.class.env('APP_NAME')
      @timeout = 5
      @allow_http = self.class.env('ALLOW_HTTP') == 'true'
      @browser_key = self.class.env('BROWSER_KEY')
      @browser_enabled = nil # nil = on when url and browser_key are set (and not in test)

      @environment = self.class.env('ENVIRONMENT') || ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
      @host = ENV['DYNO'] || ENV['HOSTNAME'] || safe_hostname
      @app_version = detect_app_version
      @min_level = (self.class.env('MIN_LEVEL') || :info).to_sym
      @send_logs = true
      @log_requests = true
      @current_user_id = nil
      @filter_keys = nil
      @before_send = nil

      @propagate_request_id = true
      @propagate_to = nil

      @batch_size = 500
      @flush_interval = 3
      @max_queue = 10_000
      @max_queue_bytes = DEFAULT_MAX_QUEUE_BYTES
      @max_retries = 4
      @shutdown_timeout = 5

      @send_errors = true
      @report_handled_errors = true
      @ignore_errors = DEFAULT_IGNORED_ERRORS.dup
      @before_notify = nil
      @app_root = nil
      @backtrace_lines = 100
      @breadcrumbs = true
      @breadcrumbs_max = 40
      @send_session = true
      @send_cookie_values = false
      @source_frames = 10
      @source_lines = 3

      @database_monitoring = self.class.env('DATABASE_MONITORING') != 'false'
      @slow_query_ms = (self.class.env('SLOW_QUERY_MS') || 500).to_i
      @before_send_query = nil
      @database_interval = 60

      @performance_monitoring = self.class.env('PERFORMANCE_MONITORING') != 'false'
      @report_dependencies = self.class.env('REPORT_DEPENDENCIES') != 'false'
      @browser_vitals = true
      @vitals_sample_rate = 1.0
      @job_queue_monitoring = self.class.env('JOB_QUEUE_MONITORING') != 'false'
      @process_monitoring = self.class.env('PROCESS_MONITORING') != 'false'

      @diagnostics = $stderr
      @enabled = nil
    end

    # Enabled when URL and key are set, unless switched off explicitly or running tests.
    def browser_enabled?
      return @browser_enabled unless @browser_enabled.nil?
      return false if environment.to_s == 'test'

      present?(url) && present?(browser_key) && secure_url_or_warn?
    end

    def check_ins_enabled?
      return @check_ins_enabled unless @check_ins_enabled.nil?

      environment.to_s != 'test'
    end

    def enabled?
      return @enabled unless @enabled.nil?
      return false if environment.to_s == 'test'

      present?(url) && present?(api_key) && secure_url_or_warn?
    end

    # Whether data (and the API key) may be sent to this URL: https, or http to a local
    # development host, or any http when allow_http is on.
    def secure_url?(value = url)
      uri = URI.parse(value.to_s.strip)
      return false if uri.host.nil? || uri.host.empty?
      return true if uri.scheme == 'https'

      uri.scheme == 'http' && (allow_http == true || local_host?(uri.host))
    rescue URI::Error
      false
    end

    def min_level_index
      LEVELS.index(min_level.to_s.downcase.to_sym) || 1
    end

    def validate!
      problems = []
      problems << 'url is missing (WATCH_URL)' unless present?(url)
      problems << 'api_key is missing (WATCH_API_KEY)' unless present?(api_key)
      if present?(url) && !secure_url?
        problems << 'url must use https:// (http:// only for localhost / *.test, or set WATCH_ALLOW_HTTP=true)'
      end
      problems << 'batch_size must be 1..1000' unless (1..1000).cover?(batch_size.to_i)
      problems << "min_level must be one of #{LEVELS.join(', ')}" unless LEVELS.include?(min_level.to_s.downcase.to_sym)
      problems
    end

    private

    def local_host?(host)
      name = host.to_s.downcase.delete_prefix('[').delete_suffix(']')
      LOCAL_HOSTS.include?(name) || name.match?(/\A127\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/) || LOCAL_SUFFIXES.any? do |suffix|
        name.end_with?(suffix)
      end
    end

    # Off for an insecure URL, with one warning (the URL is configured, so it is a mistake).
    def secure_url_or_warn?
      return true if secure_url?

      unless @insecure_url_warned
        @insecure_url_warned = true
        WatchClient.diagnose('not sending anything: WATCH_URL must use https:// ' \
                             '(http:// only for localhost / *.test, or set WATCH_ALLOW_HTTP=true)')
      end
      false
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    def safe_hostname
      Socket.gethostname
    rescue StandardError
      'unknown'
    end

    def detect_app_version
      value = self.class.env('APP_VERSION') || ENV['HEROKU_SLUG_COMMIT'] || ENV['GIT_SHA'] || ENV['SOURCE_VERSION']
      value && value[0, 12]
    end
  end
end
