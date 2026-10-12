require "test_helper"
require "loghub_client" # the old require path

# The gem used to be called loghub_client: old code, environment variables and the
# old view helper keep working.
class RenameCompatTest < Minitest::Test
  def teardown
    %w[SYNCRECORD_WATCH_URL LOGHUB_URL SYNCRECORD_WATCH_API_KEY LOGHUB_API_KEY].each { |name| ENV.delete(name) }
    SyncRecordWatch.reset!
  end

  def test_old_constant
    assert_same SyncRecordWatch, LoghubClient
  end

  def test_old_environment_variables_still_work
    ENV["LOGHUB_URL"] = "https://old.example.com"
    ENV["LOGHUB_API_KEY"] = "lh_old"
    config = SyncRecordWatch::Configuration.new
    assert_equal "https://old.example.com", config.url
    assert_equal "lh_old", config.api_key
  end

  def test_new_environment_variables_win
    ENV["LOGHUB_URL"] = "https://old.example.com"
    ENV["SYNCRECORD_WATCH_URL"] = "https://watch.example.com"
    assert_equal "https://watch.example.com", SyncRecordWatch::Configuration.new.url
  end

  def test_old_view_helper
    assert SyncRecordWatch::BrowserTag::Helper.method_defined?(:loghub_browser_tag)
    assert SyncRecordWatch::BrowserTag::Helper.method_defined?(:syncrecord_watch_tag)
  end
end
