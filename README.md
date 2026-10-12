# syncrecord_watch

The Ruby gem that connects a Rails app to **Sync Record Watch** (`https://watch.syncrecord.com`), Sync Record's
monitoring platform: one place for what Papertrail, Honeybadger, AppSignal-style performance monitoring and
bundler-audit each do. Install it once, set two environment variables, and the
app starts sending everything Sync Record Watch shows:

| You get in Sync Record Watch | Where in Sync Record Watch | Needs |
| --- | --- | --- |
| Every log line, searchable and live | **Log Tail** | the gem |
| Rails and JavaScript errors, grouped, with alerts | **Errors** | the gem (+ the browser tag for JavaScript) |
| Response times per endpoint, deploys before / after | **Performance → Endpoints** | the gem |
| Calls to outside services (Stripe, Exact Online…) | **Performance → Outside APIs** | the gem |
| Background jobs and queue sizes | **Performance → Jobs** | the gem |
| Memory, garbage collection, Puma threads | **Performance → Processes** | the gem |
| Page speed of real visits (Core Web Vitals) | **Performance → Page speed** | the browser tag (Team / Business plan) |
| Slow queries, database health, table sizes | **Database** | the gem + PostgreSQL |
| Gems with known vulnerabilities | **Security** | the gem |
| Cron jobs and workers that stop running | **Uptime → Heartbeats** | one line per job |
| Deploys on charts and errors | everywhere | `bin/rails watch:deploy` |

Your app keeps logging exactly as before (stdout, files…). The gem only adds Sync Record Watch as one more destination, sends
in the background, and never slows down or breaks the app: buffers are capped, failed sends are retried and then
dropped, and the gem's own errors are swallowed.

Requirements: Ruby 3.2 or newer, Rails 7.1 or newer. No other runtime dependencies.

---

## Quick start

About ten minutes per app. You need to be an **owner or admin** of the account in Sync Record Watch.

### 1. Create the app in Sync Record Watch

1. Sign in to Sync Record Watch and open **Apps → New app**.
2. Give it a name (e.g. `Billing API`) and save.
3. **Copy the API key** (`lh_...`). It is shown only once; if you lose it, use **Create new API key** on the app's
   **Edit** page (the old key stops working at once).
4. Optional, for JavaScript errors and page speed: on the app's **Edit** page, in **Track browser (JavaScript)
   errors**, copy the **browser key** (`lhb_...`) and list the websites allowed to use it (e.g. `https://billing.example.com`).

While on the **Edit** page, set where alerts go: a Slack webhook and/or alert emails. All alerts of this app (errors,
uptime, performance, database, security) use these channels.

### 2. Add the gem

```ruby
# Gemfile
gem "syncrecord_watch", git: "git@github.com:<your-org>/syncrecord_watch.git", tag: "v0.9.0"
```

```bash
bundle install
bin/rails generate syncrecord_watch:install   # creates config/initializers/syncrecord_watch.rb
```

