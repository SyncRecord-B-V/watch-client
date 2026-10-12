module WatchClient
  # Raised by `bin/rails watch:test_error`.
  class TestError < StandardError; end

  # Builds the error notice Watch expects (POST /api/v1/errors).
  module Notice
    MAX_MESSAGE_BYTES = 8 * 1024
    MAX_PARAMS_BYTES = 16 * 1024
    MAX_CAUSES = 3
    CONTEXT_IVAR = :@__watch_context
    NOTIFIED_IVAR = :@__watch_notified
    MAX_SECTION_BYTES = 16 * 1024
    FILTERED = "[FILTERED]".freeze
    # Never sent as they are: credentials, the CSRF token, and headers that only repeat the visitor's
    # IP address (it is already in remote_ip; one copy is enough - GDPR data minimisation).
    SECRET_HEADERS = %w[HTTP_COOKIE HTTP_AUTHORIZATION HTTP_PROXY_AUTHORIZATION HTTP_X_API_KEY HTTP_X_CSRF_TOKEN
                        HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP HTTP_CF_CONNECTING_IP HTTP_TRUE_CLIENT_IP HTTP_FORWARDED].freeze
    CGI_KEYS = %w[REQUEST_METHOD SERVER_NAME SERVER_PORT SERVER_PROTOCOL SERVER_SOFTWARE SCRIPT_NAME PATH_INFO
                  REMOTE_ADDR CONTENT_TYPE CONTENT_LENGTH HTTPS rack.url_scheme].freeze
    FRAME = /\A(?<file>.+?):(?<line>\d+)(?::in [`'](?<method>.*)')?/

    module_function

    def build(config, exception, handled:, context: nil, fingerprint: nil, component: nil, request: nil, time: Time.now)
      log_context = context_for(exception)
      request ||= current_request
      request_info = request_info(request, config)

      notice = {
        "exception_class" => exception.class.name.to_s,
        "message" => truncate(Entry.clean(exception.message.to_s), MAX_MESSAGE_BYTES),
        "backtrace" => clean_backtrace(exception.backtrace, config),
        "causes" => causes(exception, config),
        "occurred_at" => time.utc.iso8601(6),
        "environment" => config.environment.to_s,
        "host" => config.host,
        "app_version" => config.app_version,
        "request_id" => log_context[:request_id],
        "component" => component || component_for(request, log_context),
        "handled" => handled ? true : false,
        "fingerprint" => fingerprint&.to_s
      }
      notice["user_id"] = Entry.resolve_user_id(config) if log_context[:request_id]
      notice["request"] = request_info if request_info
      notice["source"] = source_context(notice["backtrace"], config)
      notice["breadcrumbs"] = Breadcrumbs.for_exception(exception) if config.breadcrumbs
      notice["app_env"] = AppEnv.snapshot(config)
      notice["notifier"] = { "name" => "watch_client", "version" => VERSION, "language" => "ruby" }
      if request
        notice["session"] = session_info(request, config) if config.send_session
        notice["cookies"] = cookies_info(request, config)
        notice["cgi_env"] = cgi_env(request, config)
      end

      extra = Entry.stringify(log_context.reject { |key, _| %i[request_id].include?(key) })
      extra.merge!(Entry.stringify(context)) if context.is_a?(Hash)
      notice["context"] = Entry.filter(extra, config.filter_keys) unless extra.empty?

      notice.delete_if { |_, value| value.nil? }
    end

    # Context to use for this exception: the one saved when it was raised inside a
    # request or job (see .attach_context), else the current one.
    def context_for(exception)
      saved = exception.instance_variable_get(CONTEXT_IVAR) if exception.instance_variable_defined?(CONTEXT_IVAR)
      saved || Context.current
    end

    # Remembers the request/job context on the exception while it propagates, so it
    # is still known when Rails or Sidekiq report it after our context has ended.
    def attach_context(exception)
      return if exception.frozen? || exception.instance_variable_defined?(CONTEXT_IVAR)

      context = Context.current
      exception.instance_variable_set(CONTEXT_IVAR, context) unless context.empty?
    rescue StandardError
      nil
    end

    # True the first time it is called for an exception object (Rails.error, the
    # DebugExceptions interceptor and Sidekiq can all see the same exception).
    def first_report?(exception)
      return true if exception.frozen?
      return false if exception.instance_variable_defined?(NOTIFIED_IVAR)

      exception.instance_variable_set(NOTIFIED_IVAR, true)
      true
    rescue StandardError
      true
    end

    def ignored?(config, exception)
      names = Array(config.ignore_errors).map(&:to_s)
      return false if names.empty?

      exception.class.ancestors.any? { |ancestor| ancestor.is_a?(Class) && names.include?(ancestor.name) }
    end

    # Paths inside the app root become relative ("app/models/invoice.rb:3:in ..."),
    # so Watch can tell the app's own frames from gems.
    def clean_backtrace(backtrace, config)
      root = config.app_root.to_s
      prefix = root.empty? ? nil : "#{root.chomp('/')}/"
      Array(backtrace).first(config.backtrace_lines.to_i).map do |line|
        line = line.to_s
        if prefix && line.start_with?(prefix) && !line.include?("/vendor/") && !line.include?("/gems/")
          line.delete_prefix(prefix)
        else
          line
        end
      end
    end

    def causes(exception, config)
      list = []
      cause = exception.cause
      seen = [ exception.object_id ]
      while cause && list.size < MAX_CAUSES && !seen.include?(cause.object_id)
        seen << cause.object_id
        list << {
          "exception_class" => cause.class.name.to_s,
          "message" => truncate(Entry.clean(cause.message.to_s), MAX_MESSAGE_BYTES),
          "backtrace" => clean_backtrace(cause.backtrace, config).first(10)
        }
        cause = cause.cause
      end
      list
    end

    def current_request
      env = Thread.current[:watch_client_rack_env]
      return unless env && defined?(ActionDispatch::Request)

      ActionDispatch::Request.new(env)
    end

    def request_info(request, config)
      return unless request

      params = Entry.json_safe(request.filtered_parameters) rescue {}
      params = { "_truncated" => true } if JSON.generate(params).bytesize > MAX_PARAMS_BYTES
      path = request.respond_to?(:filtered_path) ? request.filtered_path : request.path

      {
        "method" => request.request_method,
        "url" => "#{request.base_url}#{path}",
        "params" => Entry.filter(params, config.filter_keys),
        "remote_ip" => (request.remote_ip rescue nil),
        "referrer" => request.get_header("HTTP_REFERER")&.to_s&.[](0, 1000),
        "user_agent" => request.get_header("HTTP_USER_AGENT")&.to_s&.[](0, 500),
        "headers" => headers(request, config)
      }.compact
    rescue StandardError
      nil
    end

    # All HTTP_* request headers as "User-Agent" etc. Cookie/Authorization values are hidden.
    def headers(request, config)
      out = {}
      request.env.each do |key, value|
        next unless key.start_with?("HTTP_")

        name = key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
        out[name] = SECRET_HEADERS.include?(key) ? FILTERED : value.to_s[0, 500]
      end
      limit(Entry.filter(out, config.filter_keys))
    end

    # Rack/CGI variables (server, path, remote address...) plus all headers, filtered.
    def cgi_env(request, config)
      env = request.env
      out = {}
      CGI_KEYS.each { |key| out[key] = env[key].to_s[0, 500] if env.key?(key) }
      query = request.respond_to?(:filtered_path) ? request.filtered_path.to_s.split("?", 2)[1] : nil
      out["QUERY_STRING"] = query if query
      env.each do |key, value|
        next unless key.start_with?("HTTP_")

        out[key] = SECRET_HEADERS.include?(key) ? FILTERED : value.to_s[0, 500]
      end
      limit(Entry.filter(out, config.filter_keys))
    rescue StandardError
      nil
    end

    # Session contents with the app's filter_parameters applied (CSRF token always hidden).
    def session_info(request, config)
      session = request.session
      return nil unless session.respond_to?(:to_hash)
      # Don't load a session the request never touched (that would send a new cookie).
      return nil if session.respond_to?(:loaded?) && !session.loaded?

      data = Entry.json_safe(session.to_hash)
      keys = Array(config.filter_keys) + [ /csrf/i, /\Asession_id\z/, /\Awarden\./ ]
      limit(Entry.filter(data, keys))
    rescue StandardError
      nil
    end

    # Cookie names; values are hidden unless send_cookie_values is on.
    def cookies_info(request, config)
      cookies = request.cookies
      return nil if cookies.nil? || cookies.empty?

      out = cookies.to_h.transform_values { |value| config.send_cookie_values ? value.to_s[0, 300] : FILTERED }
      limit(Entry.filter(out, config.filter_keys))
    rescue StandardError
      nil
    end

    # Code around the first few app frames: [{ "index", "file", "line", "method", "start", "lines" }]
    def source_context(backtrace, config)
      root = config.app_root.to_s
      return [] if root.empty? || config.source_frames.to_i <= 0

      files = {}
      out = []
      Array(backtrace).each_with_index do |frame, index|
        break if out.size >= config.source_frames.to_i
        next if frame.start_with?("/") # not an app frame (gems, Ruby)

        match = FRAME.match(frame) or next
        path = File.join(root, match[:file])
        lines = (files[path] ||= read_source(path)) or next
        number = match[:line].to_i
        next if number < 1 || number > lines.size

        radius = config.source_lines.to_i
        first = [ number - radius, 1 ].max
        last = [ number + radius, lines.size ].min
        out << { "index" => index, "file" => match[:file], "line" => number, "method" => match[:method],
                 "start" => first, "lines" => lines[(first - 1)..(last - 1)].map { |line| line.chomp[0, 300] } }
      end
      out
    rescue StandardError
      []
    end

    def read_source(path)
      return nil unless File.file?(path) && File.size(path) < 1_000_000

      File.readlines(path, encoding: "UTF-8").map { |line| line.scrub("?") }
    rescue StandardError
      nil
    end

    def limit(hash)
      return hash if hash.nil? || JSON.generate(hash).bytesize <= MAX_SECTION_BYTES

      { "_truncated" => true }
    rescue StandardError
      { "_truncated" => true }
    end

    def component_for(request, log_context)
      return log_context[:job_class].to_s if log_context[:job_class]
      return unless request

      path_params = request.path_parameters
      controller = path_params[:controller]
      action = path_params[:action]
      return unless controller

      name = controller.to_s.split("/").map { |part| part.split("_").map(&:capitalize).join }.join("::")
      "#{name}Controller##{action}"
    rescue StandardError
      nil
    end

    def truncate(text, max_bytes)
      text.bytesize > max_bytes ? text.byteslice(0, max_bytes).scrub("") : text
    end
  end
end
