require "test_helper"
require "tmpdir"
require "fileutils"

class NoticeDetailsTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @root = Dir.mktmpdir("loghub-app")
    FileUtils.mkdir_p(File.join(@root, "app/models"))
    File.write(File.join(@root, "app/models/invoice.rb"), (1..20).map { |n| "line #{n}\n" }.join)
    @hub = FakeHub.new
    configure_for(@hub, app_root: @root)
  end

  def teardown
    SyncRecordWatch.reset!
    @hub.stop
    FileUtils.remove_entry(@root)
  end

  def error_with_backtrace
    raise ArgumentError, "bad total"
  rescue ArgumentError => e
    e.set_backtrace([ "#{@root}/app/models/invoice.rb:10:in 'total'", "/gems/rack/lib/rack.rb:5:in 'call'" ])
    e
  end

  def build(exception = error_with_backtrace)
    SyncRecordWatch::Notice.build(SyncRecordWatch.configuration, exception, handled: false)
  end

  def test_source_code_around_app_frames
    source = build["source"]
    assert_equal 1, source.size
    frame = source.first
    assert_equal 0, frame["index"]
    assert_equal "app/models/invoice.rb", frame["file"]
    assert_equal 10, frame["line"]
    assert_equal "total", frame["method"]
    assert_equal 7, frame["start"]
    assert_equal [ "line 7", "line 8", "line 9", "line 10", "line 11", "line 12", "line 13" ], frame["lines"]
  end

  def test_no_source_when_turned_off
    SyncRecordWatch.configuration.source_frames = 0
    assert_equal [], build["source"]
  end

  def test_app_environment_and_notifier
    notice = build
    assert_equal Process.pid, notice["app_env"]["pid"]
    assert_equal RUBY_VERSION, notice["app_env"]["ruby_version"]
    assert_equal @root, notice["app_env"]["project_root"]
    assert_equal "syncrecord_watch", notice["notifier"]["name"]
    assert_equal SyncRecordWatch::VERSION, notice["notifier"]["version"]
  end

  def test_breadcrumbs_are_kept_per_block_and_capped
    SyncRecordWatch.configuration.breadcrumbs_max = 3
    SyncRecordWatch::Breadcrumbs.with do
      5.times { |i| SyncRecordWatch::Breadcrumbs.add("query", "SELECT #{i}") }
      assert_equal [ "SELECT 2", "SELECT 3", "SELECT 4" ], SyncRecordWatch::Breadcrumbs.current.map { |c| c["message"] }
    end
    assert_equal [], SyncRecordWatch::Breadcrumbs.current
  end

  def test_breadcrumbs_travel_with_the_exception
    error = nil
    SyncRecordWatch::Breadcrumbs.with do
      SyncRecordWatch::Breadcrumbs.add("request", "InvoicesController#show", "path" => "/invoices/1")
      error = error_with_backtrace
      SyncRecordWatch::Breadcrumbs.attach(error)
    end

    crumbs = build(error)["breadcrumbs"]
    assert_equal [ "InvoicesController#show" ], crumbs.map { |c| c["message"] }
    assert_equal({ "path" => "/invoices/1" }, crumbs.first["metadata"])
  end

  def test_no_breadcrumbs_outside_a_request_or_job
    refute SyncRecordWatch::Breadcrumbs.add("query", "SELECT 1")
  end

  def test_warnings_from_the_logger_become_breadcrumbs
    SyncRecordWatch::Breadcrumbs.with do
      SyncRecordWatch.logger.info("just info")
      SyncRecordWatch.logger.warn("disk almost full")
      assert_equal [ "disk almost full" ], SyncRecordWatch::Breadcrumbs.current.map { |c| c["message"] }
    end
  end

  def test_sql_values_are_removed
    sql = "SELECT * FROM users WHERE email = 'jane@example.com' AND id = 42 AND name = 'O''Neil' LIMIT $1"
    assert_equal "SELECT * FROM users WHERE email = ? AND id = ? AND name = ? LIMIT $1",
                 SyncRecordWatch::Breadcrumbs.sanitize_sql(sql)
  end

  def test_outgoing_http_calls_become_breadcrumbs
    SyncRecordWatch::NetHTTPPropagation.install!
    SyncRecordWatch::Breadcrumbs.with do
      Net::HTTP.get_response(URI("#{@hub.url}/ping?secret=1"))
      crumb = SyncRecordWatch::Breadcrumbs.current.last
      assert_equal "http", crumb["category"]
      assert_match(%r{\AGET http://127\.0\.0\.1:\d+/ping 202\z}, crumb["message"])
    end
  end
end
