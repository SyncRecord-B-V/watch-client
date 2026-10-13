# frozen_string_literal: true

require 'digest'
require 'strscan'

module WatchClient
  # Turns SQL into a shape without values, so queries that differ only in their values group
  # together and no data (emails, tokens...) leaves the app. Used for every SQL the gem sends:
  # slow queries, top queries, the longest running query and query breadcrumbs.
  #
  #   SELECT * FROM users WHERE email = 'a@b.c' AND id IN (1, 2, 3) LIMIT 10
  #   => SELECT * FROM users WHERE email = ? AND id IN (?) LIMIT ?
  #
  # A small PostgreSQL-aware scanner rather than regexps, so escapes can't end a string early:
  # 'it''s', E'it\'s' (backslash escapes), $$...$$ and $tag$...$tag$ dollar quotes, comments
  # (-- and nested /* */, removed: they can hold data too) and quoted identifiers ("table_2023").
  # A value or comment whose end is missing (pg_stat_activity cuts queries off at 1 KB) is
  # dropped with everything after it.
  module SqlNormalizer
    MAX_LENGTH = 2_000
    CUT = '?…'

    LISTS = /\((?:\s*\?\s*,)+\s*\?\s*\)/
    VALUES_ROWS = /(VALUES\s*\(\?\))(?:\s*,\s*\(\?\))+/i
    WORD = /[[:alpha:]_][[:alnum:]_$]*/
    NUMBER = /\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?/
    DOLLAR_TAG = /\$([A-Za-z_]\w*)?\$/
    STRING_PREFIXES = %w[e b x n].freeze
    OTHER = %r{[^'"$\-/\w.]+}

    module_function

    def normalize(sql)
      text = scrub(sql.to_s)
      text = text.gsub(/\s+/, ' ').strip
      text = text.gsub(LISTS, '(?)')
      text = text.gsub(VALUES_ROWS, '\1')
      text.length > MAX_LENGTH ? "#{text[0, MAX_LENGTH]}…" : text
    end

    # Replaces every literal value with ? and removes comments.
    def scrub(sql)
      s = StringScanner.new(sql.dup.force_encoding(Encoding::UTF_8).scrub)
      out = +''
      until s.eos?
        if s.skip(/--[^\n]*/)
          out << ' '
        elsif s.check(%r{/\*})
          return out << ' …' unless skip_block_comment(s)

          out << ' '
        elsif (word = s.scan(WORD))
          if STRING_PREFIXES.include?(word.downcase) && s.check(/'/)
            return out << CUT unless skip_string(s, escapes: word.casecmp?('e'))

            out << '?'
          elsif word.casecmp?('u') && s.check(/&'/)
            s.skip(/&/)
            return out << CUT unless skip_string(s, escapes: false)

            out << '?'
          elsif word.casecmp?('true') || word.casecmp?('false')
            out << '?'
          else
            out << word
          end
        elsif s.check(/'/)
          return out << CUT unless skip_string(s, escapes: false)

          out << '?'
        elsif s.check(DOLLAR_TAG)
          tag = s.scan(DOLLAR_TAG)
          closing = s.search_full(Regexp.new(Regexp.escape(tag)), true, false)
          return out << CUT unless closing

          out << '?'
        elsif s.skip(/\$\d+/)
          out << '?'
        elsif s.check(/"/)
          identifier = s.scan(/"(?:[^"]|"")*"/)
          return out << CUT unless identifier

          out << identifier
        elsif s.scan(NUMBER)
          out << '?'
        else
          out << (s.scan(OTHER) || s.getch)
        end
      end
      out
    end

    PLAIN_STRING = /'(?:[^']|'')*'/m
    ESCAPED_STRING = /'(?:[^'\\]|''|\\.)*'/m

    # 'it''s' or, with escapes (E'...'), 'it\'s'. False when the closing quote is missing.
    def skip_string(s, escapes:)
      !s.skip(escapes ? ESCAPED_STRING : PLAIN_STRING).nil?
    end

    # /* ... */, which PostgreSQL lets nest. False when it never closes.
    def skip_block_comment(s)
      depth = 0
      until s.eos?
        if s.skip(%r{/\*})
          depth += 1
        elsif s.skip(%r{\*/})
          depth -= 1
          return true if depth.zero?
        else
          s.getch
        end
      end
      false
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
