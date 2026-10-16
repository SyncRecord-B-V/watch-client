# frozen_string_literal: true

require 'time'

module WatchClient
  # Reads an API's quota from the headers of its answer, so Watch can show how much of an outside
  # API's limit is left (Performance > Outside APIs) without any code in the app. Only these numbers
  # are kept: never other headers or the body.
  #
  #   RateLimit-Limit / -Remaining / -Reset          IETF draft (newer APIs), also "RateLimit: limit=…, remaining=…, reset=…"
  #   X-RateLimit-Limit / -Remaining / -Reset        GitHub and many others
  #   X-RateLimit-Minutely-Limit / -Remaining / -Reset   Exact Online (per minute, next to the daily X-RateLimit-*)
  #   X-HubSpot-RateLimit-Daily / -Daily-Remaining   HubSpot (daily)
  #   Sforce-Limit-Info: api-usage=6247/140000       Salesforce (24 hours)
  #   X-Shopify-Shop-Api-Call-Limit: 32/40           Shopify (leaky bucket)
  #
  # Returns [{ "name", "limit", "remaining", "reset_at" (ISO 8601 or nil) }], at most MAX per answer.
  #
  # This runs on the app's request / job thread for every outgoing call, on headers sent by another
  # service: a header longer than MAX_HEADER_BYTES is ignored before any matching, numbers have a
  # bounded number of digits, and the one free-form header is read field by field up to MAX_FIELDS.
  module ApiQuota
    MAX = 4
    MAX_VALUE = 2**62
    MAX_HEADER_BYTES = 256
    MAX_FIELDS = 8
    NUMBER = /\A\s*-?\d{1,19}(?:\.\d{1,6})?\s*\z/
    FIELD = /\A\s*([a-z]{1,9})\s*=\s*(\d{1,19})\s*\z/i

    module_function

    # headers: anything answering [](name) case-insensitively (Net::HTTPResponse, a Hash with
    # lowercase keys).
    def parse(headers, now: Time.now)
      return [] unless headers.respond_to?(:[])

      quotas = []
      quotas << standard(headers, now)
      quotas << combined(headers, now)
      quotas << prefixed(headers, 'x-ratelimit-minutely', 'minute', now)
      quotas << prefixed(headers, 'x-ratelimit', exact_online?(headers) ? 'day' : 'default', now)
      quotas << hubspot(headers)
      quotas << salesforce(headers)
      quotas << shopify(headers)
      quotas.compact.uniq { |quota| quota['name'] }.first(MAX)
    rescue StandardError
      []
    end

    def standard(headers, now)
      build('default', header(headers, 'ratelimit-limit'), header(headers, 'ratelimit-remaining'),
            header(headers, 'ratelimit-reset'), now, relative: true)
    end

    # "RateLimit: limit=100, remaining=50, reset=30" (one header)
    def combined(headers, now)
      value = header(headers, 'ratelimit').to_s
      return nil if value.empty? || header(headers, 'ratelimit-remaining')

      fields = value.split(/[,;]/, MAX_FIELDS + 1).first(MAX_FIELDS).each_with_object({}) do |part, out|
        match = FIELD.match(part)
        out[match[1].downcase] ||= match[2] if match
      end
      build('default', fields['limit'], fields['remaining'] || fields['r'], fields['reset'] || fields['t'], now, relative: true)
    end

    def prefixed(headers, prefix, name, now)
      build(name, header(headers, "#{prefix}-limit"), header(headers, "#{prefix}-remaining"), header(headers, "#{prefix}-reset"), now)
    end

    def exact_online?(headers)
      !header(headers, 'x-ratelimit-minutely-remaining').nil?
    end

    def hubspot(headers)
      build('day', header(headers, 'x-hubspot-ratelimit-daily'), header(headers, 'x-hubspot-ratelimit-daily-remaining'), nil, nil)
    end

    # "api-usage=6247/140000": used / limit over the last 24 hours.
    def salesforce(headers)
      match = header(headers, 'sforce-limit-info').to_s.match(%r{api-usage=(\d{1,19})/(\d{1,19})})
      return nil unless match

      used = match[1].to_i
      limit = match[2].to_i
      build('day', limit, [limit - used, 0].max, nil, nil)
    end

    # "32/40": calls in the bucket / bucket size.
    def shopify(headers)
      match = header(headers, 'x-shopify-shop-api-call-limit').to_s.match(%r{\A\s*(\d{1,19})\s*/\s*(\d{1,19})\s*\z})
      return nil unless match

      limit = match[2].to_i
      build('bucket', limit, [limit - match[1].to_i, 0].max, nil, nil)
    end

    def build(name, limit, remaining, reset, now, relative: false)
      return nil unless number?(limit) && number?(remaining)

      limit = limit.to_s.to_f.floor
      remaining = remaining.to_s.to_f.floor
      return nil unless limit.positive? && limit <= MAX_VALUE && remaining.between?(-MAX_VALUE, MAX_VALUE)

      { 'name' => name, 'limit' => limit, 'remaining' => remaining.clamp(0, limit), 'reset_at' => reset_at(reset, now, relative) }
    end

    # Seconds from now (small numbers, or always for the IETF headers), a Unix time in seconds or
    # milliseconds (Exact Online), or an HTTP date.
    def reset_at(value, now, relative)
      return nil if value.nil? || now.nil?

      text = value.to_s.strip
      time =
        if text.match?(NUMBER)
          number = text.to_f
          if relative || number < 10_000_000 then now + number
          elsif number > 100_000_000_000 then Time.at(number / 1000.0)
          else Time.at(number)
          end
        else
          Time.httpdate(text)
        end
      return nil if time < now - 60 || time > now + (400 * 86_400)

      time.utc.iso8601
    rescue ArgumentError
      nil
    end

    # One header's value, or nil when it is missing, not a string or too long to be a real quota.
    def header(headers, name)
      value = headers[name]
      value.is_a?(String) && value.bytesize <= MAX_HEADER_BYTES ? value : nil
    end

    def number?(value)
      !value.nil? && value.to_s.match?(NUMBER)
    end
  end
end
