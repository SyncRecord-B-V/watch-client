require "rails/railtie"
require "syncrecord_watch/rack_middleware"
require "syncrecord_watch/request_subscriber"
require "syncrecord_watch/active_job"
require "syncrecord_watch/error_subscriber"

module SyncRecordWatch
  class Railtie < Rails::Railtie
    # Defaults that depend on the Rails app; the app's initializer can still override them.
    initializer "syncrecord_watch.defaults", before: :load_config_initializers do |app|
      config = SyncRecordWatch.configuration
      config.environment = Rails.env.to_s if SyncRecordWatch::Configuration.env("ENVIRONMENT").nil?
      config.app_name ||= app.class.module_parent_name.underscore.dasherize
    end

    initializer "syncrecord_watch.middleware" do |app|
      app.middleware.insert_after ActionDispatch::RequestId, SyncRecordWatch::RackMiddleware
    end

    initializer "syncrecord_watch.view_helper" do
      ActiveSupport.on_load(:action_view) { include SyncRecordWatch::BrowserTag::Helper }
    end

    initializer "syncrecord_watch.active_job" do
      ActiveSupport.on_load(:active_job) { SyncRecordWatch::ActiveJobExtension.install(self) }
    end

    config.after_initialize do |app|
      config = SyncRecordWatch.configuration
      # Mask the same keys as the app's parameter filter (passwords, tokens...), and always at least
      # Rails' default list, also when the app has removed or never set it up.
      config.filter_keys ||= (app.config.filter_parameters + SyncRecordWatch::Configuration::DEFAULT_FILTER_KEYS).uniq
      config.app_root ||= Rails.root.to_s

      next unless config.enabled?

      SyncRecordWatch::Railtie.attach_logger!
      SyncRecordWatch::RequestSubscriber.subscribe!
      SyncRecordWatch::Metrics.install!(config)
      SyncRecordWatch::NetHTTPPropagation.install! if config.propagate_request_id || config.breadcrumbs || config.performance_monitoring
      SyncRecordWatch::Breadcrumbs.subscribe! if config.breadcrumbs
      if defined?(::Sidekiq)
        require "syncrecord_watch/sidekiq"
        SyncRecordWatch::SidekiqIntegration.install!
      end
      SyncRecordWatch::Railtie.attach_error_reporting! if config.send_errors
      SyncRecordWatch::DatabaseMonitor.install!(config) if config.database_monitoring && defined?(::ActiveRecord::Base)
      SyncRecordWatch::Dependencies.report_later(config)
      at_exit { SyncRecordWatch.shutdown }
    end

    rake_tasks do
      load File.expand_path("tasks.rake", __dir__)
    end

    generators do
      require File.expand_path("../generators/syncrecord_watch/install/install_generator", __dir__)
    end

    # Unhandled errors in requests reach the DebugExceptions interceptor (even when Rails
    # renders a 500 page); jobs and Rails.error.report/handle go through Rails.error.
    # Each exception object is only reported once.
    def self.attach_error_reporting!
      return if @error_reporting_attached

      @error_reporting_attached = true
      Rails.error.subscribe(SyncRecordWatch::ErrorSubscriber.new) if Rails.respond_to?(:error)
      if defined?(ActionDispatch::DebugExceptions)
        ActionDispatch::DebugExceptions.register_interceptor do |request, exception|
          # Report the real error (e.g. the cause inside ActionView::Template::Error), the
          # same object Rails' executor reports, so it is only sent once.
          if defined?(ActionDispatch::ExceptionWrapper)
            cleaner = request.get_header("action_dispatch.backtrace_cleaner")
            exception = ActionDispatch::ExceptionWrapper.new(cleaner, exception).unwrapped_exception
          end
          SyncRecordWatch.notify(exception, handled: false, request: request)
        end
      end
    end

    # Rails 7.1+ wraps Rails.logger in an ActiveSupport::BroadcastLogger:
    # add our logger as one more destination. Older loggers get wrapped.
    def self.attach_logger!
      logger = SyncRecordWatch.logger
      if Rails.logger.respond_to?(:broadcast_to)
        Rails.logger.broadcast_to(logger) unless Rails.logger.broadcasts.include?(logger)
      else
        Rails.logger = ActiveSupport::BroadcastLogger.new(Rails.logger, logger)
      end
    end
  end
end
