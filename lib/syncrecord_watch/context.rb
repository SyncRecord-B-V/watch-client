module SyncRecordWatch
  # Per-request / per-job context (request_id, job_id, custom fields), stored
  # fiber-locally so concurrent requests never mix their fields.
  module Context
    KEY = :syncrecord_watch_context

    module_function

    def current
      Thread.current[KEY] || {}
    end

    def request_id
      current[:request_id]
    end

    # Merges fields into the context for the duration of the block.
    def with(fields)
      previous = Thread.current[KEY]
      merged = (previous || {}).merge(compact(fields))
      Thread.current[KEY] = merged
      yield
    ensure
      Thread.current[KEY] = previous
    end

    def clear!
      Thread.current[KEY] = nil
    end

    def compact(fields)
      fields.each_with_object({}) do |(key, value), out|
        out[key.to_sym] = value unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
