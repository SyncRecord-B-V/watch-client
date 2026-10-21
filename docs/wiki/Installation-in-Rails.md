# Installation in Rails

In a Rails 7.1+ app the gem sets itself up through a Railtie. You add the gem, run the install generator, and set
`WATCH_URL` and `WATCH_API_KEY`. This page shows the generator, the initializer it creates, and every part of Rails
the gem hooks into. Nothing starts (no threads, no output) until the URL and key are set.

## Add the gem

```ruby
# Gemfile
gem "watch_client", git: "https://github.com/SyncRecord-B-V/watch-client.git", tag: "v0.10.0"
```

```bash
bundle install
bin/rails generate watch_client:install
```

The generator `watch_client:install` creates `config/initializers/watch_client.rb` and prints the next steps.

## The initializer

The generated file looks like this (the app name comes from your app's module name):

```ruby
# config/initializers/watch_client.rb
WatchClient.configure do |config|
  config.url      = ENV["WATCH_URL"]
  config.api_key  = ENV["WATCH_API_KEY"]
  config.app_name = ENV.fetch("WATCH_APP_NAME", "billing-api")

  # Lowest level sent: :debug, :info, :warn, :error, :fatal
  config.min_level = ENV.fetch("WATCH_MIN_LEVEL", "info").to_sym

  # config.current_user_id = -> { Current.user&.id }
  # config.filter_keys = Rails.application.config.filter_parameters + [:iban]
  # config.propagate_to = [/\.example\.com\z/]
  # config.before_send = ->(entry) { entry["message"].include?("healthcheck") ? nil : entry }
  # config.ignore_errors += ["Twilio::REST::RestError"]
  # config.performance_monitoring = false
  # config.job_queue_monitoring = false
  # config.process_monitoring = false
  # config.database_monitoring = false
  # config.slow_query_ms = 500
  # config.report_dependencies = false
  # config.vitals_sample_rate = 0.25
end
```

Every setting is optional. All options are listed on [Configuration](Configuration).

## Environment variables

```bash
WATCH_URL=https://watch.syncrecord.com
WATCH_API_KEY=lh_your_api_key_here
```

The gem is on when both are set, the URL is allowed (see [HTTPS](Configuration#https-only)) and the environment is
not `test`.

## What the gem hooks into

The Railtie does this at boot:

- **Defaults:** `environment` becomes `Rails.env` (unless `WATCH_ENVIRONMENT` is set); `app_name` becomes the app's
  module name in dashes (unless set); `filter_keys` becomes the app's `filter_parameters` plus the built-in list;
  `app_root` becomes `Rails.root`.
- **Middleware:** `WatchClient::RackMiddleware` right after `ActionDispatch::RequestId`. It puts the request ID in the
  log context and times outgoing calls during the request.
- **View helper:** `watch_tag` in every view.
- **ActiveJob:** stores the request ID with each job; sets the job context while it runs; times it; keeps the job's
  details for error reports.
- **Rake tasks** `watch:*` and the generator `watch_client:install`.

When the gem is on, after the app has initialized:

- `Rails.logger.broadcast_to(WatchClient.logger)`: one extra log destination. Your own log output is untouched.
- A `process_action.action_controller` subscriber: the request summary line and endpoint numbers.
- The per-minute metrics report (if `performance_monitoring` is on) and SQL timing per job.
- A `Net::HTTP` hook (Faraday's default adapter and most SDKs use it): `X-Request-ID` on outgoing calls, timing per
  host, quota headers, HTTP breadcrumbs.
- Breadcrumb subscribers (SQL without values, renders, jobs enqueued, mails, cache reads), if `breadcrumbs` is on.
- Sidekiq client and server middleware and an error handler, when Sidekiq is loaded.
- Error reporting (if `send_errors` is on): `Rails.error.subscribe` and an `ActionDispatch::DebugExceptions`
  interceptor. Each exception object is reported once.
- Database monitoring (if on and Active Record is loaded).
- The gem list, about 20 seconds after a server or worker process starts.
- `at_exit { WatchClient.shutdown }`: delivers what is still buffered.

## Puma, Sidekiq and Solid Queue

Each process starts its own background threads, also after a fork. Nothing to configure.

## Check it

```bash
bin/rails watch:config
bin/rails watch:test
bin/rails watch:test_error
```

See [Rake Tasks](Rake-Tasks) and [Troubleshooting](Troubleshooting).
