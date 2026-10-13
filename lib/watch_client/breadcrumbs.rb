# frozen_string_literal: true

require 'time'
require 'watch_client/sql_normalizer'

module WatchClient
  # The last few things that happened in the current request or job (SQL queries,
  # renders, jobs enqueued, mails, HTTP calls, warnings), sent along with an error.
  module Breadcrumbs
    KEY = :watch_client_breadcrumbs
    IVAR = :@__watch_breadcrumbs
    MAX_MESSAGE = 300

    module_function

    # Starts a fresh trail for the block (one per request / job) and restores the previous one.
    def with
      previous = Thread.current[KEY]
      Thread.current[KEY] = []
      yield
    ensure
      Thread.current[KEY] = previous
    end

    def recording?
      !Thread.current[KEY].nil? && WatchClient.configuration.breadcrumbs
    end

    def add(category, message, metadata = nil)
      trail = Thread.current[KEY]
      return unless trail && WatchClient.configuration.breadcrumbs

      crumb = { 'at' => Time.now.utc.iso8601(3), 'category' => category.to_s,
                'message' => Entry.clean(message.to_s)[0, MAX_MESSAGE] }
      if metadata && !metadata.empty?
        crumb['metadata'] = Filter.hash(Entry.json_safe(metadata.compact), WatchClient.configuration.filter_keys)
      end
      trail << crumb
      trail.shift while trail.size > WatchClient.configuration.breadcrumbs_max.to_i
      true
    rescue StandardError
      nil
    end

    def current
      (Thread.current[KEY] || []).dup
    end

    # Keeps a copy of the trail on the exception (it is reported after the request ends).
    def attach(exception)
      return if exception.frozen? || exception.instance_variable_defined?(IVAR)

      trail = Thread.current[KEY]
      exception.instance_variable_set(IVAR, trail.dup) if trail && !trail.empty?
    rescue StandardError
      nil
    end

    def for_exception(exception)
      saved = exception.instance_variable_get(IVAR) if exception.instance_variable_defined?(IVAR)
      saved || current
    end

    # Replaces literal values in SQL with ? so no personal data ends up in a breadcrumb. Same
    # SQL-aware sanitizer as slow / top queries (strings with any escaping, dollar quotes,
    # comments, numbers, bind parameters).
    def sanitize_sql(sql, connection = nil)
      SqlNormalizer.normalize(sql, dialect: connection ? SqlNormalizer.dialect_for(connection) : nil)
    rescue StandardError
      '[SQL]'
    end

    # Rails instrumentation → breadcrumbs. Called once by the Railtie.
    def subscribe!
      return if @subscribed

      @subscribed = true
      on('start_processing.action_controller') do |payload, _event|
        path = payload[:path].to_s.split('?').first
        add('request', "#{payload[:controller]}##{payload[:action]}",
            'method' => payload[:method], 'path' => path, 'format' => payload[:format]&.to_s)
      end
      on('sql.active_record') do |payload, duration|
        next if payload[:name].to_s == 'SCHEMA' || payload[:name].to_s.start_with?('EXPLAIN')

        add('query', sanitize_sql(payload[:sql], payload[:connection]),
            'name' => payload[:name], 'duration_ms' => duration, 'cached' => (payload[:cached] ? true : nil))
      end
      %w[render_template.action_view render_partial.action_view render_collection.action_view].each do |name|
        on(name) do |payload, duration|
          add('render', relative(payload[:identifier]), 'duration_ms' => duration)
        end
      end
      on('enqueue.active_job') do |payload, _event|
        job = payload[:job]
        add('job', "Enqueued #{job.class.name}", 'queue' => job.respond_to?(:queue_name) ? job.queue_name : nil,
                                                 'job_id' => job.respond_to?(:job_id) ? job.job_id : nil)
      end
      on('deliver.action_mailer') do |payload, _event|
        add('mail', "Sent mail from #{payload[:mailer]}", 'subject' => payload[:subject])
      end
      on('cache_read.active_support') do |payload, _event|
        add('cache', "Cache #{payload[:hit] ? 'hit' : 'miss'}", 'key' => payload[:key].to_s[0, 120])
      end
    end

    # Five-argument subscribers are cheap (no Event object, no CPU/allocation tracking),
    # and do nothing unless a request or job is recording a trail.
    def on(name)
      ActiveSupport::Notifications.subscribe(name) do |_name, started, finished, _id, payload|
        next unless Thread.current[KEY]

        yield(payload, ((finished - started) * 1000).round(1))
      rescue StandardError
        nil
      end
    end

    def relative(path)
      root = WatchClient.configuration.app_root.to_s
      return path.to_s if root.empty?

      path.to_s.delete_prefix("#{root.chomp('/')}/")
    end
  end
end
