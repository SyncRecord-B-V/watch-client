# Background Jobs

The gem follows ActiveJob jobs (any adapter: Solid Queue, Sidekiq, others) and native Sidekiq jobs. While a job runs,
its log lines carry the job ID, class and queue, and the request ID of the request that enqueued it. Each run is
timed, with the time spent in SQL and in outgoing HTTP calls. When a job fails, the error shows which job it was. The
job's arguments are only sent when you opt in.

## Log context

Inside a job, every log line carries `request_id` (from the enqueuing request), `job_id`, `job_class` and `queue`.

## Job details on errors

An error raised in a job (or reported with `Rails.error.report` inside it) includes the job:

| Field | ActiveJob | Native Sidekiq |
| --- | --- | --- |
| class | the job class | the worker class (or the wrapped ActiveJob class) |
| id | `job_id` | `jid` |
| queue | `queue_name` | `queue` |
| attempt | `executions` | `retry_count + 1` (when retried) |
| arguments | only on opt-in (see below) | only with `send_job_arguments` |

Details are captured only for failed runs and only while Watch is on. When a job runs inside another job
(`perform_now`), the error is shown in the job that was running when it happened.

## Job arguments (opt-in)

Arguments are off by default. A positional value (a reset token, a password) cannot be recognised by name, so the
filter list cannot protect it. Opt in per job or for all jobs.

**Per ActiveJob class** (recommended): a class method picks what to send.

```ruby
class SyncAccountJob < ApplicationJob
  # args is the job's argument list; return what may be sent
  def self.watch_arguments(args) = [args.first] # the account record only

  def perform(account, api_token)
    # ...
  end
end
```

`watch_arguments` takes precedence over `send_job_arguments` for that class.

**For every job:**

```ruby
config.send_job_arguments = true
```

```bash
WATCH_SEND_JOB_ARGUMENTS=true
```

Native Sidekiq jobs (not ActiveJob) do not use `watch_arguments`; they send arguments only with
`send_job_arguments`.

### How arguments are made safe

- Records (anything with a GlobalID) become `Invoice#42`.
- Hashes go through the filter list (see [Privacy and Filtering](Privacy-and-Filtering)).
- A string that is an email address becomes `[FILTERED]`.
- Strings are cut at 300 characters (before they are copied).
- The copy stops after 200 values or about 4 KB of text; the rest becomes `[TRUNCATED]`.
- Nesting deeper than 6 levels becomes `[TOO DEEP]`; a structure that contains itself becomes `[CIRCULAR]`.
- A hash key over 100 bytes is never cut (the filter could miss part of it): it is left out with its value and
  replaced by `"[LONG KEY]" => "[FILTERED]"`.
- If the result is still over 8 KB, it is replaced by `[TOO LARGE: n bytes]`.
- Other objects become `#<ClassName>`.

## Job timing

Each run is recorded per job class in the per-minute performance report:

- runs, failures, total and slowest time, response-time histogram;
- time waited in the queue (from enqueue, or the scheduled time when later);
- time in SQL and the number of queries (Active Record; schema queries and query-cache hits are not counted);
- time in outgoing HTTP calls (`Net::HTTP`);
- outgoing calls per job class and host: count, failures, 429 answers, total time. This shows which job uses an API's
  quota.

A job run inline inside another job or a request is timed on its own, and its SQL and HTTP time is added to the
outer run. ActiveJob jobs on Sidekiq are timed once (by the ActiveJob hook). Timing needs `performance_monitoring`.

## Queues

Once a minute, queue sizes and the oldest job's wait are read from the job backend, with failed, scheduled and
running counts (Solid Queue) or retries, dead, scheduled and running counts (Sidekiq). At most 50 queues. Turn off with
`job_queue_monitoring = false`. See [Performance Metrics](Performance-Metrics).

## Sidekiq

When Sidekiq is loaded, the gem adds client middleware (stores the request ID in the job), server middleware (job
context, timing, job details) and an error handler (if `send_errors` is on). Outside Rails, this happens in
`WatchClient.start!`.
