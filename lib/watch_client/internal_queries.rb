# frozen_string_literal: true

require 'logger'

module WatchClient
  # Wraps the gem's own database reads (database sampling, Solid Queue counts):
  #
  # * marks them internal, so they never show up as the app's slow queries or breadcrumbs;
  # * keeps them out of the app's log. ActiveRecord logs every query at DEBUG, so in
  #   development and `rails console` our monitoring SELECTs would otherwise appear in
  #   the middle of the user's own output.
  #
  # Silencing uses the logger's thread-local level (ActiveSupport::LoggerThreadSafeLevel),
  # so only the current (background) thread is quieted; the app's own queries on other
  # threads keep logging as before.
  module InternalQueries
    INTERNAL_KEY = :watch_client_internal

    module_function

    def run(logger = active_record_logger, &block)
      previous_internal = Thread.current[INTERNAL_KEY]
      Thread.current[INTERNAL_KEY] = true
      quietly(logger, &block)
    ensure
      Thread.current[INTERNAL_KEY] = previous_internal
    end

    def internal?
      Thread.current[INTERNAL_KEY] ? true : false
    end

    def quietly(logger)
      return yield unless logger.respond_to?(:local_level) && logger.respond_to?(:local_level=)

      previous = logger.local_level
      logger.local_level = ::Logger::ERROR
      begin
        yield
      ensure
        logger.local_level = previous
      end
    end

    def active_record_logger
      ::ActiveRecord::Base.logger if defined?(::ActiveRecord::Base)
    rescue StandardError
      nil
    end
  end
end
