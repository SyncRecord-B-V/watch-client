module SyncRecordWatch
  # Queue sizes and how long the oldest job has waited, plus failed / retrying / dead
  # / scheduled counts, read from the job backend: Solid Queue (its tables) or Sidekiq
  # (its Redis API). Global numbers: every process sends them, Sync Record Watch keeps one per minute.
  module JobQueues
    MAX_QUEUES = 50

    module_function

    def sample
      if defined?(::SolidQueue::ReadyExecution) && defined?(::ActiveRecord::Base)
        solid_queue
      elsif defined?(::Sidekiq::Queue)
        sidekiq
      end
    rescue StandardError
      nil
    end

    def solid_queue
      Thread.current[:syncrecord_watch_internal] = true
      now = Time.now
      ready = ::SolidQueue::ReadyExecution.group(:queue_name).pluck(:queue_name, Arel.sql("count(*)"), Arel.sql("min(created_at)"))
      queues = ready.first(MAX_QUEUES).map do |name, size, oldest|
        { "name" => name.to_s, "size" => size.to_i, "latency_s" => oldest ? [ (now - oldest).round(1), 0 ].max : 0 }
      end
      {
        "adapter" => "solid_queue", "queues" => queues,
        "failed" => ::SolidQueue::FailedExecution.count,
        "scheduled" => (defined?(::SolidQueue::ScheduledExecution) ? ::SolidQueue::ScheduledExecution.count : nil),
        "running" => (defined?(::SolidQueue::ClaimedExecution) ? ::SolidQueue::ClaimedExecution.count : nil)
      }.compact
    ensure
      Thread.current[:syncrecord_watch_internal] = nil
    end

    def sidekiq
      queues = ::Sidekiq::Queue.all.first(MAX_QUEUES).map do |queue|
        { "name" => queue.name.to_s, "size" => queue.size, "latency_s" => queue.latency.to_f.round(1) }
      end
      stats = ::Sidekiq::Stats.new
      { "adapter" => "sidekiq", "queues" => queues, "retries" => stats.retry_size, "dead" => stats.dead_size,
        "scheduled" => stats.scheduled_size, "running" => stats.workers_size }
    end
  end
end
