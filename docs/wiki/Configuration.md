# Configuration

All settings live on `WatchClient.configuration` and are set in `WatchClient.configure`. Most apps only set
`WATCH_URL` and `WATCH_API_KEY`. The defaults below come from `lib/watch_client/configuration.rb` and, in Rails, from
the Railtie. An environment variable that is set but empty counts as not set. Options without an environment variable
can only be set in code.

```ruby
# config/initializers/watch_client.rb (Rails) or at boot (other apps)
WatchClient.configure do |config|
  config.url      = ENV["WATCH_URL"]
  config.api_key  = ENV["WATCH_API_KEY"]
  config.app_name = ENV.fetch("WATCH_APP_NAME", "billing-api")
  config.min_level = :info
  config.current_user_id = -> { Current.user&.id }
end
```

## Connection and identity

| Option | ENV | Default | What it does |
| --- | --- | --- | --- |
| `url` | `WATCH_URL` | none | Watch's address, e.g. `https://watch.syncrecord.com`. Required |
| `api_key` | `WATCH_API_KEY` | none | The app's API key (`lh_...`). Required. Sent as a Bearer token |
| `allow_http` | `WATCH_ALLOW_HTTP` (`true`) | `false` | Accept `http://` for any host. See [HTTPS only](#https-only) |
| `enabled` | none | `nil`: on when `url` and `api_key` are set and the URL is allowed; always off in `test` | Set `true` or `false` to force it |
| `app_name` | `WATCH_APP_NAME` | Rails: the app's module name in dashes (`billing-api`); otherwise `nil` | Shown by `watch:test` and `watch:config`. The API key decides the app in Watch |
| `environment` | `WATCH_ENVIRONMENT` | Rails: `Rails.env`; otherwise `RAILS_ENV`, `RACK_ENV`, else `development` | The environment shown and filtered on in Watch |
| `host` | none (reads `DYNO`, `HOSTNAME`) | `DYNO`, else `HOSTNAME`, else the machine's hostname | Server or container name |
| `app_version` | `WATCH_APP_VERSION` | `WATCH_APP_VERSION`, else `HEROKU_SLUG_COMMIT`, else `GIT_SHA`, else `SOURCE_VERSION` (first 12 characters) | Version on log lines, errors, metrics and deploys |
| `timeout` | none | `5` | HTTP open, read and write timeout in seconds (also for check-ins) |

## Logs

| Option | ENV | Default | What it does |
| --- | --- | --- | --- |
| `send_logs` | none | `true` | Send log lines |
| `min_level` | `WATCH_MIN_LEVEL` | `:info` | Lowest level sent: `:debug`, `:info`, `:warn`, `:error`, `:fatal`, `:unknown` |
| `log_requests` | none | `true` | One summary line per controller action (Rails) |
| `current_user_id` | none | `nil` | `-> { ... }` or `->(env) { ... }` returning the signed-in user's ID. Added to log lines and errors that carry a request ID (web requests and jobs they enqueued) |
| `filter_keys` | none | Rails: the app's `filter_parameters` plus the built-in list. Otherwise (after `start!`): the built-in list | Keys masked as `[FILTERED]`. The built-in list always applies. See [Privacy and Filtering](Privacy-and-Filtering) |
| `before_send` | none | `nil` | `->(entry) { ... }`: change a log line (a Hash), or return `nil` to drop it |
| `propagate_request_id` | none | `true` | Add `X-Request-ID` to outgoing `Net::HTTP` calls made during a request or job |
| `propagate_to` | none | `nil` (all hosts) | Only add it for these hosts: strings (exact, case-insensitive) or regexps |

## Errors

| Option | ENV | Default | What it does |
| --- | --- | --- | --- |
| `send_errors` | none | `true` | Report exceptions |
| `report_handled_errors` | none | `true` | Also report handled errors from `Rails.error.handle` and `Rails.error.report(handled: true)` |
| `ignore_errors` | none | See [Errors and Context](Errors-and-Context#ignored-errors) | Class names never reported (subclasses too) |
| `before_notify` | none | `nil` | `->(notice, exception) { ... }`: change an error report, or return `nil` to drop it |
| `breadcrumbs` | none | `true` | Record what happened before an error |
| `breadcrumbs_max` | none | `40` | Breadcrumbs kept per request or job |
| `send_session` | none | `true` | The session, filtered (only when the request loaded it) |
| `send_cookie_values` | none | `false` | Cookie values (names are always sent) |
| `send_job_arguments` | `WATCH_SEND_JOB_ARGUMENTS` (`true`) | `false` | Every failed job's arguments. See [Background Jobs](Background-Jobs) |
| `source_frames` | none | `10` | App backtrace lines that get code around them (`0` turns it off) |
| `source_lines` | none | `3` | Lines of code before and after each of those lines |
| `app_root` | none | Rails: `Rails.root`; otherwise `nil` | Backtrace paths inside it become relative |
| `backtrace_lines` | none | `100` | Maximum backtrace lines per error |

## Performance, jobs, processes, dependencies, browser, heartbeats

| Option | ENV | Default | What it does |
| --- | --- | --- | --- |
| `performance_monitoring` | `WATCH_PERFORMANCE_MONITORING` (`false` turns off) | `true` | The per-minute report: endpoints, outside hosts, quotas, jobs. Also carries queues and process health |
| `job_queue_monitoring` | `WATCH_JOB_QUEUE_MONITORING` (`false` turns off) | `true` | Queue sizes from Solid Queue or Sidekiq. Needs `performance_monitoring` |
| `process_monitoring` | `WATCH_PROCESS_MONITORING` (`false` turns off) | `true` | Memory, garbage collection, threads, Puma. Needs `performance_monitoring` |
| `report_dependencies` | `WATCH_REPORT_DEPENDENCIES` (`false` turns off) | `true` | The gem list at boot, for vulnerable gem alerts |
| `browser_key` | `WATCH_BROWSER_KEY` | none | The public browser key (`lhb_...`) for `watch_tag` |
| `browser_enabled` | none | `nil`: on when `url` and `browser_key` are set and the URL is allowed; off in `test` | Set `true` or `false` to force it |
| `browser_vitals` | none | `true` | Page speed measured by `watch.js` |
| `vitals_sample_rate` | none | `1.0` | Share of page views measured (`0.0` to `1.0`) |
| `check_ins_enabled` | none | `nil`: on, except in `test` | Heartbeat check-ins. They do not need `api_key` |

## Database (PostgreSQL)

| Option | ENV | Default | What it does |
| --- | --- | --- | --- |
| `database_monitoring` | `WATCH_DATABASE_MONITORING` (`false` turns off) | `true` | Slow queries and database samples (Rails with Active Record) |
| `slow_query_ms` | `WATCH_SLOW_QUERY_MS` | `500` | Queries at least this slow (ms) are reported |
| `before_send_query` | none | `nil` | `->(query) { ... }`: change a slow query (a Hash), or return `nil` to drop it |
| `database_interval` | none | `60` | Seconds between database samples, minimum 15. Also the interval of the performance report |

## Delivery

| Option | ENV | Default | What it does |
| --- | --- | --- | --- |
| `batch_size` | none | `500` | Log lines per request to Watch (1 to 1000). Errors use batches of 20 |
| `flush_interval` | none | `3` | Maximum seconds before a log batch is sent. Errors: 1 second |
| `max_queue` | none | `10_000` | Entries kept per buffer. The oldest are dropped beyond it |
| `max_queue_bytes` | none | `16 MB` (`16 * 1024 * 1024`) | Buffer cap by JSON size. The oldest are dropped beyond it |
| `max_retries` | none | `4` | Retries of a log or error batch on network errors and HTTP 408, 425, 429, 500, 502, 503, 504 |
| `shutdown_timeout` | none | `5` | Seconds per buffer (errors, logs, metrics) to deliver what is left at exit, and the default for `WatchClient.flush` |
| `diagnostics` | none | `$stderr` | Where the gem writes its own problems (`[watch_client] ...`). `nil` silences it |

## HTTPS only

The gem refuses to send the API key over plain HTTP to a remote host. An `http://` URL is accepted only when:

- the host is local: `localhost`, `127.x.x.x`, `::1`, `*.localhost` or `*.test`; or
- `WATCH_ALLOW_HTTP=true` (or `config.allow_http = true`). Use this only on a private network you trust: the API key
  then travels unencrypted.

Otherwise the gem prints one warning (`not sending anything: WATCH_URL must use https://`) and sends nothing. The
same rule applies to heartbeat ping URLs.

## All environment variables

| Variable | Option |
| --- | --- |
| `WATCH_URL` | `url` |
| `WATCH_API_KEY` | `api_key` |
| `WATCH_APP_NAME` | `app_name` |
| `WATCH_ENVIRONMENT` | `environment` |
| `WATCH_APP_VERSION` | `app_version` |
| `WATCH_ALLOW_HTTP` | `allow_http` (only the value `true` turns it on) |
| `WATCH_BROWSER_KEY` | `browser_key` |
| `WATCH_MIN_LEVEL` | `min_level` |
| `WATCH_SEND_JOB_ARGUMENTS` | `send_job_arguments` (only `true` turns it on) |
| `WATCH_SLOW_QUERY_MS` | `slow_query_ms` |
| `WATCH_DATABASE_MONITORING` | `database_monitoring` (only `false` turns it off) |
| `WATCH_PERFORMANCE_MONITORING` | `performance_monitoring` (only `false` turns it off) |
| `WATCH_JOB_QUEUE_MONITORING` | `job_queue_monitoring` (only `false` turns it off) |
| `WATCH_PROCESS_MONITORING` | `process_monitoring` (only `false` turns it off) |
| `WATCH_REPORT_DEPENDENCIES` | `report_dependencies` (only `false` turns it off) |

Also read: `DYNO`, `HOSTNAME` (host), `HEROKU_SLUG_COMMIT`, `GIT_SHA`, `SOURCE_VERSION` (version), `RAILS_ENV`,
`RACK_ENV` (environment outside Rails).
