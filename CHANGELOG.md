# Changelog

## 0.10.0 (unreleased)

- **Renamed to `watch_client`** (repository: github.com/SyncRecord-B-V/watch-client), a clean break with no old names
  kept. Watch is its own product (powered by SyncRecord):
  - gem `watch_client`, `require "watch_client"`, module `WatchClient`
  - environment variables `WATCH_*` (`WATCH_URL`, `WATCH_API_KEY`, `WATCH_BROWSER_KEY`, …)
  - view helper `watch_tag` (loads `watch.js`), rake tasks `watch:*`, generator `watch_client:install`,
    initializer `config/initializers/watch_client.rb`
  - removed: `syncrecord_watch` / `SyncRecordWatch`, `SYNCRECORD_WATCH_*`, `syncrecord_watch_tag`, and the older
    `loghub_client` / `LoghubClient`, `LOGHUB_*`, `loghub_browser_tag`, `loghub:*` names. See "Upgrading" in the README.

## 0.9.0

- Renamed from loghub_client to syncrecord_watch (superseded by 0.10.0).
- Privacy (security review, 8 October 2026):
  - Rails' default filter list (passwords, emails, tokens, keys, OTP, card codes, plus IBAN) is always masked, also
    when the app has no `filter_parameters` of its own.
  - Headers that repeat the visitor's IP (`X-Forwarded-For`, `X-Real-IP`, `CF-Connecting-IP`, `True-Client-IP`,
    `Forwarded`) and the CSRF token are no longer sent; the IP is sent once, as `remote_ip`.
  - SQL: tagged dollar quotes (`$body$...$body$`) are replaced too, and a query cut off in the middle of a value
    (pg_stat_activity stops at 1 KB) is cut before that value.
  - watch.js 1.2.1: click breadcrumbs only name buttons and links, never what was typed or picked in a field;
    `data-watch-mask` hides an element's text; query values that look personal (email, name, phone, address,
    postcode, IBAN, birth date) are masked in URLs.

## 0.8.0 (unreleased)

- Background jobs: every ActiveJob job (any adapter) and native Sidekiq job is timed per job class: runs,
  failures, response-time histogram and the time it waited in the queue. Queue sizes and the oldest job's wait,
  plus failed / retrying / dead / scheduled counts, are read from Solid Queue or Sidekiq once a minute.
- Process health: memory (RSS), garbage collection (runs, time), threads, uptime and, in Puma, busy threads and
  backlog, once a minute per process. New settings `job_queue_monitoring`, `process_monitoring`.

## 0.7.0 (unreleased)

- Performance monitoring, on by default: per controller action, request count, 5xx, response-time histogram
  (for p50 / p95 / p99) and the time spent in the database, views and outgoing HTTP; per outside host the app
  calls (Net::HTTP, so Faraday and most SDKs): calls, 5xx / 4xx, timeouts, connection failures and response
  times. Added up per minute in the app and sent to `POST /api/v1/metrics`. Setting `performance_monitoring`.
- Vulnerable gem alerts: the gem list from Gemfile.lock (names and versions only) plus Ruby and Rails versions,
  sent once when a server or worker starts (`POST /api/v1/dependencies`). Setting `report_dependencies`;
  `bin/rails loghub:dependencies [SEND=1]`.
- Page speed: `loghub_browser_tag` passes `browser_vitals` / `vitals_sample_rate` to loghub.js 1.1, which
  measures Core Web Vitals of real visits.

## 0.6.0 (unreleased)

- Database monitoring (PostgreSQL), on by default: slow queries (`slow_query_ms`, default 500 ms) grouped by
  SQL with values removed and the app line that ran them; a sample every minute of connections, the Rails
  connection pool, transactions, cache hit ratio, deadlocks, long-running queries, locks, size and replica lag;
  the 20 heaviest queries from `pg_stat_statements` every 5 minutes; table and index sizes every hour.
  Sent to `POST /api/v1/database`. New settings `database_monitoring`, `slow_query_ms`, `before_send_query`,
  `database_interval`. `bin/rails loghub:database` prints a sample.

## 0.5.0 (unreleased)

- Heartbeat check-ins: `LoghubClient.check_in(token)` tells Log Hub a cron job or worker ran; with a block it
  pings when the block succeeds and reports a failure (with the error) when it raises. Also
  `bin/rails loghub:check_in TOKEN=...`. New setting `check_ins_enabled` (off in the test environment).

## 0.4.0 (unreleased)

- Browser error tracking: `<%= loghub_browser_tag %>` in the layout loads loghub.js from Log Hub, which reports
  JavaScript errors and unhandled promise rejections (with clicks, page changes, console errors and failed requests
  as breadcrumbs). New setting `browser_key` (`LOGHUB_BROWSER_KEY`); `browser_enabled` to force it on or off.

## 0.3.0 (unreleased)

- Error notices now include: code around your app's backtrace lines, breadcrumbs (SQL with values removed,
  renders, jobs enqueued, mails, cache reads, outgoing HTTP calls, warnings), session (filtered), cookie names
  (values hidden by default), request headers and CGI variables (filtered), remote IP, referrer, user agent,
  application environment (host, PID, Ruby/Rails, revision, memory, load) and client library info.
- New options: `breadcrumbs`, `breadcrumbs_max`, `send_session`, `send_cookie_values`, `source_frames`, `source_lines`.

## 0.2.0 (unreleased)

- Error tracking: `LoghubClient.notify`, `Rails.error` subscriber, DebugExceptions interceptor,
  Sidekiq error handler; once per exception; request, job and user context; causes; ignore list; `before_notify`.
- Deploy tracking: `LoghubClient.notify_deploy`, `bin/rails loghub:deploy`.
- `bin/rails loghub:test_error`.

## 0.1.0 (unreleased)

- Sends Rails logs to Log Hub (`POST /api/v1/logs`, gzip JSON, API key).
- Background batching (500 lines or 3 s), capped buffer, retries with backoff, fork-safe.
- Request context: request ID (incoming `X-Request-ID` respected), optional user ID.
- One structured summary line per request; 5xx logged as errors.
- ActiveJob and Sidekiq: request ID carried into jobs; job ID and class on every line.
- `X-Request-ID` added to outgoing Net::HTTP / Faraday calls.
- Masks the app's `filter_parameters` in structured fields.
- `bin/rails generate loghub_client:install`, `bin/rails loghub:test`, `bin/rails loghub:config`.
