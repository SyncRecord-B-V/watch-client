# frozen_string_literal: true

require 'json'

module WatchClient
  # The job an error happened in, sent with the error (never for successful runs): class, id, queue,
  # attempt and its arguments.
  #
  # Arguments are OFF by default: a positional value (a reset token, a password) can't be recognised
  # by name. Opt in per job with a class method that picks what to send:
  #
  #   class SyncAccountJob < ApplicationJob
  #     def self.watch_arguments(args) = [args.first] # the account record only
  #   end
  #
  # or for every job with config.send_job_arguments = true (WATCH_SEND_JOB_ARGUMENTS=true). What is
  # sent is made safe first: records become "Invoice#42" (their GlobalID), hashes go through the
  # filter list, email addresses are masked, strings are cut before copying, and the copy stops after
  # MAX_NODES values / about MAX_BYTES (cycles detected), so a huge payload costs almost nothing.
  module JobDetails
    KEY = :watch_client_job
    IVAR = :@__watch_job
    MAX_BYTES = 4 * 1024
    MAX_STRING = 300
    MAX_NODES = 200
    MAX_DEPTH = 6
    TRUNCATED = '[TRUNCATED]'
    MAX_KEY = 100
    LONG_KEY = '[LONG KEY]'
    EMAIL = /\A[^@\s]{1,64}@[^@\s]{1,255}\.[a-z]{2,24}\z/i
    GLOBAL_ID = %r{\Agid://[^/]+/(?<model>[\w:]+)/(?<id>[^/?]+)}
    ACTIVE_JOB_KEYS = %w[_aj_symbol_keys _aj_ruby2_keywords _aj_serialized].freeze

    module_function

    # Runs the block with `job` as the job running on this thread (an ActiveJob object or a Sidekiq
    # job hash); its details are built only when an error is reported.
    def with(job)
      previous = Thread.current[KEY]
      Thread.current[KEY] = job
      yield
    ensure
      Thread.current[KEY] = previous
    end

    # Keeps the job's details on the error while it propagates (Rails reports job errors after the
    # job's context has ended).
    def attach(exception, job = Thread.current[KEY], config = WatchClient.configuration)
      return if exception.frozen? || exception.instance_variable_defined?(IVAR)
      return unless config.enabled? && config.send_errors

      exception.instance_variable_set(IVAR, describe(job, config)) if job
    rescue StandardError
      nil
    end

    # The job details for a notice: saved on the error, else the job running now (an error reported
    # with Rails.error.report inside a job).
    def for_notice(exception, config)
      saved = exception.instance_variable_get(IVAR) if exception.instance_variable_defined?(IVAR)
      saved || (Thread.current[KEY] && describe(Thread.current[KEY], config))
    rescue StandardError
      nil
    end

    def describe(job, config)
      details =
        if job.is_a?(Hash) then sidekiq(job, config)
        elsif job.respond_to?(:job_id) && job.respond_to?(:arguments) then active_job(job, config)
        end
      details&.compact
    end

    def active_job(job, config)
      {
        'class' => job.class.name, 'id' => job.job_id.to_s, 'queue' => job.queue_name.to_s,
        'attempt' => (job.executions if job.respond_to?(:executions)),
        'arguments' => active_job_arguments(job, config)
      }
    end

    # Opt-in only: the job class chooses what to send (`def self.watch_arguments(args)`), or the app
    # sends every job's arguments (config.send_job_arguments). Positional values can't be filtered by
    # name, so nothing is sent by default.
    def active_job_arguments(job, config)
      if job.class.respond_to?(:watch_arguments)
        arguments(job.class.watch_arguments(job.arguments), config)
      elsif config.send_job_arguments
        arguments(job.arguments, config)
      end
    rescue StandardError
      '[UNREADABLE]'
    end

    # A Sidekiq job hash; for ActiveJob jobs on Sidekiq ("wrapped") the arguments are ActiveJob's serialized form.
    def sidekiq(job, config)
      wrapped = job['wrapped']
      args = job['args']
      args = args.first['arguments'] if wrapped && args.is_a?(Array) && args.first.is_a?(Hash) && args.first.key?('arguments')
      {
        'class' => (wrapped || job['class']).to_s, 'id' => job['jid'].to_s, 'queue' => job['queue'].to_s,
        'attempt' => (job['retry_count'].to_i + 1 if job.key?('retry_count')),
        'arguments' => (arguments(args, config) if config.send_job_arguments)
      }
    end

    # Copies at most MAX_NODES values and about MAX_BYTES of text, stopping as soon as either runs out
    # (big payloads cost almost nothing), with cycle detection; then filters the small copy.
    Budget = Struct.new(:nodes, :bytes, :seen, :exhausted)

    def arguments(args, config)
      budget = Budget.new(MAX_NODES, MAX_BYTES, {}.compare_by_identity, false)
      list = args.is_a?(Array) ? args : [args]
      safe = []
      list.each do |value|
        break if budget.exhausted

        safe << safe_value(value, 0, budget)
      end
      safe << TRUNCATED if budget.exhausted || list.size > safe.size
      filtered = Filter.hash({ 'arguments' => safe }, config.filter_keys)['arguments']
      size = JSON.generate(filtered).bytesize
      size > MAX_BYTES * 2 ? "[TOO LARGE: #{size} bytes]" : filtered
    rescue StandardError, SystemStackError
      '[UNREADABLE]'
    end

    def take(budget, bytes)
      budget.nodes -= 1
      budget.bytes -= bytes
      budget.exhausted = true if budget.nodes.negative? || budget.bytes.negative?
      !budget.exhausted
    end

    def safe_value(value, depth, budget)
      return TRUNCATED unless take(budget, 8)
      return '[TOO DEEP]' if depth > MAX_DEPTH

      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      when Symbol then safe_string(value.name, budget)
      when String then safe_string(value, budget)
      when Time then value.utc.iso8601
      when Hash, Array then safe_container(value, depth, budget)
      else record(value) || "#<#{value.class.name}>"
      end
    end

    # Cut before copying: never more than MAX_STRING characters of a string are touched.
    def safe_string(value, budget)
      head = value[0, MAX_STRING]
      cut = head.bytesize < value.bytesize
      text = head.dup.force_encoding(Encoding::UTF_8).scrub('?')
      take(budget, text.bytesize)
      return Filter::FILTERED if text.match?(EMAIL)
      return global_id(text) if text.start_with?('gid://')

      cut ? "#{text}…" : text
    end

    def safe_container(value, depth, budget)
      return '[CIRCULAR]' if budget.seen.key?(value)

      budget.seen[value] = true
      begin
        value.is_a?(Hash) ? safe_hash(value, depth, budget) : safe_array(value, depth, budget)
      ensure
        budget.seen.delete(value)
      end
    end

    def safe_array(value, depth, budget)
      out = []
      value.each do |item|
        break if budget.exhausted

        out << safe_value(item, depth + 1, budget)
      end
      out << TRUNCATED if budget.exhausted && out.last != TRUNCATED
      out
    end

    # ActiveJob's serialized hashes: {"_aj_globalid" => "gid://app/Invoice/42"} is a record.
    def safe_hash(value, depth, budget)
      return global_id(value['_aj_globalid'].to_s[0, 300]) if value.key?('_aj_globalid')

      out = {}
      value.each do |key, item|
        break if budget.exhausted
        next if ACTIVE_JOB_KEYS.include?(key.to_s)

        name = key.is_a?(String) || key.is_a?(Symbol) ? key.to_s : key.class.name.to_s
        # A key is never cut (a cut "..._password" would lose the part the filter looks for): an
        # oversized key is left out together with its value.
        if name.bytesize > MAX_KEY
          take(budget, 8)
          out[LONG_KEY] = Filter::FILTERED
          next
        end

        take(budget, name.bytesize)
        out[name] = safe_value(item, depth + 1, budget)
      end
      out['…'] = TRUNCATED if budget.exhausted
      out
    end

    # "Invoice#42" for anything with a GlobalID (Active Record records).
    def record(value)
      return nil unless value.respond_to?(:to_global_id)

      global_id(value.to_global_id.to_s)
    rescue StandardError
      nil
    end

    def global_id(text)
      match = GLOBAL_ID.match(text)
      match ? "#{match[:model]}##{match[:id]}" : '[RECORD]'
    end
  end
end
