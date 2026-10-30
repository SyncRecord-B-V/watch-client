# frozen_string_literal: true

require 'json'

module WatchClient
  # Buffers entries in memory and delivers them in batches from one background
  # thread. Never blocks or raises into the app:
  # - the buffer is capped by count (max_queue) and by size (max_queue_bytes); the oldest
  #   entries are dropped when full,
  # - failed batches are retried with backoff, then dropped and counted,
  # - after a fork (Puma workers, Sidekiq) the child starts a fresh thread.
  class Client
    attr_reader :config, :transport

    # batch_bytes: a batch also stops at about this many JSON bytes (nil = count only).
    def initialize(config, transport: Transport.new(config), batch_size: nil, flush_interval: nil, batch_bytes: nil)
      @config = config
      @transport = transport
      @batch_size = batch_size
      @batch_bytes = batch_bytes
      @flush_interval = flush_interval
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @buffer = []
      @sizes = [] # JSON bytes per buffered entry, same order as @buffer
      @buffer_bytes = 0
      @stats = Hash.new(0)
      @pid = Process.pid
      @thread = nil
      @stopping = false
      @closed = false
    end

    def push(entry)
      entry, bytes = self.class.prepare(entry)
      @mutex.synchronize do
        reset_after_fork! if @pid != Process.pid
        if @closed
          diagnose('not sent: watch_client was already shut down (at exit)')
          return false
        end

        unless entry
          @stats[:dropped_unencodable] += 1
          return false
        end

        if bytes > max_queue_bytes
          @stats[:dropped_too_large] += 1
          return false
        end

        @buffer << entry
        @sizes << bytes
        @buffer_bytes += bytes
        drop_oldest while @buffer.size > config.max_queue.to_i || @buffer_bytes > max_queue_bytes
        @stats[:queued] += 1
        ensure_thread!
        @wakeup.signal if @buffer.size >= batch_size
      end
      true
    end

    def size
      @mutex.synchronize { @buffer.size }
    end

    # [entry, JSON bytes] as it will be sent, or [nil, 0] when JSON can't encode it (e.g. a
    # before_send / before_notify callback added NaN or circular data). Such an entry is
    # dropped and counted, never converted here, so the buffer only holds what was measured.
    def self.prepare(entry)
      [entry, JSON.generate(entry).bytesize]
    rescue StandardError, SystemStackError
      [nil, 0]
    end

    def stats
      @mutex.synchronize { @stats.dup.merge(buffered: @buffer.size, buffered_bytes: @buffer_bytes) }
    end

    # Sends everything buffered now, from the calling thread. Used by
    # WatchClient.flush, at shutdown, and in tests.
    def flush(timeout: config.shutdown_timeout, retries: 1)
      deadline = monotonic + timeout
      loop do
        batch = take_batch
        break if batch.empty?

        deliver(batch, retries: monotonic < deadline ? retries : 0)
        break if monotonic >= deadline
      end
    end

    # Stops the worker and sends what is left (no retries), within `timeout` in total. Further
    # pushes are ignored. In a forked child (Puma worker, Parallel) only the child's own entries
    # are sent: the parent's buffer and connection stay the parent's.
    def shutdown(timeout: config.shutdown_timeout)
      deadline = monotonic + timeout
      thread = @mutex.synchronize do
        return if @closed

        reset_after_fork! if @pid != Process.pid
        @closed = true
        @stopping = true
        @wakeup.broadcast
        @thread
      end
      # Still sending (a slow Watch): don't use the same connection from a second thread.
      return if thread&.join([deadline - monotonic, 0].max).nil? && thread&.alive?

      flush(timeout: [deadline - monotonic, 0.1].max, retries: 0)
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
      @mutex.synchronize do
        count = batch_size
        if @batch_bytes
          total = 0
          count = @sizes.first(batch_size).take_while { |bytes| (total += bytes) <= @batch_bytes }.size.clamp(1, batch_size)
        end
        @buffer_bytes -= @sizes.shift(count).sum
        @buffer.shift(count)
      end
    end

    def requeue(batch)
      sizes = batch.map { |entry| self.class.prepare(entry)[1] }
      @mutex.synchronize do
        @buffer.unshift(*batch)
        @sizes.unshift(*sizes)
        @buffer_bytes += sizes.sum
      end
    end

    # Called with the mutex held.
    def drop_oldest
      @buffer.shift
      @buffer_bytes -= @sizes.shift.to_i
      @stats[:dropped_queue_full] += 1
    end

    def max_queue_bytes
      config.max_queue_bytes.to_i.positive? ? config.max_queue_bytes.to_i : Configuration::DEFAULT_MAX_QUEUE_BYTES
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
          # Interruptible: shutdown (at exit) wakes it instead of waiting out the backoff.
          @mutex.synchronize { @wakeup.wait(@mutex, backoff(attempt)) unless @stopping }
          if stopping?
            # Shutting down: hand the batch back, shutdown's own flush sends it.
            requeue(batch)
            return false
          end
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
      @sizes.clear
      @buffer_bytes = 0
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
