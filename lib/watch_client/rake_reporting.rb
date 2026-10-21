# frozen_string_literal: true

require 'rake'

module WatchClient
  # Errors that end a rake task (`rake db:migrate`, a cron `rake invoices:send`...). Rake catches
  # them and prints them itself, so nothing else would see them. Sent right away: tasks that don't
  # load the Rails environment have no background sender.
  module RakeReporting
    SEND_TIMEOUT = 3
    def display_error_message(error)
      super
    ensure
      WatchClient::RakeReporting.report(error, top_level_tasks)
    end

    def self.report(error, tasks)
      return false if error.is_a?(SystemExit) || error.is_a?(SignalException)
      return false unless WatchClient.enabled?

      config = WatchClient.configuration
      config.filter_keys ||= Configuration::DEFAULT_FILTER_KEYS.dup
      names = Array(tasks).map(&:to_s).first(5)
      sent = WatchClient.notify(error, handled: false, component: "rake #{names.join(' ')}".strip[0, 200],
                                       context: { 'rake_tasks' => names })
      # Only the error, briefly and without retries: the task has failed, rake exits next.
      WatchClient.error_client.shutdown(timeout: SEND_TIMEOUT) if sent
      sent
    rescue StandardError
      false
    end

    def self.install!
      return if @installed

      @installed = true
      ::Rake::Application.prepend(self)
    end
  end
end
