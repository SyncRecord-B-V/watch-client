# frozen_string_literal: true

require 'test_helper'

class JobTimerTest < Minitest::Test
  def setup
    Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY] = nil # not inside a request
    Thread.current[WatchClient::JobTimer::KEY] = nil
    @metrics = WatchClient::Metrics.new(WatchClient::Configuration.new)
    @metrics.define_singleton_method(:ensure_running) { nil }
  end

  def test_counts_queries_and_http_time_of_a_run
    run = WatchClient::JobTimer.start
    WatchClient::JobTimer.sql(12.5, { name: 'User Load' })
    WatchClient::JobTimer.sql(7.5, { name: 'User Load' })
    WatchClient::JobTimer.sql(3.0, { name: 'SCHEMA' })
    WatchClient::JobTimer.sql(1.0, { name: 'CACHE', cached: true })
    Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY] += 40.0
    numbers = WatchClient::JobTimer.stop(run)
    assert_equal({ db_ms: 20.0, queries: 2, http_ms: 40.0 }, numbers)
    assert_nil Thread.current[WatchClient::JobTimer::KEY]
    assert_nil Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY]
  end

  def test_a_nested_job_is_measured_alone_and_added_to_the_outer_one
    outer = WatchClient::JobTimer.start
    WatchClient::JobTimer.sql(10, {})
    inner = WatchClient::JobTimer.start
    WatchClient::JobTimer.sql(5, {})
    Thread.current[WatchClient::NetHTTPPropagation::HTTP_MS_KEY] += 8.0
    assert_equal({ db_ms: 5.0, queries: 1, http_ms: 8.0 }, WatchClient::JobTimer.stop(inner))
    assert_equal({ db_ms: 15.0, queries: 2, http_ms: 8.0 }, WatchClient::JobTimer.stop(outer))
  end

  def test_no_counting_outside_a_job
    WatchClient::JobTimer.sql(10, {})
    assert_nil Thread.current[WatchClient::JobTimer::KEY]
  end

  def test_job_rows_carry_the_time_split
    @metrics.record_job(job_class: 'SyncJob', duration_ms: 100, db_ms: 30, queries: 12, http_ms: 50)
    @metrics.record_job(job_class: 'SyncJob', duration_ms: 100, db_ms: 10, queries: 3, http_ms: 0)
    row = @metrics.build_payload['jobs'].first
    assert_equal [40.0, 15, 50.0], row.values_at('db_ms', 'queries', 'http_ms')
  end

  def test_calls_are_counted_per_job_and_host
    WatchClient::Context.with(job_class: 'SalesforceSyncJob') do
      3.times { @metrics.record_http(host: 'login.salesforce.com', duration_ms: 100, status: '200') }
      @metrics.record_http(host: 'login.salesforce.com', duration_ms: 50, status: '429')
    end
    @metrics.record_http(host: 'login.salesforce.com', duration_ms: 100, status: '200') # in a request: not a job
    rows = @metrics.build_payload['job_http']
    assert_equal [{ 'count' => 4, 'errors' => 0, 'rate_limited' => 1, 'total_ms' => 350.0,
                    'job_class' => 'SalesforceSyncJob', 'host' => 'login.salesforce.com' }], rows
  end
end
