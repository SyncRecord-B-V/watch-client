require "test_helper"

class EntryTest < Minitest::Test
  def setup
    SyncRecordWatch.reset!
    @config = SyncRecordWatch.configuration
    @config.environment = "staging"
    @config.host = "web-2"
    @config.app_version = nil
  end

  def teardown
    SyncRecordWatch.reset!
  end

  def build(**args)
    SyncRecordWatch::Entry.build(@config, **{ severity: :info, message: "hi", context: {} }.merge(args))
  end

  def test_maps_logger_severities_to_hub_levels
    assert_equal "debug", build(severity: Logger::DEBUG)["level"]
    assert_equal "warn", build(severity: Logger::WARN)["level"]
    assert_equal "fatal", build(severity: Logger::FATAL)["level"]
    assert_equal "unknown", build(severity: Logger::UNKNOWN)["level"]
    assert_equal "error", build(severity: :error)["level"]
  end

  def test_strips_ansi_colors_and_whitespace
    entry = build(message: "\e[1m\e[36mUser Load (0.4ms)\e[0m  SELECT 1\n")
    assert_equal "User Load (0.4ms)  SELECT 1", entry["message"]
  end

  def test_truncates_huge_messages
    entry = build(message: "x" * 100_000)
    assert_equal SyncRecordWatch::Entry::MAX_MESSAGE_BYTES, entry["message"].bytesize
  end

  def test_repairs_invalid_utf8
    entry = build(message: "caf\xC3".dup.force_encoding("BINARY"))
    assert entry["message"].valid_encoding?
    JSON.generate(entry)
  end

  def test_structured_hash_messages_become_fields
    entry = build(message: { event: "invoice.sent", invoice_id: 7, message: "Invoice sent" })
    assert_equal "Invoice sent", entry["message"]
    assert_equal "invoice.sent", entry["event"]
    assert_equal 7, entry["invoice_id"]
  end

  def test_structured_fields_cannot_overwrite_core_columns
    entry = build(message: { message: "x", level: "fatal", environment: "hacked" })
    assert_equal "info", entry["level"]
    assert_equal "staging", entry["environment"]
  end

  def test_masks_filtered_keys_like_rails
    @config.filter_keys = [ :passw, :token, /\Acard_/ ]
    entry = build(payload: { password: "secret", api_token: "abc", card_number: "4111", user: { password_confirmation: "s" }, ok: 1 })
    assert_equal "[FILTERED]", entry["password"]
    assert_equal "[FILTERED]", entry["api_token"]
    assert_equal "[FILTERED]", entry["card_number"]
    assert_equal({ "password_confirmation" => "[FILTERED]" }, entry["user"])
    assert_equal 1, entry["ok"]
  end

  def test_includes_context_fields
    entry = build(context: { request_id: "req-1", job_id: "j-1", job_class: "SyncJob" })
    assert_equal "req-1", entry["request_id"]
    assert_equal "j-1", entry["job_id"]
    assert_equal "SyncJob", entry["job_class"]
  end

  def test_resolves_user_id_only_inside_requests
    @config.current_user_id = -> { 42 }
    assert_equal "42", build(context: { request_id: "r" })["user_id"]
    assert_nil build(context: {})["user_id"]
  end

  def test_user_id_resolver_can_read_the_rack_env
    @config.current_user_id = ->(env) { env["warden.user"] }
    Thread.current[:syncrecord_watch_rack_env] = { "warden.user" => 7 }
    assert_equal "7", build(context: { request_id: "r" })["user_id"]
  ensure
    Thread.current[:syncrecord_watch_rack_env] = nil
  end

  def test_user_id_resolver_errors_are_ignored
    @config.current_user_id = -> { raise "boom" }
    assert_nil build(context: { request_id: "r" })["user_id"]
  end

  def test_exceptions_as_messages
    entry = build(severity: :error, message: ArgumentError.new("bad input"))
    assert_equal "ArgumentError: bad input", entry["message"]
    assert_equal "ArgumentError", entry["exception_class"]
  end
end
