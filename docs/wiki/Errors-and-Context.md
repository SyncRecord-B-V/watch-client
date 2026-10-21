# Errors and Context

The gem reports unhandled exceptions automatically: in Rails requests, in ActiveJob jobs, in native Sidekiq jobs,
and through `Rails.error`. You report errors you rescue yourself with `WatchClient.notify`. Each report carries
context: the request, the user, the job, breadcrumbs and code around your own backtrace lines. Each exception object
is reported only once, even when several hooks see it.

## Reported automatically

- **Rails requests:** an `ActionDispatch::DebugExceptions` interceptor, also when Rails renders the 500 page. The
  real error is reported (for example the cause inside `ActionView::Template::Error`).
- **Rails.error:** unhandled errors in jobs and the Rails executor, plus your own `Rails.error.report` and
  `Rails.error.handle`.
- **Sidekiq:** an error handler (every failed attempt, retries included).
- **Rack apps after `WatchClient.start!`:** `StandardError`s that escape the app, through `WatchClient::RackMiddleware`.

## Report a rescued error

```ruby
begin
  charge.capture!
rescue Stripe::APIError => e
  WatchClient.notify(e, context: { order_id: order.id })
end
```

`WatchClient.notify(exception, context: nil, fingerprint: nil, handled: true, component: nil, request: nil)`:

| Argument | What it does |
| --- | --- |
| `context` | A Hash shown with the error. Filtered like log fields |
| `fingerprint` | Errors with the same fingerprint are grouped as one error in Watch, whatever the message |
| `handled` | `true` by default for `notify` |
| `component` | Where it happened. Default: `Controller#action` or the job class |
| `request` | An `ActionDispatch::Request`, when the error is not reported inside that request |

It returns `true` when the error was queued. It returns `false` when Watch is off, `send_errors` is off, the class is
ignored, the same exception object was already reported, or `before_notify` returned `nil`.

## Rails.error

```ruby
Rails.error.handle(context: { order_id: order.id }) { charge.capture! }
Rails.error.report(e, handled: true, context: { order_id: order.id })
```

Handled errors are reported unless `config.report_handled_errors = false`. The `severity`, `source` and context
values are sent as plain data (objects become short strings).

## Context on every error

- **Request:** method, URL (filtered), params (filtered by Rails and the gem), remote IP, referrer, user agent,
  headers. `Cookie`, `Authorization`, `Proxy-Authorization`, `X-Api-Key`, `X-CSRF-Token` and headers that repeat the
  visitor's IP are hidden.
- **Session:** filtered, only when the request loaded it. Off with `send_session = false`.
- **Cookies:** names only. Values with `send_cookie_values = true`.
- **User:** from `current_user_id`, for errors that carry a request ID (web requests and the jobs they enqueued). See [Logging](Logging#the-signed-in-user).
- **Job:** class, id, queue and attempt. See [Background Jobs](Background-Jobs).
- **Your context:** `with_context` fields plus the `context:` you pass.
- **Breadcrumbs:** up to `breadcrumbs_max` (40) steps before the error in the same request or job: SQL without
  values, renders, jobs enqueued, mails, cache reads, outgoing HTTP calls, log lines at `warn` and up.
- **Source:** up to `source_frames` (10) of your own backtrace lines with `source_lines` (3) lines of code around
  them. `source_frames = 0` turns it off.
- **App facts:** host, PID, project root, version, Ruby and Rails versions, memory and load (Linux).

## Ignored errors

These classes (and their subclasses) are never reported:

```
ActionController::RoutingError            AbstractController::ActionNotFound
ActionController::MethodNotAllowed        ActionController::UnknownHttpMethod
ActionController::NotImplemented          ActionController::UnknownFormat
ActionController::InvalidAuthenticityToken ActionController::InvalidCrossOriginRequest
ActionController::BadRequest              ActionController::ParameterMissing
ActionDispatch::Http::Parameters::ParseError
ActionDispatch::Http::MimeNegotiation::InvalidType
ActiveRecord::RecordNotFound              Sidekiq::JobRetry::Skip
SignalException                           Interrupt
```

Add your own:

```ruby
config.ignore_errors += ["Twilio::REST::RestError"]
```

## Change or drop a report

```ruby
config.before_notify = ->(notice, exception) do
  return nil if exception.message.include?("timeout from legacy API")
  notice
end
```

`notice` is a Hash with string keys. Return it, or `nil` to drop the report.

## Test it

```bash
bin/rails watch:test_error
```

This sends a `WatchClient::TestError`. Look for it under **Errors** in Watch, then resolve it.