The generated initializer works as it is; everything in it is optional (see [Configuration](#configuration)).

### 3. Set the environment variables

Set them wherever the app runs (production, staging). Leave them out locally and in tests: without them the gem
sends nothing, and it never sends in the `test` environment.

| Variable | Required | Example | What it is |
| --- | --- | --- | --- |
| `SYNCRECORD_WATCH_URL` | yes | `https://watch.syncrecord.com` | Sync Record Watch's address |
| `SYNCRECORD_WATCH_API_KEY` | yes | `lh_3f9a…` | The app's API key from step 1. Keep it secret |
| `SYNCRECORD_WATCH_APP_NAME` | no | `billing-api` | Only used by `bin/rails watch:test` (the key decides the app) |
| `SYNCRECORD_WATCH_BROWSER_KEY` | no | `lhb_81c2…` | Browser key from step 1, for JavaScript errors and page speed. Public by design |
| `SYNCRECORD_WATCH_ENVIRONMENT` | no | `staging` | Overrides `Rails.env` as the environment shown in Sync Record Watch |
| `SYNCRECORD_WATCH_APP_VERSION` | no | `a1b2c3d` | The deployed version; otherwise read from `GIT_SHA`, `HEROKU_SLUG_COMMIT` or `SOURCE_VERSION` |

Where to set them:

- **Heroku:** `heroku config:set SYNCRECORD_WATCH_URL=... SYNCRECORD_WATCH_API_KEY=...`
- **DigitalOcean App Platform:** the app's **Settings → App-Level Environment Variables**; mark the API key as encrypted.
- **Kamal:** `env.secret` in `config/deploy.yml`, with the values in `.kamal/secrets`.
- **Your own server:** the service's environment (systemd `Environment=`, `.env` loaded by your process manager…).

### 4. Deploy and check

After deploying, from a console or one-off command on the server:

```bash
bin/rails watch:config       # what the gem will use (the key is hidden)
bin/rails watch:test         # sends one log line and prints OK or the problem
bin/rails watch:test_error   # sends a test error (SyncRecordWatch::TestError)
```

Then in Sync Record Watch: **Apps** shows the app as *sending*, **Log Tail** shows the test line, **Errors** shows the test
error (resolve it), and within a few minutes **Performance**, **Database** and **Security** fill up.

### 5. Record deploys

Run `bin/rails watch:deploy` after every deploy. Sync Record Watch then shows which deploy an error started in, and compares
response times before and after each deploy.

| Platform | How |
| --- | --- |
| Heroku | `Procfile`: `release: bin/rails db:migrate && bin/rails watch:deploy` |
| DigitalOcean App Platform | A job component of kind **Post-deploy** with run command `bin/rails watch:deploy` |
| Kamal | `.kamal/hooks/post-deploy`: `kamal app exec --reuse "bin/rails watch:deploy VERSION=$KAMAL_VERSION"` |
| Capistrano | `after "deploy:finished", "watch:deploy"` (a task that runs `bin/rails watch:deploy` on one app server) |

The version comes from `VERSION=...`, else `SYNCRECORD_WATCH_APP_VERSION` / `GIT_SHA` / `HEROKU_SLUG_COMMIT` / `SOURCE_VERSION`,
else `git rev-parse`. Optional: `REVISION=...`, `DEPLOYED_BY=...`.

### 6. JavaScript errors and page speed (optional)

With `SYNCRECORD_WATCH_BROWSER_KEY` set, add one line to the `<head>` of your layout(s):

```erb
<%= syncrecord_watch_tag %>
<%# or, so errors show which user saw them (an id, not personal data): %>
<%= syncrecord_watch_tag(user_id: current_user&.id) %>
```

This loads `watch.js` from Sync Record Watch (about 5 KB gzipped, no dependencies). It reports uncaught JavaScript errors and unhandled
promise rejections, with the last clicks, page changes, console errors and failed requests; and it measures each full
page load (Core Web Vitals, Team and Business plans). Nothing is rendered when the browser key is missing or in tests.

If the app has a **Content Security Policy**, allow Sync Record Watch (the tag gets the CSP nonce automatically):

```ruby
# config/initializers/content_security_policy.rb
policy.script_src  :self, "https://watch.syncrecord.com"
policy.connect_src :self, "https://watch.syncrecord.com"
```

Try it in the browser console: `SyncRecordWatch.notify(new Error("Test from the console"))`.

### 7. Heartbeats for cron jobs and workers (optional)

For every scheduled job that must keep running, create a heartbeat in Sync Record Watch (**Uptime → Heartbeats → New
heartbeat**, with how often it runs) and copy its token. Then:

```ruby
# pings when the block finishes, and reports a failure (then re-raises) when it raises
SyncRecordWatch.check_in(ENV["SYNCRECORD_WATCH_HEARTBEAT_INVOICE_EXPORT"]) do
  InvoiceExport.run
end
```

Or from a crontab, without the gem:

```bash
0 2 * * * cd /app && bin/rails invoices:export && curl -fsS -m 10 --retry 3 https://watch.syncrecord.com/ping/<token>
```

Sync Record Watch alerts when a ping doesn't arrive in time (period + grace time), or when a job calls `/ping/<token>/fail`.

### Checklist

- [ ] App created in Sync Record Watch, API key copied, Slack / email alerts set on the app
- [ ] Gem added, initializer generated
- [ ] `SYNCRECORD_WATCH_URL` and `SYNCRECORD_WATCH_API_KEY` set in every deployed environment
- [ ] `bin/rails watch:test` prints OK on the server
- [ ] `bin/rails watch:deploy` runs after each deploy
- [ ] Optional: `syncrecord_watch_tag` in the layout and `SYNCRECORD_WATCH_BROWSER_KEY` set (CSP updated)
- [ ] Optional: heartbeats for cron jobs
- [ ] Optional: `config.current_user_id` so log lines show the signed-in user

---

## What is sent, and when

All of this is on by default once `SYNCRECORD_WATCH_URL` and `SYNCRECORD_WATCH_API_KEY` are set. Each line can be turned off on its own.

| What | When | Turn off with |
| --- | --- | --- |
| Log lines (`Rails.logger`, level `info` and up) | Batches every 3 s or 500 lines | `config.send_logs = false` |
| One summary line per request (method, path, status, duration, controller#action, DB / view time) | With the logs | `config.log_requests = false` |
| Errors: unhandled exceptions in requests, ActiveJob and Sidekiq; `Rails.error.report` / `handle`; `SyncRecordWatch.notify` | Right away (small batches, every second) | `config.send_errors = false` |
| Performance: per controller action, per outside host, per job class: counts, failures, response-time histograms | Totals once a minute | `config.performance_monitoring = false` |
| Job queues: sizes, oldest job's wait, failed / retrying / dead (Solid Queue or Sidekiq) | Once a minute | `config.job_queue_monitoring = false` |
| Process health: memory, garbage collection, threads, Puma busy threads and backlog | Once a minute | `config.process_monitoring = false` |
| Database (PostgreSQL): slow queries, health, top queries, table sizes | Every minute / 5 minutes / hour | `config.database_monitoring = false` |
| Gem names and versions (Gemfile.lock), Ruby and Rails versions | Once when a server or worker starts | `config.report_dependencies = false` |
| Browser: JavaScript errors and page speed (with the browser tag) | When they happen / once per page view | `config.browser_vitals = false` (page speed only) |

Every log line and error carries the environment, host, app version, request ID and (if configured) user ID. The
request ID follows a request into its jobs and into other Rails apps it calls (`X-Request-ID`), so one user action
can be traced across apps in Log Tail.

## What never leaves your app

- **Secrets:** keys in the app's `filter_parameters` (passwords, tokens…) are replaced with `[FILTERED]` in log
  payloads, error params, session and headers. The CSRF token is always hidden; cookie *values* are not sent.
- **SQL values:** slow queries and query texts are normalised first: `WHERE email = 'a@b.c'` becomes `WHERE email = ?`.
- **Single requests:** performance numbers are per-minute totals, never individual requests or their parameters.
- **Page addresses:** page speed reports the path only, with ids replaced (`/invoices/:id`), never query strings.
- **Code and configuration:** only the gem list and versions, never source files (except a few lines of code around
  your own backtrace lines in error reports; `config.source_frames = 0` turns that off).
- **Database access:** Sync Record Watch never connects to your database; the gem reads statistics over the app's own
  connection, read-only, with a 2-second timeout, and only when the connection pool is not busy.

Use `config.before_send` (log lines), `config.before_notify` (errors) and `config.before_send_query` (slow
queries) to change or drop anything else before it is sent.

---

## Using it in your code

Normal logging just works:

```ruby
Rails.logger.info("Invoice sent")
```

**Structured lines.** Fields become searchable in Log Tail (`payload.invoice_id=42`, `payload.total>100`):

```ruby
Rails.logger.info(event: "invoice.sent", invoice_id: invoice.id, total: invoice.total, message: "Invoice sent")
SyncRecordWatch.log(:warn, "Slow sync", seconds: 12.4, account_id: account.id)
```

**Extra fields on every line inside a block** (e.g. the tenant in a multi-tenant job):

```ruby
SyncRecordWatch.with_context(tenant: account.slug) do
  ImportJob.perform_now(file)
end
```

**Who did it.** Attach the signed-in user's ID to request log lines (in the initializer):

```ruby
config.current_user_id = -> { Current.user&.id }
# with Devise:
config.current_user_id = ->(env) { env["warden"]&.user(scope: :user, run_callbacks: false)&.id }
```

**Handled errors.** Unhandled ones are reported automatically; report the ones you rescue yourself:

```ruby
begin
  charge.capture!
rescue Stripe::APIError => e
  SyncRecordWatch.notify(e, context: { order_id: order.id })
  # group all of these into one error, whatever the message:
  # SyncRecordWatch.notify(e, fingerprint: "stripe-capture")
end

# Rails' own error API works too:
Rails.error.handle(context: { order_id: order.id }) { charge.capture! }
```

**Errors you never want to see** (404s, bad requests, CSRF and `RecordNotFound` are already ignored):

```ruby
config.ignore_errors += ["Twilio::REST::RestError"]
```

**Heartbeats:** see [step 7](#7-heartbeats-for-cron-jobs-and-workers-optional).

**In the browser** (with the browser tag): `SyncRecordWatch.notify(error)` for caught errors, `SyncRecordWatch.setUser({ id: 42 })`,
`SyncRecordWatch.setContext({ plan: "pro" })`, `SyncRecordWatch.addBreadcrumb("Opened checkout")`.

**From a console:** `SyncRecordWatch.stats` (what was queued, sent, retried or dropped) and `SyncRecordWatch.flush`.

---

## Configuration

Everything goes in `config/initializers/syncrecord_watch.rb`. Defaults are chosen so most apps only set the two
environment variables.

```ruby
SyncRecordWatch.configure do |config|
  config.url      = ENV["SYNCRECORD_WATCH_URL"]
  config.api_key  = ENV["SYNCRECORD_WATCH_API_KEY"]
  config.app_name = ENV.fetch("SYNCRECORD_WATCH_APP_NAME", "billing-api")
  config.min_level = :info
  config.current_user_id = -> { Current.user&.id }
end
```

**Connection and identity**

| Option | Default | What it does |
| --- | --- | --- |
| `url`, `api_key` | `SYNCRECORD_WATCH_URL`, `SYNCRECORD_WATCH_API_KEY` | Where to send, and as which app |
| `enabled` | on when url and key are set, off in `test` | Force sending on or off |
| `app_name` | `SYNCRECORD_WATCH_APP_NAME` or the app's module name | Shown by `loghub:test` |
| `environment` | `SYNCRECORD_WATCH_ENVIRONMENT`, else `Rails.env` | Environment filter in Sync Record Watch |
| `host` | `DYNO`, `HOSTNAME` or the hostname | Server / container name |
| `app_version` | `SYNCRECORD_WATCH_APP_VERSION`, `HEROKU_SLUG_COMMIT`, `GIT_SHA`, `SOURCE_VERSION` | Version on errors and deploys (first 12 characters) |

**Logs**

| Option | Default | What it does |
| --- | --- | --- |
| `send_logs` | `true` | Send Rails log lines |
| `min_level` | `:info` (or `SYNCRECORD_WATCH_MIN_LEVEL`) | Lowest level sent: `:debug`, `:info`, `:warn`, `:error`, `:fatal` |
| `log_requests` | `true` | The summary line per request |
| `current_user_id` | `nil` | Lambda returning the signed-in user's ID |
| `filter_keys` | the app's `filter_parameters` | Keys masked as `[FILTERED]` |
| `before_send` | `nil` | `->(entry) { ... }` change a line, or return `nil` to drop it |
| `propagate_request_id`, `propagate_to` | `true`, all hosts | Add `X-Request-ID` to outgoing calls (optionally only to these hosts, e.g. `[/\.example\.com\z/]`) |

**Errors**

| Option | Default | What it does |
| --- | --- | --- |
| `send_errors` | `true` | Report exceptions |
| `report_handled_errors` | `true` | Also report `Rails.error.handle` / handled `Rails.error.report` |
| `ignore_errors` | 404s, bad requests, CSRF, `RecordNotFound`… | Exception classes never reported (subclasses too) |
| `before_notify` | `nil` | `->(notice, exception) { ... }` change an error report, or return `nil` to drop it |
| `breadcrumbs`, `breadcrumbs_max` | `true`, `40` | What happened before an error (SQL without values, renders, jobs, mails, HTTP calls, warnings) |
| `send_session`, `send_cookie_values` | `true`, `false` | The session (filtered); cookie values (names are always sent) |
| `source_frames`, `source_lines` | `10`, `3` | Code around your backtrace lines (0 frames = off) |
| `app_root`, `backtrace_lines` | `Rails.root`, `100` | Backtrace paths made relative; maximum lines |

**Performance, jobs, processes and security**

| Option | Default | What it does |
| --- | --- | --- |
| `performance_monitoring` | on (`SYNCRECORD_WATCH_PERFORMANCE_MONITORING=false` turns it off) | Endpoints, outside APIs and job runs |
| `job_queue_monitoring` | on (`SYNCRECORD_WATCH_JOB_QUEUE_MONITORING=false`) | Queue sizes from Solid Queue or Sidekiq |
| `process_monitoring` | on (`SYNCRECORD_WATCH_PROCESS_MONITORING=false`) | Memory, garbage collection, threads, Puma |
| `report_dependencies` | on (`SYNCRECORD_WATCH_REPORT_DEPENDENCIES=false`) | Gem list at boot, for vulnerable gem alerts |
| `browser_vitals`, `vitals_sample_rate` | `true`, `1.0` | Page speed from watch.js; share of page views measured (e.g. `0.25`) |
| `browser_key`, `browser_enabled` | `SYNCRECORD_WATCH_BROWSER_KEY`, on when the key is set | The browser tag |
| `check_ins_enabled` | on, off in `test` | Heartbeat check-ins |

**Database (PostgreSQL)**

| Option | Default | What it does |
| --- | --- | --- |
| `database_monitoring` | on (`SYNCRECORD_WATCH_DATABASE_MONITORING=false`) | Slow queries, health, top queries, tables |
| `slow_query_ms` | `500` (or `SYNCRECORD_WATCH_SLOW_QUERY_MS`) | Queries at least this slow are reported |
| `before_send_query` | `nil` | `->(query) { ... }` change a slow query, or return `nil` to drop it |
| `database_interval` | `60` | Seconds between samples (also used for the performance report; minimum 15) |

For **Top queries**, enable PostgreSQL's `pg_stat_statements` extension (DigitalOcean and Heroku support it; in a
migration: `enable_extension "pg_stat_statements"`). Slow queries work with any database; the rest needs PostgreSQL.

**Delivery** (rarely changed)

| Option | Default | What it does |
| --- | --- | --- |
| `batch_size`, `flush_interval` | `500`, `3` | Lines per request (max 1000); max seconds before a batch is sent |
| `max_queue` | `10_000` | Buffer cap; the oldest lines are dropped beyond it |
| `max_retries`, `timeout` | `4`, `5` | Retries for network errors and 408/425/429/5xx; HTTP timeout in seconds |
| `shutdown_timeout` | `5` | Seconds to deliver what's left when the process exits |
| `diagnostics` | `$stderr` | Where the gem reports its own problems (rate-limited); `nil` to silence |

## Rake tasks

| Command | What it does |
| --- | --- |
| `bin/rails watch:config` | Show the settings the gem uses (key hidden) |
| `bin/rails watch:test` | Send one test log line; prints OK or the problem |
| `bin/rails watch:test_error` | Send a test error |
| `bin/rails watch:deploy [VERSION=…] [REVISION=…] [DEPLOYED_BY=…]` | Record a deploy |
| `bin/rails watch:check_in TOKEN=… [FAIL=1] [MSG=…]` | Heartbeat check-in from a shell |
| `bin/rails watch:database [SEND=1]` | Print one database sample (and send it) |
| `bin/rails watch:dependencies [SEND=1]` | Print the gem list summary (and send it) |

## Troubleshooting

| Problem | Check |
| --- | --- |
| Nothing arrives at all | `bin/rails watch:config`: `enabled` must be true and url / key set. `bin/rails watch:test` prints the exact problem (wrong URL, 401, network) |
| `401` from Sync Record Watch | The API key is wrong or was rotated, or the app is paused (plan limit) or set inactive in Sync Record Watch |
| Some log lines are missing | `SyncRecordWatch.stats` in a console shows dropped batches; the account may be over its monthly volume (**Plan & usage** in Sync Record Watch); `min_level` may be above the line's level |
| Errors don't show up | The class may be in `ignore_errors`; errors in the `test` environment are never sent; `before_notify` may return nil |
| JavaScript errors / page speed missing | `SYNCRECORD_WATCH_BROWSER_KEY` set? The page's website listed under the app's allowed websites? CSP allows Sync Record Watch in `script-src` and `connect-src`? Page speed needs the Team or Business plan |
| Performance, Jobs or Processes empty | Needs gem 0.7 / 0.8 or newer and a restart; numbers arrive once a minute after the first request or job |
| Database page empty | PostgreSQL only; `database_monitoring` on; Top queries needs `pg_stat_statements` |
| Security page empty | The gem list is sent when a server or worker starts (not from consoles or rake tasks): restart, or `bin/rails watch:dependencies SEND=1` |
| Too many alerts | Tune or mute them per app in Sync Record Watch (Errors: ignore; Database: alert settings; Performance: alert switch) |

## FAQ

**Does it slow my app down?** The work in the request is adding a line to an in-memory buffer or a number to a
per-minute total. Sending happens on background threads, in batches, gzipped. If Sync Record Watch is slow or down, the app
doesn't wait: buffers are capped and old entries are dropped.

**What about Puma workers, Sidekiq and Solid Queue processes?** Each process gets its own background threads after it
starts (also after a fork). Nothing to configure.

**Staging and production in one Sync Record Watch app?** Yes: the environment is sent with everything and is a filter in Log
Hub. Or create one Sync Record Watch app per environment, each with its own key.

**Can I use it outside Rails?** The logger, `SyncRecordWatch.notify`, `SyncRecordWatch.log` and `SyncRecordWatch.check_in`
work in any Ruby process after `SyncRecordWatch.configure`; the automatic parts (requests, jobs, database) need Rails.

**How do I turn it off temporarily?** Remove `SYNCRECORD_WATCH_API_KEY`, or set `config.enabled = false`.

## Upgrading

Update the tag in the Gemfile and run `bundle update syncrecord_watch`; new features are on by default. See
[CHANGELOG.md](CHANGELOG.md). In short: 0.4 browser errors · 0.5 heartbeats · 0.6 database monitoring ·
0.7 performance, outside APIs, page speed and vulnerable gems · 0.8 background jobs and process health ·
0.9 renamed to `syncrecord_watch`.

### Coming from `loghub_client` (Log Hub)

Log Hub is now **Sync Record Watch** and the gem is `syncrecord_watch`. Nothing breaks if you only change the Gemfile:
the old names keep working. To move over fully:

| Old | New |
| --- | --- |
| `gem "loghub_client"` | `gem "syncrecord_watch"` (then `bundle install`) |
| `LoghubClient.configure`, `LoghubClient.notify` … | `SyncRecordWatch.configure`, `SyncRecordWatch.notify` … (`LoghubClient` still points to it) |
| `config/initializers/loghub_client.rb` | rename to `config/initializers/syncrecord_watch.rb` (optional) |
| `LOGHUB_URL`, `LOGHUB_API_KEY`, `LOGHUB_BROWSER_KEY`, other `LOGHUB_*` | `SYNCRECORD_WATCH_URL`, `SYNCRECORD_WATCH_API_KEY`, `SYNCRECORD_WATCH_BROWSER_KEY`… (the old names are still read when the new ones are not set) |
| `<%= loghub_browser_tag %>` | `<%= syncrecord_watch_tag %>` (the old helper still works) |
| `bin/rails loghub:test`, `loghub:deploy` … | `bin/rails watch:test`, `watch:deploy` … (the old task names still work) |
| `loghub.js`, `LogHub.notify(...)` in the browser | `watch.js`, `SyncRecordWatch.notify(...)` (`LogHub` still works) |
| `https://loghub.example.com` | `https://watch.syncrecord.com` |

## How it hooks into Rails

- `Rails.logger.broadcast_to(SyncRecordWatch.logger)`: one extra logger; your existing output is untouched.
- `SyncRecordWatch::RackMiddleware` right after `ActionDispatch::RequestId`: request ID in the context, outgoing-call timing.
- `process_action.action_controller` subscriber: the request summary line and endpoint numbers.
- `sql.active_record` subscriber: slow queries (database monitoring).
- ActiveJob: `serialize` stores the request ID; `around_perform` sets the job context and times the job.
- Sidekiq (when present): client and server middleware for native Sidekiq jobs, and an error handler.
- `Net::HTTP` prepend: `X-Request-ID` on outgoing calls, timing per host, HTTP breadcrumbs.
- Errors: `Rails.error.subscribe` (jobs, executor, `Rails.error.report/handle`) and an
  `ActionDispatch::DebugExceptions` interceptor (unhandled request errors, even when Rails renders the 500 page).
  Each exception object is reported once.
- Background threads per process: log delivery, error delivery, the per-minute metrics report, the database sampler.
- `at_exit`: delivers what is still buffered (up to `shutdown_timeout`).

## Development

```bash
bundle install
bundle exec rake test   # unit tests + a small Rails app test (railtie_test.rb)
```

The unit tests start a fake Sync Record Watch on `127.0.0.1` and need no network.
