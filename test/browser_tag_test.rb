# frozen_string_literal: true

require_relative 'test_helper'

class BrowserTagTest < Minitest::Test
  def config(**overrides)
    WatchClient::Configuration.new.tap do |config|
      config.url = 'https://watch.example.com/'
      config.browser_key = 'lhb_abc'
      config.environment = 'production'
      config.app_version = 'v42'
      overrides.each { |name, value| config.public_send("#{name}=", value) }
    end
  end

  def test_renders_the_script_tag_with_settings
    html = WatchClient::BrowserTag.html(user_id: 7, config: config)
    assert_includes html, %(src="https://watch.example.com/watch.js")
    assert_includes html, %(data-key="lhb_abc")
    assert_includes html, %(data-environment="production")
    assert_includes html, %(data-version="v42")
    assert_includes html, %(data-user-id="7")
    assert_includes html, ' defer></script>'
  end

  def test_escapes_values
    html = WatchClient::BrowserTag.html(user_id: %("><script>x</script>), config: config)
    refute_includes html, '<script>x'
    assert_includes html, '&quot;&gt;&lt;script&gt;'
  end

  def test_adds_the_csp_nonce
    assert_includes WatchClient::BrowserTag.html(nonce: 'n0nce', config: config), %(nonce="n0nce")
  end

  def test_renders_nothing_without_a_browser_key_or_in_test
    assert_equal '', WatchClient::BrowserTag.html(config: config(browser_key: nil))
    assert_equal '', WatchClient::BrowserTag.html(config: config(environment: 'test'))
    refute_empty WatchClient::BrowserTag.html(config: config(environment: 'test', browser_enabled: true))
  end
end
