# frozen_string_literal: true

module WatchClient
  # Hides secrets and personal data before anything leaves the app. One place for every path:
  # structured log fields, log context, error params, session, headers, CGI variables, error
  # context and URLs (request URL, referrer).
  #
  # Uses the app's filter_parameters (in Rails, through ActiveSupport::ParameterFilter, so every
  # Rails rule works: substrings, regexps, dotted rules like "account.credential" and procs) plus
  # a built-in floor (Configuration::DEFAULT_FILTER_KEYS). Walks every level of nested hashes
  # and arrays.
  module Filter
    FILTERED = '[FILTERED]'
    # Query string values that are masked in URLs on top of the filter rules: secrets, and values
    # that usually identify a person (same list as watch.js).
    URL_SECRET = /token|secret|passw|key|auth|session|signature|code|e?mail|name|phone|tel|address|iban|zip|postcode|birth/i

    @cache = {}
    @mutex = Mutex.new

    module_function

    def rules(keys)
      (Array(keys) + Configuration::DEFAULT_FILTER_KEYS).uniq
    end

    # A filtered deep copy of a hash (anything else is returned as is).
    def hash(value, keys)
      return value unless value.is_a?(Hash)

      all = rules(keys)
      if (filter = parameter_filter(all))
        filter.filter(value)
      else
        filter_hash(value, all, nil)
      end
    rescue StandardError
      # Never send unfiltered data because a rule failed.
      value.transform_values { FILTERED }
    end

    # Whether a single key (e.g. a query string name) is covered by the rules.
    def key?(name, keys)
      matches?(name.to_s, nil, rules(keys))
    end

    # The URL with secret / personal query values masked and the fragment removed.
    def url(value, keys)
      return value if value.nil?

      text = value.to_s
      base, query = text.split('?', 2)
      base = base.split('#', 2).first
      return base if query.nil?

      query = query.split('#', 2).first
      "#{base}?#{query_string(query, keys)}"
    rescue StandardError
      text.to_s.split('?', 2).first
    end

    # "a=1&token=x" with the values of secret / personal names masked.
    def query_string(query, keys)
      all = rules(keys)
      query.to_s.split('&').map do |pair|
        name, val = pair.split('=', 2)
        next pair if val.nil?

        decoded = begin
          URI.decode_www_form_component(name.to_s)
        rescue StandardError
          name.to_s
        end
        hidden = URL_SECRET.match?(decoded) || matches?(decoded, nil, all)
        hidden ? "#{name}=#{FILTERED}" : pair
      end.join('&')
    end

    # ActiveSupport's own filter when it's loaded (Rails apps), cached per rule list.
    def parameter_filter(all)
      return nil unless defined?(::ActiveSupport::ParameterFilter)

      key = all.hash
      @mutex.synchronize do
        @cache.clear if @cache.size > 20
        @cache[key] ||= ::ActiveSupport::ParameterFilter.new(all, mask: FILTERED)
      end
    end

    # The same rules without ActiveSupport (plain Ruby apps).
    def filter_hash(hash, all, parent)
      hash.each_with_object({}) do |(key, value), out|
        full = parent ? "#{parent}.#{key}" : key.to_s
        out[key] = filter_value(key, value, all, full)
      end
    end

    def filter_value(key, value, all, full)
      return FILTERED if matches?(key.to_s, full, all)

      case value
      when Hash then filter_hash(value, all, full)
      when Array then value.map { |item| filter_value(key, item, all, full) }
      else apply_procs(key, value, all)
      end
    end

    def matches?(name, full, all)
      all.any? do |rule|
        case rule
        when Regexp then rule.match?(name) || (full && rule.source.include?('\\.') && rule.match?(full))
        when Proc then false
        else
          text = rule.to_s.downcase
          if text.include?('.')
            full&.downcase&.include?(text)
          else
            name.downcase.include?(text)
          end
        end
      end
    end

    def apply_procs(key, value, all)
      procs = all.grep(Proc)
      return value if procs.empty?

      copy = begin
        value.dup
      rescue StandardError
        value
      end
      procs.each { |rule| rule.arity == 2 ? rule.call(key.to_s.dup, copy) : rule.call(key.to_s.dup, copy, nil) }
      copy
    end
  end
end
