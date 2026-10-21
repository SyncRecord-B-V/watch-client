# What Is Sent

This page lists everything the gem sends to Watch, when it sends it, and how to turn each part off. All of it is
on by default once `WATCH_URL` and `WATCH_API_KEY` are set, and nothing is sent in the `test` environment. Data goes
over HTTPS as gzipped JSON, from background threads. Personal data and secrets are filtered first; see
[Privacy and Filtering](Privacy-and-Filtering).

## Overview

| What | Watch endpoint | When | Turn off with |
| --- | --- | --- | --- |
| Log lines (level `min_level` and up) | `/api/v1/logs` | Batches of up to 500 lines, at least every 3 s | `send_logs = false` |
| Request summary line (Rails) | `/api/v1/logs` | With the logs | `log_requests = false` |
| Errors | `/api/v1/errors` | Batches of up to 20, at least every second | `send_errors = false` |
| Deploys | `/api/v1/deploys` | When `bin/rails watch:deploy` or `WatchClient.notify_deploy` runs (right away) | Don't run it |
| Performance report: endpoints, outside hosts, quotas, jobs, job calls per host | `/api/v1/metrics` | Once a minute per process | `performance_monitoring = false` |
| Job queues (in the performance report) | `/api/v1/metrics` | Once a minute | `job_queue_monitoring = false` |
| Process health (in the performance report) | `/api/v1/metrics` | Once a minute | `process_monitoring = false` |
| Database samples and slow queries | `/api/v1/database` | Every minute; top queries every 5th sample; tables every 60th | `database_monitoring = false` |
| Gem list (Gemfile.lock), Ruby and Rails versions | `/api/v1/dependencies` | Once, about 20 s after a server or worker process starts | `report_dependencies = false` |
| Heartbeat pings | `/ping/<token>` | When `WatchClient.check_in` runs | `check_ins_enabled = false` |
| Browser errors and page speed | from the browser (`watch.js`) | When they happen / once per page view | no browser key, or `browser_vitals = false` (page speed only) |

"Once a minute" is `database_interval` (default 60 seconds, minimum 15).

## Log lines

Each line has: `timestamp`, `level`, `message`, `environment`, `host`, `app_version`, and, when known, `request_id`,
`user_id`, `job_id`, `job_class`, `queue`, your `with_context` fields and structured fields. A message is capped at
32 KB and a whole line at 64 KB (larger fields become `[TRUNCATED: n bytes]`). See [Logging](Logging).

## Request summary line

One line per controller action, for example `GET /invoices/42 200 in 45ms (InvoicesController#show)`. Its fields:
method, path (filtered), status, duration, controller, action, format, view time, DB time and exception class. A 5xx
response is logged at `error` level.

## Errors

Class, message, backtrace (up to `backtrace_lines`), up to 3 causes, environment, host, version, request ID, user ID,
component (`Controller#action` or job class), handled or not, fingerprint, and your context. Also, when available:
the request (method, filtered URL, params, remote IP, referrer, user agent, headers), session, cookie names, CGI
variables, code around your own backtrace lines, breadcrumbs, the job, and app facts (host, PID, Ruby and Rails
versions, memory, load). See [Errors and Context](Errors-and-Context).

## Performance report

Per minute and per process. See [Performance Metrics](Performance-Metrics) and
[Outside API Quotas](Outside-API-Quotas).

## Database

Slow queries without values, connection and pool numbers, health counters, top queries and table sizes. See
[Database Monitoring](Database-Monitoring).

## Gem list

Names and versions from `Gemfile.lock`, Ruby and Rails versions, environment, host, app version and a digest. Only
from server and worker processes (Rails server, Puma, Sidekiq, Solid Queue `jobs`), not from consoles, rake tasks or
tests. Run `bin/rails watch:dependencies SEND=1` to send it by hand.

## Delivery and limits

- Logs and errors each have their own buffer and background thread, capped at `max_queue` entries and
  `max_queue_bytes` (16 MB). When full, the oldest entries are dropped and counted.
- A failed batch is retried up to `max_retries` times (backoff 1, 2, 4, 8 s, up to 30 s) on network errors and HTTP
  408, 425, 429, 500, 502, 503, 504. Other answers (400, 401, 413, 422) drop the batch. Metrics and database samples
  are retried once.
- `WatchClient.stats` shows the counters: `queued`, `sent`, `batches_sent`, `retries`, `dropped_queue_full`,
  `dropped_delivery`, `dropped_unencodable`, `dropped_too_large`, `buffered`, `buffered_bytes`, and the same for errors
  under `:errors`.

## Flush and shutdown

- `WatchClient.flush(timeout: ...)` sends what is buffered now, from the calling thread: errors, logs and the
  current metrics. The default timeout is `shutdown_timeout` (5 s), applied to each buffer.
- `WatchClient.shutdown(timeout: ...)` sends what is left and stops the background threads. In Rails and after
  `WatchClient.start!` it runs automatically at exit.
- Only one metrics delivery runs at a time. A flush that times out against a slow Watch is picked up by the next
  flush, and `shutdown` stops it.
