# frozen_string_literal: true

module WatchClient
  # The first middleware of a Rails app. Rails reports errors from the app and from the middleware
  # after ActionDispatch::ShowExceptions itself (DebugExceptions, Rails.error), but not from the
  # middleware in front of it (Rack::Cors, Rack::Attack, a Redis session or rate-limit store
  # inserted at position 0...): those reach Puma as they are. This reports them, then raises them
  # again unchanged. An exception that was already reported is not sent twice.
  class OuterMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue Exception => e # rubocop:disable Lint/RescueException -- report, then re-raise as is
      if e.is_a?(StandardError) || e.is_a?(ScriptError)
        begin
          request = defined?(::ActionDispatch::Request) ? ::ActionDispatch::Request.new(env) : nil
          # The real error inside ActionView::Template::Error & co., the object Rails reports itself,
          # so it is never sent twice.
          error = begin
            defined?(::ActionDispatch::ExceptionWrapper) ? ::ActionDispatch::ExceptionWrapper.new(nil, e).unwrapped_exception : e
          rescue StandardError
            e
          end
          WatchClient.notify(error, handled: false, request: request)
        rescue StandardError
          nil
        end
      end
      raise
    end
  end
end
