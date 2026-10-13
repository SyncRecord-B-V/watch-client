# frozen_string_literal: true

require 'test_helper'
require 'watch_client/sidekiq'
require 'watch_client/active_job'

class JobMetricsTest < Minitest::Test
  include WatchTestHelpers

  def setup
    @hub = FakeHub.new
    configure_for(@hub)
    @metrics = WatchClient::Metrics.new(WatchClient.configuration)
    @metrics.define_singleton_method(:ensure_running) { nil }
  end

  def teardown
    WatchClient.reset!
    @hub.stop
  end

  def test_runs_per_job_class
    @metrics.record_job(job_class: 'InvoiceMailerJob', queue: 'mailers', duration_ms: 120, wait_ms: 3_000)
    @metrics.record_job(job_class: 'InvoiceMailerJob', queue: 'mailers', duration_ms: 80, failed: true, wait_ms: 1_000)
    row = @metrics.build_payload['jobs'].first
    assert_equal({ 'job_class' => 'InvoiceMailerJob', 'queue' => 'mailers', 'count' => 2, 'errors' => 1, 'total_ms' => 200.0,
                   'max_ms' => 120.0, 'wait_ms' => 4_000.0, 'wait_max_ms' => 3_000.0 },
                 row.slice('job_class', 'queue', 'count', 'errors', 'total_ms', 'max_ms', 'wait_ms', 'wait_max_ms'))
  end

  def test_process_health_is_sent_every_minute
    assert @metrics.send_once
    body = @hub.next_request.json
    process = body['process']
    assert_includes %w[web worker other], process['role']
    assert_operator process['threads'], :>=, 1
    assert process.key?('uptime_s')
    assert_nil process['gc_count'], 'GC numbers are deltas: none on the first sample'
    second = @metrics.build_payload['process']
    assert second.key?('gc_count')
    refute body.key?('queues'), 'no job backend in this test'
  end

  def test_process_monitoring_can_be_turned_off
    WatchClient.configuration.process_monitoring = false
    refute @metrics.build_payload.key?('process')
  end

  def test_sidekiq_wait_in_seconds_or_milliseconds
    now = Time.now.to_f
    assert_in_delta 2_000, WatchClient::SidekiqIntegration.wait_ms({ 'enqueued_at' => now - 2 }), 200
    assert_in_delta 2_000, WatchClient::SidekiqIntegration.wait_ms({ 'enqueued_at' => ((now - 2) * 1000).to_i }), 200
    assert_nil WatchClient::SidekiqIntegration.wait_ms({})
  end

  def test_active_job_wait_uses_the_later_of_enqueued_and_scheduled
    job = Struct.new(:enqueued_at, :scheduled_at).new((Time.now - 10).utc.iso8601, Time.now - 3)
    assert_in_delta 3_000, WatchClient::ActiveJobExtension.wait_ms(job), 300
  end

  def test_sidekiq_middleware_times_native_jobs_only
    WatchClient::Metrics.install!
    WatchClient::Metrics.instance.define_singleton_method(:ensure_running) { nil }
    middleware = WatchClient::SidekiqIntegration::ServerMiddleware.new
    middleware.call(nil, { 'class' => 'ImportWorker', 'jid' => '1', 'enqueued_at' => Time.now.to_f }, 'default') { :ok }
    middleware.call(nil, { 'class' => 'Wrapper', 'wrapped' => 'MailJob', 'jid' => '2' }, 'default') { :ok }
    assert_raises(RuntimeError) do
      middleware.call(nil, { 'class' => 'ImportWorker', 'jid' => '3' }, 'default') { raise 'boom' }
    end
    jobs = WatchClient::Metrics.instance.build_payload['jobs']
    assert_equal(['ImportWorker'], jobs.map { |job| job['job_class'] })
    assert_equal [2, 1], [jobs.first['count'], jobs.first['errors']]
  end
end
