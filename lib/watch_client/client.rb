# frozen_string_literal: true

module WatchClient
  # Buffers entries in memory and delivers them in batches from one background
  # thread. Never blocks or raises into the app:
  # - the buffer is capped (oldest entries are dropped when full),
  # - failed batches are retried with backoff, then dropped and counted,
  # - after a fork (Puma workers, Sidekiq) the child starts a fresh thread.
  class Client
    attr_reader :config, :transport

    def initialize(config, transport: Transport.new(config), batch_size: nil, flush_interval: nil)
      @config = config
      @transport = transport
      @batch_size = batch_size
      @flush_interval = flush_interval
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @buffer = []
      @stats = Hash.new(0)
      @pid = Process.pid
      @thread = nil
      @stopping = false
      @closed = false
    end

    def push(entry)
      @mutex.synchronize do
        reset_after_fork! if @pid != Process.pid
        return false if @closed

        @buffer << entry
        @buffer.shift(@buffer.size - config.max_queue).size.times { @stats[:dropped_queue_full] += 1 } if @buffer.size > config.max_queue
        @stats[:queued] += 1
        ensure_thread!
        @wakeup.signal if @buffer.size >= batch_size
      end
      true
    end

    def size
      @mutex.synchronize { @buffer.size }
    end

    def stats
      @mutex.synchronize { @stats.dup.merge(buffered: @buffer.size) }
    end

    # Sends everything buffered now, from the calling thread. Used by
    # WatchClient.flush, at shutdown, and in tests.
    def flush(timeout: config.shutdown_timeout)
      deadline = monotonic + timeout
      loop do
        batch = take_batch
        break if batch.empty?

        deliver(batch, retries: monotonic < deadline ? 1 : 0)
        break if monotonic >= deadline
      end
    end

    # Stops the worker and sends what is left (no retries). Further pushes are ignored.
    def shutdown(timeout: config.shutdown_timeout)
      thread = @mutex.synchronize do
        return if @closed

        @closed = true
        @stopping = true
        @wakeup.signal
        @thread
      end
      thread&.join(timeout)
      flush(timeout: timeout)
      transport.close
    end

    private

    def batch_size
      @batch_size || config.batch_size
    end

    def flush_interval
      @flush_interval || config.flush_interval
    end

    def ensure_thread!
      return if @thread&.alive?

      @thread = Thread.new { run }
      @thread.name = 'watch_client' if @thread.respond_to?(:name=)
      @thread.report_on_exception = false
    end

    def run
      loop do
        @mutex.synchronize do
          @wakeup.wait(@mutex, flush_interval) if !@stopping && @buffer.size < batch_size
        end
        break if stopping?

        while (batch = take_batch).any?
          deliver(batch, retries: config.max_retries)
          break if stopping?
        end
      end
    rescue StandardError => e
      diagnose("worker crashed: #{e.class}: #{e.message}")
    end

    def take_batch
      @mutex.synchronize { @buffer.shift(batch_size) }
    end

    def deliver(batch, retries:)
      attempt = 0
      loop do
        result = transport.post(batch)
        if result.ok?
          count(:sent, batch.size)
          count(:batches_sent, 1)
          return true
        elsif result.retry? && attempt < retries && !stopping?
          attempt += 1
          count(:retries, 1)
          sleep(backoff(attempt))
        else
          count(:dropped_delivery, batch.size)
          diagnose("dropped #{batch.size} entries: #{result.error}")
          return false
        end
      end
    end

    def backoff(attempt)
      [2**(attempt - 1), 30].min + rand * 0.5
    end

    def stopping?
      @mutex.synchronize { @stopping }
    end

    def count(key, amount)
      @mutex.synchronize { @stats[key] += amount }
    end

    # Called with the mutex held.
    def reset_after_fork!
      @pid = Process.pid
      @buffer.clear
      @thread = nil
      @stopping = false
      @closed = false
      @wakeup = ConditionVariable.new
      @transport = @transport.fresh
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Rate-limited: at most one line per 60 seconds per message kind.
    def diagnose(message)
      out = config.diagnostics
      return unless out

      key = message[0, 40]
      @last_diagnostics ||= {}
      now = monotonic
      return if @last_diagnostics[key] && now - @last_diagnostics[key] < 60

      @last_diagnostics[key] = now
      out.puts("[watch_client] #{message}")
    rescue StandardError
      nil
    end
  end
end
