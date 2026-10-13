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
  # A small SQL scanner rather than regexps, so escapes can't end a string early:
  # 'it''s', E'it\'s' (backslash escapes), $$...$$ and $tag$...$tag$ dollar quotes, comments
  # (--, # in MySQL and nested /* */, removed: they can hold data too) and quoted identifiers.
  #
  # Dialects: PostgreSQL / SQLite ("table_2023" is an identifier) and MySQL / MariaDB ("text"
  # is a string value unless ANSI_QUOTES, `table` is an identifier). Whether a backslash
  # escapes a quote depends on server settings (standard_conforming_strings,
  # NO_BACKSLASH_ESCAPES), so a string is read both ways: when the two readings end in
  # different places, everything from that string on is dropped. A value or comment whose end
  # is missing (pg_stat_activity cuts queries off at 1 KB) is dropped with everything after it.
  module SqlNormalizer
    MAX_LENGTH = 2_000
    CUT = '?…'

    LISTS = /\((?:\s*\?\s*,)+\s*\?\s*\)/
    VALUES_ROWS = /(VALUES\s*\(\?\))(?:\s*,\s*\(\?\))+/i
    WORD = /[[:alpha:]_][[:alnum:]_$]*/
    NUMBER = /\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?/
    DOLLAR_TAG = /\$([A-Za-z_]\w*)?\$/
    STRING_PREFIXES = %w[e b x n].freeze
    OTHER = %r{[^'"`\#$\-/\w.]+}
    MYSQL_ADAPTER = /mysql|trilogy|maria/i

    module_function

    # dialect: :mysql or :standard (PostgreSQL, SQLite); nil = the app's database adapter.
    def normalize(sql, dialect: nil)
      text = scrub(sql.to_s, dialect || default_dialect)
      text = text.gsub(/\s+/, ' ').strip
      text = text.gsub(LISTS, '(?)')
      text = text.gsub(VALUES_ROWS, '\1')
      text.length > MAX_LENGTH ? "#{text[0, MAX_LENGTH]}…" : text
    end

    # :mysql for MySQL / MariaDB / Trilogy connections (an ActiveRecord connection, adapter or
    # its name), else :standard.
    def dialect_for(connection)
      name = connection.respond_to?(:adapter_name) ? connection.adapter_name : connection
      name.to_s.match?(MYSQL_ADAPTER) ? :mysql : :standard
    rescue StandardError
      default_dialect
    end

    # From the app's primary database config (no connection is opened).
    def default_dialect
      return @default_dialect if defined?(@default_dialect) && @default_dialect
      return :standard unless defined?(::ActiveRecord::Base)

      adapter = ::ActiveRecord::Base.connection_db_config&.adapter
      return :standard if adapter.nil?

      @default_dialect = adapter.to_s.match?(MYSQL_ADAPTER) ? :mysql : :standard
    rescue StandardError
      :standard
    end

    def reset_dialect!
      @default_dialect = nil
    end

    # Replaces every literal value with ? and removes comments.
    def scrub(sql, dialect = :standard)
      mysql = dialect == :mysql
      s = StringScanner.new(sql.dup.force_encoding(Encoding::UTF_8).scrub)
      out = +''
      until s.eos?
        if s.skip(/--[^\n]*/) || (mysql && s.skip(/#[^\n]*/))
          out << ' '
        elsif s.check(%r{/\*})
          return out << ' …' unless skip_block_comment(s)

          out << ' '
        elsif (word = s.scan(WORD))
          if STRING_PREFIXES.include?(word.downcase) && s.check(/'/)
            read = word.casecmp?('e') ? skip_string(s, escapes: true) : skip_ambiguous_string(s)
            return out << CUT unless read

            out << '?'
          elsif word.casecmp?('u') && s.check(/&'/)
            s.skip(/&/)
            return out << CUT unless skip_ambiguous_string(s)

            out << '?'
          elsif word.casecmp?('true') || word.casecmp?('false')
            out << '?'
          else
            out << word
          end
        elsif s.check(/'/) || (mysql && s.check(/"/))
          return out << CUT unless skip_ambiguous_string(s)

          out << '?'
        elsif mysql && s.check(/`/)
          identifier = s.scan(/`(?:[^`]|``)*`/)
          return out << CUT unless identifier

          out << identifier
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
    PLAIN_DOUBLE = /"(?:[^"]|"")*"/m
    ESCAPED_DOUBLE = /"(?:[^"\\]|""|\\.)*"/m

    # A quoted value where a backslash may or may not escape the quote (server setting). Read
    # both ways; false (cut the rest) unless both readings end at the same place.
    def skip_ambiguous_string(s)
      double = s.check(/"/)
      plain = s.match?(double ? PLAIN_DOUBLE : PLAIN_STRING)
      escaped = s.match?(double ? ESCAPED_DOUBLE : ESCAPED_STRING)
      return false if plain.nil? || plain != escaped

      s.pos += plain
      true
    end

    # E'it\'s' (always backslash escapes) or 'it''s'. False when the closing quote is missing.
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
