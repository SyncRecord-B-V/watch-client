require "rails/railtie"
require "watch_client/rack_middleware"
require "watch_client/request_subscriber"
require "watch_client/active_job"
require "watch_client/error_subscriber"

module WatchClient
  class Railtie < Rails::Railtie
    # Defaults that depend on the Rails app; the app's initializer can still override them.
    initializer "watch_client.defaults", before: :load_config_initializers do |app|
      config = WatchClient.configuration
      config.environment = Rails.env.to_s if WatchClient::Configuration.env("ENVIRONMENT").nil?
      config.app_name ||= app.class.module_parent_name.underscore.dasherize
    end

    initializer "watch_client.middleware" do |app|
      app.middleware.insert_after ActionDispatch::RequestId, WatchClient::RackMiddleware
    end

    initializer "watch_client.view_helper" do
      ActiveSupport.on_load(:action_view) { include WatchClient::BrowserTag::Helper }
    end

    initializer "watch_client.active_job" do
      ActiveSupport.on_load(:active_job) { WatchClient::ActiveJobExtension.install(self) }
    end

    config.after_initialize do |app|
      config = WatchClient.configuration
      # Mask the same keys as the app's parameter filter (passwords, tokens...), and always at least
      # Rails' default list, also when the app has removed or never set it up.
      config.filter_keys ||= (app.config.filter_parameters + WatchClient::Configuration::DEFAULT_FILTER_KEYS).uniq
      config.app_root ||= Rails.root.to_s

      next unless config.enabled?

      WatchClient::Railtie.attach_logger!
      WatchClient::RequestSubscriber.subscribe!
      WatchClient::Metrics.install!(config)
      WatchClient::NetHTTPPropagation.install! if config.propagate_request_id || config.breadcrumbs || config.performance_monitoring
      WatchClient::Breadcrumbs.subscribe! if config.breadcrumbs
      if defined?(::Sidekiq)
        require "watch_client/sidekiq"
        WatchClient::SidekiqIntegration.install!
      end
      WatchClient::Railtie.attach_error_reporting! if config.send_errors
      WatchClient::DatabaseMonitor.install!(config) if config.database_monitoring && defined?(::ActiveRecord::Base)
      WatchClient::Dependencies.report_later(config)
      at_exit { WatchClient.shutdown }
    end

    rake_tasks do
      load File.expand_path("tasks.rake", __dir__)
    end

    generators do
      require File.expand_path("../generators/watch_client/install/install_generator", __dir__)
    end

    # Unhandled errors in requests reach the DebugExceptions interceptor (even when Rails
    # renders a 500 page); jobs and Rails.error.report/handle go through Rails.error.
    # Each exception object is only reported once.
    def self.attach_error_reporting!
      return if @error_reporting_attached

      @error_reporting_attached = true
      Rails.error.subscribe(WatchClient::ErrorSubscriber.new) if Rails.respond_to?(:error)
      if defined?(ActionDispatch::DebugExceptions)
        ActionDispatch::DebugExceptions.register_interceptor do |request, exception|
          # Report the real error (e.g. the cause inside ActionView::Template::Error), the
          # same object Rails' executor reports, so it is only sent once.
          if defined?(ActionDispatch::ExceptionWrapper)
            cleaner = request.get_header("action_dispatch.backtrace_cleaner")
            exception = ActionDispatch::ExceptionWrapper.new(cleaner, exception).unwrapped_exception
          end
          WatchClient.notify(exception, handled: false, request: request)
        end
      end
    end

    # Rails 7.1+ wraps Rails.logger in an ActiveSupport::BroadcastLogger:
    # add our logger as one more destination. Older loggers get wrapped.
    def self.attach_logger!
      logger = WatchClient.logger
      if Rails.logger.respond_to?(:broadcast_to)
        Rails.logger.broadcast_to(logger) unless Rails.logger.broadcasts.include?(logger)
      else
        Rails.logger = ActiveSupport::BroadcastLogger.new(Rails.logger, logger)
      end
    end
  end
end
