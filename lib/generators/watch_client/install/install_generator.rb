require "rails/generators/base"

module WatchClient
  module Generators
    # bin/rails generate watch_client:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Creates config/initializers/watch_client.rb"

      def copy_initializer
        template "watch_client.rb.tt", "config/initializers/watch_client.rb"
      end

      def show_next_steps
        say ""
        say "Next steps:", :green
        say "  1. In Watch (https://watch.syncrecord.com): Apps -> New app (\"#{app_label}\"), copy the API key"
        say "  2. Set WATCH_URL and WATCH_API_KEY where the app runs"
        say "  3. Deploy, then check with: bin/rails watch:test"
        say "  4. Record deploys: bin/rails watch:deploy after every deploy"
      end

      private

      def app_label
        Rails.application.class.module_parent_name.titleize
      end
    end
  end
end
