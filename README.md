# watch_client

The Ruby gem that connects a Rails app to **Watch** (`https://watch.syncrecord.com`), a
monitoring platform powered by SyncRecord that brings logs, error tracking, performance monitoring and
vulnerable gem checks together. Install it once, set two environment variables, and the
app starts sending everything Watch shows:

| You get in Watch | Where in Watch | Needs |
| --- | --- | --- |
| Every log line, searchable and live | **Log Tail** | the gem |
| Rails and JavaScript errors, grouped, with alerts | **Errors** | the gem (+ the browser tag for JavaScript) |
| Response times per endpoint, deploys before / after | **Performance → Endpoints** | the gem |
| Calls to outside services (Stripe, Exact Online…) | **Performance → Outside APIs** | the gem |
| API quotas left and 429s (from the APIs' rate-limit headers: Salesforce, GitHub, Shopify, HubSpot, Exact Online, `RateLimit-*`) | **Performance → Outside APIs**, dashboard when low | the gem |
| Background jobs and queue sizes | **Performance → Jobs** | the gem |
| Memory, garbage collection, Puma threads | **Performance → Processes** | the gem |
| Page speed of real visits (Core Web Vitals) | **Performance → Page speed** | the browser tag (Team / Business plan) |
| Slow queries, database health, table sizes | **Database** | the gem + PostgreSQL |
| Gems with known vulnerabilities | **Security** | the gem |
| Cron jobs and workers that stop running | **Uptime → Heartbeats** | one line per job |
| Deploys on charts and errors | everywhere | `bin/rails watch:deploy` |

Your app keeps logging exactly as before (stdout, files…). The gem only adds Watch as one more destination, sends
in the background, and never slows down or breaks the app: buffers are capped, failed sends are retried and then
dropped, and the gem's own errors are swallowed.

Requirements: Ruby 3.2 or newer. Rails 7.1 or newer for the automatic Rails setup; Rack, Sinatra, scripts and
workers work too (see [Without Rails](#without-rails-sinatra-rack-scripts-workers)). No runtime dependencies other
than Ruby's standard library and the `logger` gem.

More detail on every topic: the [wiki](https://github.com/SyncRecord-B-V/watch-client/wiki). Watch itself (the
hub) is documented in its own [wiki](https://github.com/SyncRecord-B-V/watch/wiki).

---

## Quick start

About ten minutes per app. You need to be an **owner or admin** of the account in Watch.

### 1. Create the app in Watch

1. Sign in to Watch and open **Apps → New app**.
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
gem "watch_client", git: "https://github.com/SyncRecord-B-V/watch-client.git", tag: "v0.10.0"
```

```bash
bundle install
bin/rails generate watch_client:install   # creates config/initializers/watch_client.rb
```

The generated initializer works as it is; everything in it is optional (see [Configuration](#configuration)).

### 3. Set the environment variables

Set them wherever the app runs (production, staging). Leave them out locally and in tests: without them the gem
sends nothing, and it never sends in the `test` environment.

| Variable | Required | Example | What it is |
| --- | --- | --- | --- |
| `WATCH_URL` | yes | `https://watch.syncrecord.com` | Watch's address. Must be `https://` (plain `http://` only for `localhost`, `127.x.x.x`, `::1`, `*.localhost` and `*.test`) |
| `WATCH_API_KEY` | yes | `lh_3f9a…` | The app's API key from step 1. Keep it secret |
| `WATCH_APP_NAME` | no | `billing-api` | Only shown by `watch:test`, `watch:test_error` and `watch:config` (the key decides the app) |
| `WATCH_BROWSER_KEY` | no | `lhb_81c2…` | Browser key from step 1, for JavaScript errors and page speed. Public by design |
| `WATCH_ENVIRONMENT` | no | `staging` | Overrides `Rails.env` as the environment shown in Watch |
| `WATCH_ALLOW_HTTP` | no | `true` | Accept `http://` for any host (a private network you trust only: the API key then travels unencrypted) |
| `WATCH_APP_VERSION` | no | `a1b2c3d` | The deployed version (first 12 characters); otherwise read from `HEROKU_SLUG_COMMIT`, `GIT_SHA` or `SOURCE_VERSION`, in that order |

More variables switch single features off or tune them (`WATCH_MIN_LEVEL`, `WATCH_SLOW_QUERY_MS`,
`WATCH_SEND_JOB_ARGUMENTS`, `WATCH_*_MONITORING`, `WATCH_REPORT_DEPENDENCIES`): see [Configuration](#configuration).

Where to set them:

- **Heroku:** `heroku config:set WATCH_URL=... WATCH_API_KEY=...`
- **DigitalOcean App Platform:** the app's **Settings → App-Level Environment Variables**; mark the API key as encrypted.
- **Kamal:** `env.secret` in `config/deploy.yml`, with the values in `.kamal/secrets`.
- **Your own server:** the service's environment (systemd `Environment=`, `.env` loaded by your process manager…).

### 4. Deploy and check

After deploying, from a console or one-off command on the server:

```bash
bin/rails watch:config       # what the gem will use (the key is hidden)
bin/rails watch:test         # sends one log line and prints OK or the problem
bin/rails watch:test_error   # sends a test error (WatchClient::TestError)
```

Then in Watch: **Apps** shows the app as *sending*, **Log Tail** shows the test line, **Errors** shows the test
error (resolve it), and within a few minutes **Performance**, **Database** and **Security** fill up.

### 5. Record deploys

Run `bin/rails watch:deploy` after every deploy. Watch then shows which deploy an error started in, and compares
response times before and after each deploy.

| Platform | How |
| --- | --- |
| Heroku | `Procfile`: `release: bin/rails db:migrate && bin/rails watch:deploy` |
| DigitalOcean App Platform | A job component of kind **Post-deploy** with run command `bin/rails watch:deploy` |
| Kamal | `.kamal/hooks/post-deploy`: `kamal app exec --reuse "bin/rails watch:deploy VERSION=$KAMAL_VERSION"` |
| Capistrano | `after "deploy:finished", "watch:deploy"` (a task that runs `bin/rails watch:deploy` on one app server) |

The version comes from `VERSION=...`, else `WATCH_APP_VERSION` / `HEROKU_SLUG_COMMIT` / `GIT_SHA` / `SOURCE_VERSION`,
else `git rev-parse`. Optional: `REVISION=...`, `DEPLOYED_BY=...`.

### 6. JavaScript errors and page speed (optional)

With `WATCH_BROWSER_KEY` set, add one line to the `<head>` of your layout(s):

```erb
<%= watch_tag %>
<%# or, so errors show which user saw them (an id, not personal data): %>
<%= watch_tag(user_id: current_user&.id) %>
```

This loads `watch.js` (about 5 KB gzipped, no dependencies). It reports uncaught JavaScript errors and unhandled
promise rejections, with the last clicks, page changes, console errors and failed requests; and it measures each full
page load (Core Web Vitals, Team and Business plans). Nothing is rendered when the browser key is missing or in tests.

watch.js loads from **your own website**, and its reports go there too (the browser relay, on by default):

- `/watch/watch.js` is the copy of watch.js that comes with the gem, served by `WatchClient::BrowserRelay` (first in
  the middleware stack, before sessions and authentication). Browsers keep it for a year per version.
- `/watch/browser_errors` and `/watch/browser_vitals` take the reports: only from your website's own pages, with your
  browser key, up to 64 KB (errors) or 4 KB (page speed), at most 60 errors and 120 page views per visitor per
  minute (600 and 6,000 in all, counted in `Rails.cache`). The visitor gets an empty answer at once; a background
  thread sends the reports to Watch with the server key at most once a minute, in batches of 200 reports or 1 MB.

So browser errors and page speed keep working where Watch's domain is blocked (company firewalls, ad blockers, some
countries), and a slow Watch never slows your pages. Watch still only stores reports from the websites you allowed
for the app. The visitor's IP address is Rails' `request.remote_ip`, so it follows your `trusted_proxies`.
`WATCH_BROWSER_RELAY=false` (or no `WATCH_API_KEY`) loads watch.js from Watch instead; `WATCH_BROWSER_PATH` moves
the relay (default `/watch`).

With a **Content Security Policy** and the relay, `:self` is all it needs (the tag gets the CSP nonce automatically).
Without the relay, allow Watch:

```ruby
# config/initializers/content_security_policy.rb
policy.script_src  :self, "https://watch.syncrecord.com"
policy.connect_src :self, "https://watch.syncrecord.com"
```

Try it in the browser console: `WatchClient.notify(new Error("Test from the console"))`.

### 7. Heartbeats for cron jobs and workers (optional)

For every scheduled job that must keep running, create a heartbeat in Watch (**Uptime → Heartbeats → New
heartbeat**, with how often it runs) and copy its token. Then:

```ruby
# pings when the block finishes, and reports a failure (then re-raises) when it raises
WatchClient.check_in(ENV["WATCH_HEARTBEAT_INVOICE_EXPORT"]) do
  InvoiceExport.run
end
```

Or from a crontab, without the gem:

```bash
0 2 * * * cd /app && bin/rails invoices:export && curl -fsS -m 10 --retry 3 https://watch.syncrecord.com/ping/<token>
```

Watch alerts when a ping doesn't arrive in time (period + grace time), or when a job calls `/ping/<token>/fail`.

### Checklist

- [ ] App created in Watch, API key copied, Slack / email alerts set on the app
- [ ] Gem added, initializer generated
- [ ] `WATCH_URL` and `WATCH_API_KEY` set in every deployed environment
- [ ] `bin/rails watch:test` prints OK on the server
- [ ] `bin/rails watch:deploy` runs after each deploy
- [ ] Optional: `watch_tag` in the layout and `WATCH_BROWSER_KEY` set (CSP updated)
- [ ] Optional: heartbeats for cron jobs
- [ ] Optional: `config.current_user_id` so log lines show the signed-in user

---

## What is sent, and when

All of this is on by default once `WATCH_URL` and `WATCH_API_KEY` are set. Each line can be turned off on its own.
Job queues and process health travel in the per-minute performance report, so `performance_monitoring = false`
stops them too.

| What | When | Turn off with |
| --- | --- | --- |
| Log lines (`Rails.logger`, level `info` and up) | Batches every 3 s or 500 lines | `config.send_logs = false` |
| One summary line per request (method, path, status, duration, controller#action, DB / view time) | With the logs | `config.log_requests = false` |
| Errors: unhandled exceptions in requests (also from middleware in front of Rails' error pages), ActiveJob and Sidekiq (also Sidekiq's own failures, like losing Redis); errors Rails handles itself (`Rails.error.report` / `handle`, a failing Redis cache); failing rake tasks; a crash that ends the process (at boot, `rails runner`, a worker that can't connect); `WatchClient.notify` | Right away (small batches, every second; rake tasks and crashes before the process ends) | `config.send_errors = false` |
| Performance: per controller action, per outside host (with API quotas and 429s), per job class (with time in SQL and HTTP): counts, failures, response-time histograms | Totals once a minute | `config.performance_monitoring = false` |
| Job queues: sizes, oldest job's wait, failed / retrying / dead (Solid Queue or Sidekiq) | Once a minute | `config.job_queue_monitoring = false` |
| Process health: memory, garbage collection, threads, Puma busy threads and backlog | Once a minute | `config.process_monitoring = false` |
| Database (PostgreSQL): slow queries, health, top queries, table sizes | Every minute / 5 minutes / hour | `config.database_monitoring = false` |
| Gem names and versions (Gemfile.lock), Ruby and Rails versions | Once, about 20 s after a server or worker starts (not consoles or rake tasks) | `config.report_dependencies = false` |
| Deploys | When `bin/rails watch:deploy` runs | (only sent when you run it) |
| Heartbeat pings | When `WatchClient.check_in` runs | `config.check_ins_enabled = false` |
| Browser: JavaScript errors and page speed (with the browser tag) | When they happen / once per page view | `config.browser_vitals = false` (page speed only) |

Every log line and error carries the environment, host, app version, request ID and (if configured) user ID. The
request ID follows a request into its jobs and into other Rails apps it calls (`X-Request-ID`), so one user action
can be traced across apps in Log Tail.

## What never leaves your app

- **Secrets:** keys in the app's `filter_parameters`, plus a built-in list that is always applied (`passw`, `email`,
  `secret`, `token`, `_key`, `crypt`, `salt`, `certificate`, `otp`, `ssn`, `cvv`, `cvc`, `iban`), are replaced with
  `[FILTERED]` in log payloads, `with_context` fields, error params, session, headers and breadcrumbs. The CSRF token,
  `Authorization`, `Cookie` and `X-Api-Key` headers are always hidden; cookie *values* are not sent by default.
- **URLs:** in error reports and request lines, query values whose name is secret or personal (token, key, auth,
  code, email, name, phone, address, postcode, IBAN, birth date…) are masked and the `#fragment` is removed.
- **Job arguments:** not sent unless you opt in (see `send_job_arguments`).
- **SQL values:** slow queries and query texts are normalised first: `WHERE email = 'a@b.c'` becomes `WHERE email = ?`.
- **Single requests:** performance numbers are per-minute totals, never individual requests or their parameters.
- **Page addresses:** page speed reports the path only, with ids replaced (`/invoices/:id`), never query strings.
- **Code and configuration:** only the gem list and versions, never source files (except a few lines of code around
  your own backtrace lines in error reports; `config.source_frames = 0` turns that off).
- **Database access:** Watch never connects to your database; the gem reads statistics over the app's own
  connection (only `SELECT`s on PostgreSQL's statistics views), with a 2-second statement timeout, and only when the
  connection pool is not busy.

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
WatchClient.log(:warn, "Slow sync", seconds: 12.4, account_id: account.id)
```

**Extra fields on every line inside a block** (e.g. the tenant in a multi-tenant job):

```ruby
WatchClient.with_context(tenant: account.slug) do
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
  WatchClient.notify(e, context: { order_id: order.id })
  # group all of these into one error, whatever the message:
  # WatchClient.notify(e, fingerprint: "stripe-capture")
end

# Rails' own error API works too:
Rails.error.handle(context: { order_id: order.id }) { charge.capture! }
```

**Errors you never want to see** (404s, bad requests, CSRF and `RecordNotFound` are already ignored):

```ruby
config.ignore_errors += ["Twilio::REST::RestError"]
```

**Failed jobs.** An error in a job always shows the job (class, id, queue, attempt). Its arguments are only sent
when you opt in, per ActiveJob class or for all jobs (`config.send_job_arguments = true`):

```ruby
class SyncAccountJob < ApplicationJob
  def self.watch_arguments(args) = [args.first] # only the account record, sent as "Account#42"
end
```

What is sent is made safe first: records become `Invoice#42`, hashes go through the filter list, email addresses are
masked, strings are cut at 300 characters, and the copy stops at 200 values or about 4 KB. Hash keys over 100 bytes
are left out with their value. Native Sidekiq jobs (not ActiveJob) only send arguments with `send_job_arguments`.

**Heartbeats:** see [step 7](#7-heartbeats-for-cron-jobs-and-workers-optional).

**In the browser** (with the browser tag): `WatchClient.notify(error)` for caught errors, `WatchClient.setUser({ id: 42 })`,
`WatchClient.setContext({ plan: "pro" })`, `WatchClient.addBreadcrumb("Opened checkout")`.

**From a console:** `WatchClient.stats` (what was queued, sent, retried or dropped) and `WatchClient.flush`.

---

## Configuration

Everything goes in `config/initializers/watch_client.rb`. Defaults are chosen so most apps only set the two
environment variables.

```ruby
WatchClient.configure do |config|
  config.url      = ENV["WATCH_URL"]
  config.api_key  = ENV["WATCH_API_KEY"]
  config.app_name = ENV.fetch("WATCH_APP_NAME", "billing-api")
  config.min_level = :info
  config.current_user_id = -> { Current.user&.id }
end
```

**Connection and identity**

| Option | Default | What it does |
| --- | --- | --- |
| `url`, `api_key` | `WATCH_URL`, `WATCH_API_KEY` | Where to send, and as which app |
| `allow_http` | `WATCH_ALLOW_HTTP` (off) | Accept `http://` Watch and ping URLs for remote hosts |
| `enabled` | on when url and key are set and the url is allowed (https), off in `test` | Force sending on or off |
| `app_name` | `WATCH_APP_NAME` or the app's module name (`billing-api`) | Shown by `watch:test` and `watch:config` |
| `environment` | `WATCH_ENVIRONMENT`, else `Rails.env` (outside Rails: `RAILS_ENV`, `RACK_ENV`, else `development`) | Environment filter in Watch |
| `host` | `DYNO`, `HOSTNAME` or the hostname | Server / container name |
| `app_version` | `WATCH_APP_VERSION`, `HEROKU_SLUG_COMMIT`, `GIT_SHA`, `SOURCE_VERSION` | Version on errors and deploys (first 12 characters) |

**Logs**

| Option | Default | What it does |
| --- | --- | --- |
| `send_logs` | `true` | Send Rails log lines |
| `min_level` | `:info` (or `WATCH_MIN_LEVEL`) | Lowest level sent: `:debug`, `:info`, `:warn`, `:error`, `:fatal`, `:unknown` |
| `log_requests` | `true` | The summary line per request |
| `current_user_id` | `nil` | Lambda returning the signed-in user's ID (added to lines and errors that carry a request ID: web requests and jobs they enqueued) |
| `filter_keys` | the app's `filter_parameters` plus the built-in list (outside Rails: the built-in list) | Keys masked as `[FILTERED]`; the built-in list always applies |
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
| `send_job_arguments` | `false` (`WATCH_SEND_JOB_ARGUMENTS=true` turns it on) | Every failed job's arguments with its error (records as `Invoice#42`, filtered, cut at 200 values / about 4 KB). Off because positional values (tokens, passwords) can't be filtered by name: better opt in per job with `def self.watch_arguments(args) = [args.first]` |
| `source_frames`, `source_lines` | `10`, `3` | Code around your backtrace lines (0 frames = off) |
| `app_root`, `backtrace_lines` | `Rails.root`, `100` | Backtrace paths made relative; maximum lines |

**Performance, jobs, processes and security**

| Option | Default | What it does |
| --- | --- | --- |
| `performance_monitoring` | on (`WATCH_PERFORMANCE_MONITORING=false` turns it off) | Endpoints, outside APIs, quotas and job runs; also carries job queues and process health |
| `job_queue_monitoring` | on (`WATCH_JOB_QUEUE_MONITORING=false`) | Queue sizes from Solid Queue or Sidekiq (needs `performance_monitoring`) |
| `process_monitoring` | on (`WATCH_PROCESS_MONITORING=false`) | Memory, garbage collection, threads, Puma (needs `performance_monitoring`) |
| `report_dependencies` | on (`WATCH_REPORT_DEPENDENCIES=false`) | Gem list at boot, for vulnerable gem alerts |
| `browser_vitals`, `vitals_sample_rate` | `true`, `1.0` | Page speed from watch.js; share of page views measured (e.g. `0.25`) |
| `browser_key`, `browser_enabled` | `WATCH_BROWSER_KEY`, on when url and browser key are set (off in `test`) | The browser tag |
| `browser_relay`, `browser_path` | on (`WATCH_BROWSER_RELAY=false`), `/watch` (`WATCH_BROWSER_PATH`) | watch.js and its reports through your own website (needs the API key too) |
| `check_ins_enabled` | on, off in `test` | Heartbeat check-ins (they need no API key) |

**Database (PostgreSQL)**

| Option | Default | What it does |
| --- | --- | --- |
| `database_monitoring` | on (`WATCH_DATABASE_MONITORING=false`) | Slow queries, health, top queries, tables |
| `slow_query_ms` | `500` (or `WATCH_SLOW_QUERY_MS`) | Queries at least this slow are reported |
| `before_send_query` | `nil` | `->(query) { ... }` change a slow query, or return `nil` to drop it |
| `database_interval` | `60` | Seconds between samples (also used for the performance report; minimum 15) |

For **Top queries**, enable PostgreSQL's `pg_stat_statements` extension (DigitalOcean and Heroku support it; in a
migration: `enable_extension "pg_stat_statements"`). Slow queries work with any database; the rest needs PostgreSQL.

**Delivery** (rarely changed)

| Option | Default | What it does |
| --- | --- | --- |
| `batch_size`, `flush_interval` | `500`, `3` | Lines per request (max 1000); max seconds before a batch is sent |
| `max_queue` | `10_000` | Buffer cap; the oldest lines are dropped beyond it |
| `max_queue_bytes` | `16 MB` | Buffer cap by size (JSON); the oldest lines are dropped beyond it. One log line is capped at 64 KB: bigger fields become `[TRUNCATED: n bytes]` |
| `max_retries`, `timeout` | `4`, `5` | Retries of a log or error batch for network errors and 408/425/429/500/502/503/504 (metrics and database samples retry once); HTTP timeout in seconds |
| `shutdown_timeout` | `5` | Seconds to deliver what's left when the process exits (per buffer: errors, logs, metrics) |
| `diagnostics` | `$stderr` | Where the gem reports its own problems (delivery problems at most once a minute per kind); `nil` to silence |

## Rake tasks

| Command | What it does |
| --- | --- |
| `bin/rails watch:config` | Show the settings the gem uses (only the key's last 4 characters) |
| `bin/rails watch:test` | Send one test log line; prints OK or the problem |
| `bin/rails watch:test_error` | Send a test error |
| `bin/rails watch:deploy [VERSION=…] [REVISION=…] [DEPLOYED_BY=…]` | Record a deploy (`DEPLOYED_BY` defaults to `$USER`) |
| `bin/rails watch:check_in TOKEN=… [FAIL=1] [MSG=…]` | Heartbeat check-in from a shell |
| `bin/rails watch:database [SEND=1]` | Print one database sample (and send it) |
| `bin/rails watch:dependencies [SEND=1]` | Print the gem list summary (and send it) |

## Troubleshooting

| Problem | Check |
| --- | --- |
| Nothing arrives at all | `bin/rails watch:config`: `enabled` must be true and url / key set. `bin/rails watch:test` prints the exact problem (wrong URL, 401, network) |
| `401` from Watch | The API key is wrong or was rotated, or the app is paused (plan limit) or set inactive in Watch |
| Some log lines are missing | `WatchClient.stats` in a console shows dropped entries; the account may be over its monthly volume (**Plan & usage** in Watch); `min_level` may be above the line's level |
| Errors don't show up | The class may be in `ignore_errors`; errors in the `test` environment are never sent; `before_notify` may return nil |
| JavaScript errors / page speed missing | `WATCH_BROWSER_KEY` set? The page's website listed under the app's allowed websites? Does `/watch/watch.js` open on your website (the browser relay)? Without the relay: CSP allows Watch in `script-src` and `connect-src`? Page speed needs the Team or Business plan |
| Performance, Jobs or Processes empty | Needs gem 0.7 / 0.8 or newer, a restart and `performance_monitoring` on; a process starts its per-minute report at its first request, outgoing call or job |
| `not sending anything: WATCH_URL must use https://` | Use an `https://` URL, or set `WATCH_ALLOW_HTTP=true` for a private network you trust |
| Database page empty | Needs Active Record (health, top queries and tables need PostgreSQL); `database_monitoring` on; Top queries needs `pg_stat_statements` |
| Security page empty | The gem list is sent when a server or worker starts (not from consoles or rake tasks): restart, or `bin/rails watch:dependencies SEND=1` |
| Too many alerts | Tune or mute them per app in Watch (Errors: ignore; Database: alert settings; Performance: alert switch) |

## FAQ

**Does it slow my app down?** The work in the request is adding a line to an in-memory buffer or a number to a
per-minute total. Sending happens on background threads, in batches, gzipped. If Watch is slow or down, the app
doesn't wait: buffers are capped and old entries are dropped.

**What about Puma workers, Sidekiq and Solid Queue processes?** Each process gets its own background threads after it
starts (also after a fork). Nothing to configure.

**Staging and production in one Watch app?** Yes: the environment is sent with everything and is a filter in
Watch. Or create one Watch app per environment, each with its own key.

**Can I use it outside Rails?** Yes: call `WatchClient.start!` once at boot (see
[Without Rails](#without-rails-sinatra-rack-scripts-workers)). Per-endpoint numbers, request lines, ActiveJob and
database monitoring need Rails.

**How do I turn it off temporarily?** Remove `WATCH_API_KEY`, or set `config.enabled = false`.

## Upgrading

Update the tag in the Gemfile and run `bundle update watch_client`; new features are on by default. See
[CHANGELOG.md](CHANGELOG.md). In short: 0.4 browser errors · 0.5 heartbeats · 0.6 database monitoring ·
0.7 performance, outside APIs, page speed and vulnerable gems · 0.8 background jobs and process health ·
0.10 renamed to `watch_client` (no old names kept: see below).

### Coming from `syncrecord_watch` or `loghub_client`

From 0.10 the gem is `watch_client` and the old names are gone, so change all of these at once:

| Old (`syncrecord_watch` 0.9 / `loghub_client`) | New |
| --- | --- |
| `gem "syncrecord_watch"` / `gem "loghub_client"` | `gem "watch_client", git: "https://github.com/SyncRecord-B-V/watch-client.git", tag: "v0.10.0"` |
| `SyncRecordWatch.…` / `LoghubClient.…` | `WatchClient.…` (e.g. `WatchClient.notify`, `WatchClient.check_in`) |
| `config/initializers/syncrecord_watch.rb` / `loghub_client.rb` | `config/initializers/watch_client.rb` (rename the file and the constant in it) |
| `SYNCRECORD_WATCH_*` / `LOGHUB_*` environment variables | `WATCH_*`: `WATCH_URL`, `WATCH_API_KEY`, `WATCH_BROWSER_KEY`, `WATCH_APP_NAME`, … |
| `<%= syncrecord_watch_tag %>` / `<%= loghub_browser_tag %>` | `<%= watch_tag %>` |
| `bin/rails loghub:test`, `loghub:deploy` … | `bin/rails watch:test`, `watch:deploy` … |
| `SyncRecordWatch.notify(...)` / `LogHub.notify(...)` in the browser | `WatchClient.notify(...)` |

Then run `bin/rails watch:config` and `bin/rails watch:test` to check.

## Without Rails (Sinatra, Rack, scripts, workers)

Set the same `WATCH_*` variables, then start it once at boot:

```ruby
require "watch_client"
WatchClient.start!                 # outgoing HTTP calls and quotas, metrics, Sidekiq, gem list, flush at exit

use WatchClient::RackMiddleware    # Rack / Sinatra apps: request IDs, breadcrumbs, errors that escape the app
use WatchClient::BrowserRelay      # with WATCH_BROWSER_KEY: watch.js and its reports on your own website
WatchClient.logger.info("...")     # logs (or broadcast your own logger to it)
WatchClient.notify(error)          # errors you rescue yourself
```

`start!` does nothing (and returns `false`) when Watch isn't configured, and is safe to call twice. It does not
add the Rack middleware or a logger for you.

Not available without Rails: per-endpoint response times, request summary lines, ActiveJob timing, Rails.error
reporting, SQL / render breadcrumbs and database monitoring. Errors from `RackMiddleware` have no request details
(URL, params, headers) outside Rails. After `start!` the buffers are delivered at exit (`WatchClient.shutdown`, up to
`shutdown_timeout`); without `start!`, call `WatchClient.flush` before a script exits.

## How it hooks into Rails

- `Rails.logger.broadcast_to(WatchClient.logger)`: one extra logger; your existing output is untouched.
- `WatchClient::RackMiddleware` right after `ActionDispatch::RequestId`: request ID in the context, outgoing-call timing.
- `WatchClient::OuterMiddleware` first in the stack: reports errors from middleware that runs before Rails' own error
  handling (a Redis-backed session or rate-limit store, `Rack::Cors`...) and raises them again.
- `WatchClient::BrowserRelay` right behind it: answers `/watch/watch.js`, `/watch/browser_errors` and
  `/watch/browser_vitals` (the browser relay); every other request passes straight through.
- `process_action.action_controller` subscriber: the request summary line and endpoint numbers.
- `sql.active_record` subscriber: slow queries (database monitoring).
- ActiveJob: `serialize` stores the request ID; `around_perform` sets the job context and times the job.
- Sidekiq (when present): client and server middleware for native Sidekiq jobs, and an error handler.
- `Net::HTTP` prepend: `X-Request-ID` on outgoing calls, timing per host, HTTP breadcrumbs.
- Errors: `Rails.error.subscribe` (jobs, executor, `Rails.error.report/handle`) and an
  `ActionDispatch::DebugExceptions` interceptor (unhandled request errors, even when Rails renders the 500 page).
  Each exception object is reported once.
- Rake: a failing task is reported and sent (at most 3 s) after rake prints it. Tasks that don't load the Rails
  environment only know Watch's settings from `WATCH_URL` / `WATCH_API_KEY` environment variables.
- Not covered by Rails' hooks, optional: errors Puma itself catches (while streaming a body, or a broken request).
  Add to `config/puma.rb`:

  ```ruby
  lowlevel_error_handler do |error, env|
    WatchClient.notify(error, handled: false) if defined?(WatchClient)
    [500, {}, ["Internal Server Error\n"]]
  end
  ```
- Background threads per process: log delivery, error delivery, the per-minute metrics report, the database sampler,
  and relayed browser reports (only once one arrives).
- `at_exit` (registered early in the boot): reports the exception that ends the process, if any (not `exit`, not
  signals), then delivers what is still buffered (up to `shutdown_timeout`).

## Development

```bash
bundle install
bundle exec rake test   # Minitest: unit tests + a small Rails app test (railtie_test.rb)
rubocop                 # style (.rubocop.yml); RuboCop is not in the Gemfile, install it with `gem install rubocop`
```

The unit tests start a fake Watch on `127.0.0.1` and need no network.
