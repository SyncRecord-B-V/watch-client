# frozen_string_literal: true

require 'uri'

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

    # Deeper data (only possible from the app's own hashes) is masked rather than walked.
    MAX_FILTER_DEPTH = 32

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
        filter_hash(value, all, nil, value)
      end
    rescue StandardError, SystemStackError
      # Never send unfiltered data because a rule failed.
      value.transform_values { FILTERED }
    end

    # Whether a single key (e.g. a query string name) is covered by the rules.
    def key?(name, keys)
      matches?(name.to_s, nil, rules(keys))
    end

    # The URL with secret / personal query values masked and the fragment removed. A query that
    # is too long, too deep or has too many parameters is left out entirely.
    def url(value, keys)
      return value if value.nil?

      text = value.to_s
      base, query = text.split('?', 2)
      base = base.split('#', 2).first
      return base if query.nil?

      filtered = query_string(query.split('#', 2).first, keys)
      filtered ? "#{base}?#{filtered}" : base
    rescue StandardError, SystemStackError
      text.to_s.split(/[?#]/, 2).first
    end

    MAX_QUERY_BYTES = 4096
    MAX_QUERY_PARAMS = 100
    MAX_PARAM_DEPTH = 8
    PARAM_NAME = /\A([^\[\]]+)((?:\[[^\[\]]*\])*)\z/

    # "a=1&token=x" with the values of secret / personal names masked; nil (leave the query out)
    # when it is over MAX_QUERY_BYTES, MAX_QUERY_PARAMS or MAX_PARAM_DEPTH.
    #
    # The query is parsed like Rack parses request params ("account[credential]" nests, "ids[]"
    # collects, a repeated plain name keeps its last value) and the whole hash is filtered at
    # once, so dotted rules and procs that look at other parameters see what the app saw. Every
    # occurrence of a parameter is masked when the filter changed it or its name matches
    # URL_SECRET. Names Rack would read differently ("a[][b]", "a=1&a[b]=2") mask every value.
    def query_string(query, keys)
      query = query.to_s
      return nil if query.bytesize > MAX_QUERY_BYTES

      pairs = query.split('&')
      return nil if pairs.size > MAX_QUERY_PARAMS

      parsed = pairs.map { |pair| parse_pair(pair) }
      return nil if parsed.any? { |pair| pair[:path] == :too_deep }

      tree = param_tree(parsed)
      return parsed.map { |pair| masked(pair) }.join('&') if tree.nil?

      filtered = hash(tree, keys)
      parsed.map do |pair|
        next pair[:raw] if pair[:value].nil?

        secret = URL_SECRET.match?(pair[:path].join('.')) || changed?(tree, filtered, pair[:path])
        secret ? masked(pair) : pair[:raw]
      end.join('&')
    rescue StandardError, SystemStackError
      nil
    end

    # { raw:, name:, value:, path: [parts], array: } - path :ambiguous / :too_deep when Rack
    # would read the name differently or it nests deeper than MAX_PARAM_DEPTH.
    def parse_pair(pair)
      name, val = pair.split('=', 2)
      out = { raw: pair, name: name.to_s, value: val && decode(val) }
      return out if val.nil?

      match = PARAM_NAME.match(decode(name))
      return out.merge(path: :ambiguous) unless match

      segments = match[2].scan(/\[([^\[\]]*)\]/).flatten
      return out.merge(path: :too_deep) if segments.size > MAX_PARAM_DEPTH

      array = segments.last == ''
      segments.pop if array
      return out.merge(path: :ambiguous) if segments.include?('')

      out.merge(path: [match[1], *segments], array: array)
    end

    def masked(pair)
      pair[:value].nil? ? pair[:raw] : "#{pair[:name]}=#{FILTERED}"
    end

    # The params hash Rack would build, or nil when a name is ambiguous or names clash.
    def param_tree(pairs)
      tree = {}
      pairs.each do |pair|
        next if pair[:value].nil?
        return nil if pair[:path] == :ambiguous
        return nil unless insert_param(tree, pair[:path], pair[:value], pair[:array])
      end
      tree
    end

    def insert_param(tree, parts, value, array)
      node = tree
      parts[0..-2].each do |part|
        node[part] = {} if node[part].nil?
        return false unless node[part].is_a?(Hash)

        node = node[part]
      end
      last = parts.last
      if array
        node[last] = [] if node[last].nil?
        return false unless node[last].is_a?(Array)

        node[last] << value
      else
        return false if node[last].is_a?(Hash) || node[last].is_a?(Array)

        node[last] = value # a repeated name keeps its last value, like Rack
      end
      true
    end

    def changed?(tree, filtered, parts)
      filtered.dig(*parts) != tree.dig(*parts)
    rescue StandardError
      true
    end

    def decode(text)
      URI.decode_www_form_component(text.to_s)
    rescue StandardError
      text.to_s
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
    def filter_hash(hash, all, parent, root = hash, depth = 0)
      hash.each_with_object({}) do |(key, value), out|
        full = parent ? "#{parent}.#{key}" : key.to_s
        out[key] = filter_value(key, value, all, full, root, depth)
      end
    end

    def filter_value(key, value, all, full, root, depth = 0)
      return FILTERED if depth > MAX_FILTER_DEPTH || matches?(key.to_s, full, all)

      case value
      when Hash then filter_hash(value, all, full, root, depth + 1)
      when Array then value.map { |item| filter_value(key, item, all, full, root, depth + 1) }
      else apply_procs(key, value, all, root)
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

    def apply_procs(key, value, all, root = nil)
      procs = all.grep(Proc)
      return value if procs.empty?

      copy = begin
        value.dup
      rescue StandardError
        value
      end
      procs.each { |rule| rule.arity == 2 ? rule.call(key.to_s.dup, copy) : rule.call(key.to_s.dup, copy, root) }
      copy
    end
  end
end
