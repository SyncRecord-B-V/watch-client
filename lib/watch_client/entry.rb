# frozen_string_literal: true

require 'time'
require 'uri'
require 'json'

module WatchClient
  # Builds the JSON-ready hash Watch expects for one log line.
  module Entry
    LEVEL_NAMES = %w[debug info warn error fatal unknown].freeze
    MAX_MESSAGE_BYTES = 32 * 1024
    # One log line with all its fields, as JSON. Bigger fields are replaced by a note.
    MAX_ENTRY_BYTES = 64 * 1024
    MAX_FIELD_BYTES = 8 * 1024
    # Core columns other than the message (user_id, request_id, host...): short by nature.
    MAX_CORE_CHARS = 255
    ANSI_COLOR = /\e\[[\d;]*m/
    FILTERED = '[FILTERED]'
    # Fields Watch stores in columns; everything else ends up in its payload.
    RESERVED = %w[timestamp level message environment host request_id user_id job_id].freeze
    CORE = (RESERVED + %w[app_version]).freeze

    module_function

    # severity: 0..5 (Logger constants) or a name like :error
    # message:  String, Hash (structured log) or Exception
    def build(config, severity:, message:, time: Time.now, payload: nil, context: Context.current)
      level = level_name(severity)
      # Fields are filtered before anything is built from them (also the fallback message text).
      text, structured = split_message(message, config.filter_keys)
      fields = {}
      fields.merge!(structured) if structured
      fields.merge!(stringify(payload)) if payload
      fields = filter(fields, config.filter_keys) unless fields.empty?

      entry = {
        'timestamp' => time.utc.iso8601(6),
        'level' => level,
        'message' => clean(text),
        'environment' => config.environment.to_s,
        'host' => config.host
      }
      entry['app_version'] = config.app_version if config.app_version

      # with_context fields go through the same filter (an api_key in the context is masked).
      filter(stringify(context), config.filter_keys).each { |key, value| entry[key] = scalar(value) }
      entry['user_id'] ||= resolve_user_id(config) if context.key?(:request_id)

      fields.each do |key, value|
        # Structured fields never overwrite the core columns.
        entry[key] = value unless entry.key?(key) && RESERVED.include?(key)
      end
      limit_size(entry.delete_if { |_, value| value.nil? })
    end

    # Keeps one entry under MAX_ENTRY_BYTES: large structured fields become
    # "[TRUNCATED: n bytes]"; if that is not enough, all extra fields are dropped.
    # Core columns are always bounded (message: MAX_MESSAGE_BYTES, the rest MAX_CORE_CHARS), so
    # the final fallback is guaranteed to fit.
    def limit_size(entry)
      if json_bytes(entry).nil?
        entry = json_safe(entry)
        return entry.slice(*CORE).transform_values(&:to_s).merge('fields_unencodable' => true) if json_bytes(entry).nil?
      end
      (CORE - %w[message]).each do |key|
        value = entry[key]
        entry[key] = value[0, MAX_CORE_CHARS] if value.is_a?(String) && value.length > MAX_CORE_CHARS
      end
      return entry if json_bytes(entry).to_i <= MAX_ENTRY_BYTES

      (entry.keys - CORE).each do |key|
        bytes = json_bytes(entry[key]).to_i
        entry[key] = "[TRUNCATED: #{bytes} bytes]" if bytes > MAX_FIELD_BYTES
      end
      return entry if json_bytes(entry).to_i <= MAX_ENTRY_BYTES

      core = entry.slice(*CORE).merge('fields_truncated' => true)
      return core if json_bytes(core).to_i <= MAX_ENTRY_BYTES

      # Only reachable with a message full of characters JSON escapes (\u0000...).
      core.merge('message' => core['message'].to_s[0, 1024])
    end

    # nil when JSON can't encode the value.
    def json_bytes(value)
      JSON.generate(value).bytesize
    rescue StandardError
      nil
    end

    def level_name(severity)
      case severity
      when Integer then LEVEL_NAMES[severity] || 'unknown'
      else
        name = severity.to_s.downcase
        LEVEL_NAMES.include?(name) ? name : 'info'
      end
    end

    def level_index(severity)
      LEVEL_NAMES.index(level_name(severity))
    end

    # Returns [text, structured_hash_or_nil]. A hash is filtered first, so a text made from its
    # fields ("password=[FILTERED]") never shows a secret.
    def split_message(message, keys = nil)
      case message
      when Hash
        hash = filter(stringify(message), keys)
        text = hash.delete('message') || hash.delete('msg') || hash['event'] || hash.map do |k, v|
          "#{k}=#{v}"
        end.join(' ')
        [text.to_s, hash]
      when Exception
        ["#{message.class}: #{message.message}", { 'exception_class' => message.class.name }]
      when nil
        ['', nil]
      else
        [message.to_s, nil]
      end
    end

    def clean(text)
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text = text.scrub('?').gsub(ANSI_COLOR, '').strip
      text.bytesize > MAX_MESSAGE_BYTES ? text.byteslice(0, MAX_MESSAGE_BYTES).scrub('') : text
    end

    # Nesting deeper than this becomes "[TOO DEEP]"; a hash or array that contains itself
    # becomes "[CIRCULAR]". Keeps every conversion bounded whatever the app passes in.
    MAX_DEPTH = 20

    def stringify(hash, depth = 0, seen = nil)
      json_safe(hash, depth, seen)
    end

    # A copy JSON can always encode: string keys, UTF-8 strings, finite numbers ("NaN" and
    # "Infinity" as text), bounded depth, no cycles.
    def json_safe(value, depth = 0, seen = nil)
      return '[TOO DEEP]' if depth > MAX_DEPTH

      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      when String then value.dup.force_encoding(Encoding::UTF_8).scrub('?')
      when Symbol then value.to_s
      when Hash, Array then json_safe_container(value, depth, seen || {}.compare_by_identity)
      when Time then value.utc.iso8601(6)
      else value.respond_to?(:as_json) ? json_safe(value.as_json, depth + 1, seen) : value.to_s
      end
    rescue StandardError, SystemStackError
      '[UNREADABLE]'
    end

    # seen: the containers on the current path (a value repeated side by side is fine).
    def json_safe_container(value, depth, seen)
      return '[CIRCULAR]' if seen.key?(value)

      seen[value] = true
      begin
        if value.is_a?(Hash)
          value.each_with_object({}) { |(key, item), out| out[key.to_s] = json_safe(item, depth + 1, seen) }
        else
          value.map { |item| json_safe(item, depth + 1, seen) }
        end
      ensure
        seen.delete(value)
      end
    end

    def scalar(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false ? value : value.to_s
    end

    # Masks values whose key matches a filter rule, at every level (see Filter).
    def filter(hash, keys)
      Filter.hash(hash, keys)
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
