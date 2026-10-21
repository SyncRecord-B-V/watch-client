# Without Rails

Outside Rails (Rack, Sinatra, plain Ruby scripts, workers) you start the gem yourself with `WatchClient.start!`. It
installs what the Railtie installs in a Rails app, as far as that works without Rails. You add the Rack middleware
and send logs through `WatchClient.logger` yourself. Some Rails-only features are not available.

## Setup

Set the same environment variables as in Rails:

```bash
WATCH_URL=https://watch.syncrecord.com
WATCH_API_KEY=lh_your_api_key_here
WATCH_ENVIRONMENT=production   # otherwise RAILS_ENV, RACK_ENV, else "development"
```

Configure in code if you prefer (optional; the defaults read the environment variables):

```ruby
require "watch_client"

WatchClient.configure do |config|
  config.app_name = "billing-worker"
end

WatchClient.start!
```

## What `start!` does

- Sets `filter_keys` to the built-in list if you did not set it (see [Privacy and Filtering](Privacy-and-Filtering)).
- Starts the per-minute metrics report (outside hosts, quotas, Sidekiq jobs, queues, process health) if
  `performance_monitoring` is on.
- Times SQL per job when `ActiveSupport::Notifications` is loaded.
- Hooks `Net::HTTP`: `X-Request-ID` propagation, timing per host, quota headers, HTTP breadcrumbs.
- Installs the Sidekiq middleware and error handler when Sidekiq is loaded.
- Sends the gem list about 20 seconds after boot, in server and worker processes only.
- Registers `at_exit { WatchClient.shutdown }`, which delivers buffered errors, logs and metrics.

`start!` does nothing and returns `false` when Watch is not configured. It is safe to call twice. It returns `true`
when running.

## Rack and Sinatra

```ruby
# config.ru
require "watch_client"
WatchClient.start!

use WatchClient::RackMiddleware
run MyApp
```

The middleware takes the request ID from an incoming `X-Request-ID` header, keeps breadcrumbs per request, and,
after `start!`, reports errors that escape the app (only `StandardError`s).

## Logs

```ruby
WatchClient.logger.info("Import started")
WatchClient.log(:warn, "Slow sync", seconds: 12.4)

# or add Watch to an existing logger (ActiveSupport 7.1+):
logger = ActiveSupport::BroadcastLogger.new(Logger.new($stdout), WatchClient.logger)
```

## Errors

```ruby
begin
  sync!
rescue => e
  WatchClient.notify(e, context: { account_id: 42 })
  raise
end
```

## Scripts and short-lived workers

After `start!`, the buffers are delivered at exit by `WatchClient.shutdown` (each buffer waits at most
`shutdown_timeout` seconds, default 5). Without `start!`, call `WatchClient.flush` before the script exits:

```ruby
WatchClient.flush               # errors, logs and metrics; default timeout: shutdown_timeout
WatchClient.flush(timeout: 10)
```

## Not available without Rails

- Per-endpoint response times and the request summary line.
- ActiveJob hooks (job context, timing, job details).
- `Rails.error` reporting and the DebugExceptions interceptor.
- SQL, render, mail and cache breadcrumbs.
- Database monitoring.
- Request details on errors (URL, params, headers, session): they need ActionDispatch.
- The `watch:*` rake tasks and the generator.

Native Sidekiq jobs are covered: job context, timing, job details and errors. Load Sidekiq before you call
`start!`, because `start!` only installs the Sidekiq parts when `Sidekiq` is already defined.
