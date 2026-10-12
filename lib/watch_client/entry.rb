require "time"

module WatchClient
  # Builds the JSON-ready hash Watch expects for one log line.
  module Entry
    LEVEL_NAMES = %w[debug info warn error fatal unknown].freeze
    MAX_MESSAGE_BYTES = 32 * 1024
    ANSI_COLOR = /\e\[[\d;]*m/
    FILTERED = "[FILTERED]".freeze
    # Fields Watch stores in columns; everything else ends up in its payload.
    RESERVED = %w[timestamp level message environment host request_id user_id job_id].freeze

    module_function

    # severity: 0..5 (Logger constants) or a name like :error
    # message:  String, Hash (structured log) or Exception
    def build(config, severity:, message:, time: Time.now, payload: nil, context: Context.current)
      level = level_name(severity)
      text, structured = split_message(message)
      fields = {}
      fields.merge!(stringify(structured)) if structured
      fields.merge!(stringify(payload)) if payload
      fields = filter(fields, config.filter_keys) unless fields.empty?

      entry = {
        "timestamp" => time.utc.iso8601(6),
        "level" => level,
        "message" => clean(text),
        "environment" => config.environment.to_s,
        "host" => config.host
      }
      entry["app_version"] = config.app_version if config.app_version

      context.each { |key, value| entry[key.to_s] = scalar(value) }
      entry["user_id"] ||= resolve_user_id(config) if context.key?(:request_id)

      fields.each do |key, value|
        # Structured fields never overwrite the core columns.
        entry[key] = value unless entry.key?(key) && RESERVED.include?(key)
      end
      entry.delete_if { |_, value| value.nil? }
    end

    def level_name(severity)
      case severity
      when Integer then LEVEL_NAMES[severity] || "unknown"
      else
        name = severity.to_s.downcase
        LEVEL_NAMES.include?(name) ? name : "info"
      end
    end

    def level_index(severity)
      LEVEL_NAMES.index(level_name(severity))
    end

    # Returns [text, structured_hash_or_nil].
    def split_message(message)
      case message
      when Hash
        hash = stringify(message)
        text = hash.delete("message") || hash.delete("msg") || hash["event"] || hash.map { |k, v| "#{k}=#{v}" }.join(" ")
        [ text.to_s, hash ]
      when Exception
        [ "#{message.class}: #{message.message}", { "exception_class" => message.class.name } ]
      when nil
        [ "", nil ]
      else
        [ message.to_s, nil ]
      end
    end

    def clean(text)
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text = text.scrub("?").gsub(ANSI_COLOR, "").strip
      text.bytesize > MAX_MESSAGE_BYTES ? text.byteslice(0, MAX_MESSAGE_BYTES).scrub("") : text
    end

    def stringify(hash)
      hash.each_with_object({}) { |(key, value), out| out[key.to_s] = json_safe(value) }
    end

    def json_safe(value)
      case value
      when nil, true, false, Integer, Float then value
      when String then value.dup.force_encoding(Encoding::UTF_8).scrub("?")
      when Symbol then value.to_s
      when Hash then stringify(value)
      when Array then value.map { |item| json_safe(item) }
      when Time then value.utc.iso8601(6)
      else value.respond_to?(:as_json) ? json_safe(value.as_json) : value.to_s
      end
    end

    def scalar(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false ? value : value.to_s
    end

    # Masks values whose key matches a filter (Strings match as substrings, like Rails).
    def filter(hash, keys)
      return hash if keys.nil? || keys.empty?

      hash.each_with_object({}) do |(key, value), out|
        out[key] =
          if filtered_key?(key, keys) then FILTERED
          elsif value.is_a?(Hash) then filter(value, keys)
          elsif value.is_a?(Array) then value.map { |item| item.is_a?(Hash) ? filter(item, keys) : item }
          else value
          end
      end
    end

    def filtered_key?(key, keys)
      name = key.to_s.downcase
      keys.any? do |filter|
        case filter
        when Regexp then filter.match?(key.to_s)
        when Proc then false
        else name.include?(filter.to_s.downcase)
        end
      end
    end

    # Calls the app's current_user_id lambda, never twice at once on a thread
    # (the lambda itself might log) and never letting errors escape.
    def resolve_user_id(config)
      resolver = config.current_user_id
      return nil unless resolver
      return nil if Thread.current[:watch_client_resolving_user]

      Thread.current[:watch_client_resolving_user] = true
      # ->(env) { ... } gets the Rack env (e.g. to ask Warden); -> { ... } gets nothing.
      id = resolver.arity == 1 ? resolver.call(Thread.current[:watch_client_rack_env] || {}) : resolver.call
      id&.to_s
    rescue StandardError
      nil
    ensure
      Thread.current[:watch_client_resolving_user] = nil if resolver
    end
  end
end
