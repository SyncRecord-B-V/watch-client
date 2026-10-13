# frozen_string_literal: true

require 'erb'

module WatchClient
  # The <script> tag for watch.js (JavaScript errors and page speed), served by Watch itself.
  # In a Rails layout:  <%= watch_tag %>  or  <%= watch_tag(user_id: current_user&.id) %>
  # Renders nothing unless WATCH_URL and WATCH_BROWSER_KEY are set.
  module BrowserTag
    module_function

    def html(user_id: nil, environment: nil, version: nil, nonce: nil, config: WatchClient.configuration)
      return '' unless config.browser_enabled?

      attributes = {
        'src' => "#{config.url.to_s.chomp('/')}/watch.js",
        'data-key' => config.browser_key,
        'data-environment' => environment || config.environment,
        'data-version' => version || config.app_version,
        'data-user-id' => user_id,
        'data-vitals' => config.browser_vitals ? nil : 'false',
        'data-vitals-sample' => config.browser_vitals && config.vitals_sample_rate.to_f < 1 ? config.vitals_sample_rate.to_f.to_s : nil,
        'nonce' => nonce
      }.reject { |_name, value| value.nil? || value.to_s.empty? }

      rendered = attributes.map { |name, value| %(#{name}="#{ERB::Util.html_escape(value.to_s)}") }.join(' ')
      %(<script #{rendered} defer></script>)
    end

    # Rails view helper.
    module Helper
      def watch_tag(user_id: nil, environment: nil, version: nil)
        nonce = respond_to?(:content_security_policy_nonce) ? content_security_policy_nonce : nil
        html = WatchClient::BrowserTag.html(user_id: user_id, environment: environment, version: version, nonce: nonce)
        html.respond_to?(:html_safe) ? html.html_safe : html
      end
    end
  end
end
