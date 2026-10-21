# frozen_string_literal: true

require 'test_helper'

class JobDetailsTest < Minitest::Test
  Record = Struct.new(:id) do
    def to_global_id = "gid://billing/Invoice/#{id}"
  end

  FakeJob = Struct.new(:job_id, :queue_name, :executions, :arguments)

  def setup
    @config = WatchClient::Configuration.new
    @config.filter_keys = [:passw]
    @config.send_job_arguments = true
  end

  def describe(job) = WatchClient::JobDetails.describe(job, @config)

  def test_active_job_with_records_filtered_hashes_and_masked_emails
    job = FakeJob.new('j-1', 'default', 3, [Record.new(42), { 'password' => 'p', 'api_token' => 't', 'mode' => 'full' },
                                            'jane@example.com', 'x' * 400, :sym, 1.5])
    details = describe(job)
    assert_equal({ 'id' => 'j-1', 'queue' => 'default', 'attempt' => 3 }, details.slice('id', 'queue', 'attempt'))
    record, hash, email, long, sym, float = details['arguments']
    assert_equal 'Invoice#42', record
    assert_equal({ 'password' => '[FILTERED]', 'api_token' => '[FILTERED]', 'mode' => 'full' }, hash)
    assert_equal '[FILTERED]', email
    assert_equal 301, long.length
    assert_equal ['sym', 1.5], [sym, float]
  end

  def test_sidekiq_wrapped_active_job_arguments
    job = { 'class' => 'Sidekiq::ActiveJob::Wrapper', 'wrapped' => 'SyncJob', 'jid' => 'abc', 'queue' => 'sync', 'retry_count' => 1,
            'args' => [{ 'job_class' => 'SyncJob', 'arguments' => [{ '_aj_globalid' => 'gid://billing/Account/7' },
                                                                   { 'full' => true, '_aj_symbol_keys' => ['full'] }] }] }
    details = describe(job)
    assert_equal({ 'class' => 'SyncJob', 'id' => 'abc', 'queue' => 'sync', 'attempt' => 2,
                   'arguments' => ['Account#7', { 'full' => true }] }, details)
  end

  def test_off_by_default_and_opt_in_per_job
    refute WatchClient::Configuration.new.send_job_arguments
    @config.send_job_arguments = false
    refute describe(FakeJob.new('j', 'q', 1, ['reset-token-123'])).key?('arguments')

    picky = Class.new(FakeJob) { def self.watch_arguments(args) = [args.first] }
    assert_equal ['Invoice#7'], describe(picky.new('j', 'q', 1, [Record.new(7), 'reset-token-123']))['arguments']
  end

  def test_big_payloads_stop_early_and_cheaply
    nested = Array.new(2_000) { |i| { "k#{i}" => 'v' * 1_000, 'deep' => Array.new(100) { 'x' * 100 } } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    args = describe(FakeJob.new('j', 'q', 1, [nested]))['arguments']
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.05
    assert_operator JSON.generate(args).bytesize, :<, 10_000
    assert_includes JSON.generate(args), '[TRUNCATED]'
    assert_equal 301, describe(FakeJob.new('j', 'q', 1, ['z' * 1_000_000]))['arguments'].first.length
  end

  def test_cycles_are_detected
    loop_hash = { 'a' => 1 }
    loop_hash['self'] = loop_hash
    assert_equal [{ 'a' => 1, 'self' => '[CIRCULAR]' }], describe(FakeJob.new('j', 'q', 1, [loop_hash]))['arguments']
  end

  def test_nothing_is_captured_when_watch_is_off
    error = RuntimeError.new('boom')
    @config.enabled = false
    job = FakeJob.new('j', 'q', 1, [])
    WatchClient::JobDetails.with(job) { WatchClient::JobDetails.attach(error, job, @config) }
    refute error.instance_variable_defined?(WatchClient::JobDetails::IVAR)
  end

  def test_the_error_keeps_its_job_after_the_job_ended
    error = RuntimeError.new('boom')
    @config.enabled = true
    WatchClient::JobDetails.with(FakeJob.new('j-9', 'default', 1, [Record.new(1)])) do
      WatchClient::JobDetails.attach(error, Thread.current[WatchClient::JobDetails::KEY], @config)
    end
    assert_nil Thread.current[WatchClient::JobDetails::KEY]
    assert_equal ['Invoice#1'], WatchClient::JobDetails.for_notice(error, @config)['arguments']
    assert_nil WatchClient::JobDetails.for_notice(RuntimeError.new('outside'), @config)
  end

  def test_notice_includes_the_job
    error = RuntimeError.new('boom')
    @config.enabled = true
    job = FakeJob.new('j-9', 'default', 2, [])
    WatchClient::JobDetails.with(job) { WatchClient::JobDetails.attach(error, job, @config) }
    notice = WatchClient::Notice.build(@config, error, handled: false)
    assert_equal({ 'class' => 'JobDetailsTest::FakeJob', 'id' => 'j-9', 'queue' => 'default', 'attempt' => 2, 'arguments' => [] },
                 notice['job'])
  end

  def test_long_keys_are_dropped_with_their_value_never_cut
    long = "#{'a' * 120}_password"
    args = describe(FakeJob.new('j', 'q', 1, [{ long => 'hunter2', ('b' * 150).to_s => 'also-secret', 'ok' => 1 }]))['arguments']
    json = JSON.generate(args)
    refute_includes json, 'hunter2'
    refute_includes json, 'also-secret'
    assert_equal({ '[LONG KEY]' => '[FILTERED]', 'ok' => 1 }, args.first)
  end
end
