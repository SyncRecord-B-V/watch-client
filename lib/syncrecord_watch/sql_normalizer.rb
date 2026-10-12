require "digest"

module SyncRecordWatch
  # Turns SQL into a shape without values, so queries that differ only in their
  # values group together and no data (emails, tokens...) leaves the app:
  #
  #   SELECT * FROM users WHERE email = 'a@b.c' AND id IN (1, 2, 3) LIMIT 10
  #   => SELECT * FROM users WHERE email = ? AND id IN (?) LIMIT ?
  module SqlNormalizer
    MAX_LENGTH = 2_000

    COMMENTS = %r{/\*.*?\*/|--[^\n]*}m
    # '..' strings and dollar quotes, also tagged ones: $$..$$, $body$..$body$.
    STRINGS = /'(?:[^']|'')*'|\$(\w*)\$.*?\$\1\$/m
    # What is left of a string whose end is missing: pg_stat_activity cuts queries off at
    # track_activity_query_size, sometimes in the middle of a value. Everything from there is dropped.
    UNTERMINATED = /'|\$\w*\$/
    # E'..', B'..', X'..' prefixes stay attached to the string they introduce.
    PREFIXED = /\b[EBX]\?/i
    NUMBERS = /(?<![\w$."])-?\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b/i
    BIND_PARAMS = /\$\d+\b/
    BOOLEANS = /\b(?:TRUE|FALSE)\b/i
    LISTS = /\((?:\s*\?\s*,)+\s*\?\s*\)/
    VALUES_ROWS = /(VALUES\s*\(\?\))(?:\s*,\s*\(\?\))+/i

    module_function

    def normalize(sql)
      text = sql.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      text = text.gsub(COMMENTS, " ")
      text = text.gsub(STRINGS, "?").gsub(PREFIXED, "?")
      if (cut = text.index(UNTERMINATED))
        text = "#{text[0, cut]}?…"
      end
      text = text.gsub(BIND_PARAMS, "?").gsub(NUMBERS, "?").gsub(BOOLEANS, "?")
      text = text.gsub(/\s+/, " ").strip
      text = text.gsub(LISTS, "(?)")
      text = text.gsub(VALUES_ROWS, '\1')
      text.length > MAX_LENGTH ? "#{text[0, MAX_LENGTH]}…" : text
    end

    # Short, stable ID of a normalized query (case and spacing don't matter).
    def fingerprint(normalized)
      Digest::SHA256.hexdigest(normalized.downcase)[0, 16]
    end

    # BEGIN / COMMIT / SAVEPOINT and friends: never interesting as slow queries.
    def transaction_statement?(sql)
      sql.to_s.lstrip.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|START TRANSACTION|SET|SHOW)\b/i)
    end
  end
end
