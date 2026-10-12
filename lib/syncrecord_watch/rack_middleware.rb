module SyncRecordWatch
  # Puts the request ID (from ActionDispatch::RequestId, which also accepts an
  # incoming X-Request-ID from another app) into the log context for the
  # whole request. Inserted right after ActionDispatch::RequestId.
  class RackMiddleware
    def initialize(app)
      @app = app
    end

    ENV_KEY = :syncrecord_watch_rack_env

    def call(env)
      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      previous_env = Thread.current[ENV_KEY]
      # Kept outside the context so it is never serialized; used by current_user_id ->(env) { ... }.
      Thread.current[ENV_KEY] = env
      # Time spent in outgoing HTTP calls during this request (performance monitoring).
      Thread.current[NetHTTPPropagation::HTTP_MS_KEY] = 0.0
      # Remember Puma's server once, for busy threads and backlog (process health).
      ProcessStats.puma_server ||= ::Puma::Server.current if defined?(::Puma::Server) && ::Puma::Server.respond_to?(:current)
      Context.with(request_id: request_id) do
        Breadcrumbs.with do
          @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException
          Notice.attach_context(e)
          Breadcrumbs.attach(e)
          raise
        end
      end
    ensure
      Thread.current[ENV_KEY] = previous_env
    end
  end
end
