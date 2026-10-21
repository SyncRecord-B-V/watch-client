# Logging

In Rails, every `Rails.logger` line at `min_level` (default `info`) and up is also sent to Watch. Your own log output
(stdout, files) stays as it is: the gem adds one more destination with `broadcast_to`. This page shows structured
lines, extra fields, the signed-in user and the request ID that links lines across requests, jobs and apps.

## Plain lines

```ruby
Rails.logger.info("Invoice sent")
```

`Rails.logger.silence` also quiets what goes to Watch.

## Structured lines

Pass a Hash. Its fields become searchable in Log Tail. The text of the line is `message`, else `msg`, else `event`,
else the fields as `key=value`.

```ruby
Rails.logger.info(event: "invoice.sent", invoice_id: invoice.id, total: invoice.total, message: "Invoice sent")

WatchClient.log(:warn, "Slow sync", seconds: 12.4, account_id: account.id)
```

Fields never overwrite the core columns (`timestamp`, `level`, `message`, `environment`, `host`, `request_id`,
`user_id`, `job_id`). Fields go through the filter list before the text is built, so
`logger.info(password: "x")` never shows the value.

## Extra fields inside a block

```ruby
WatchClient.with_context(tenant: account.slug) do
  ImportJob.perform_now(file)
end
```

Every line logged inside the block on this thread gets `tenant`. Context fields are filtered too.

## The signed-in user

```ruby
# config/initializers/watch_client.rb
config.current_user_id = -> { Current.user&.id }

# with Devise / Warden (gets the Rack env):
config.current_user_id = ->(env) { env["warden"]&.user(scope: :user, run_callbacks: false)&.id }
```

The ID is added to log lines and errors that carry a request ID (web requests, and jobs enqueued from them; there a `->(env)` lambda gets an empty env). Send an ID, not personal data. Errors in the
lambda are ignored.

## Request IDs

- In Rails, the request ID comes from `ActionDispatch::RequestId`, which also accepts an incoming `X-Request-ID`.
- ActiveJob and native Sidekiq jobs keep the request ID of the request that enqueued them.
- Outgoing `Net::HTTP` calls made during a request or job get an `X-Request-ID` header, so another app with this gem
  logs under the same ID. Limit it with `config.propagate_to = [/\.example\.com\z/]`, or turn it off with
  `config.propagate_request_id = false`.

## Change or drop lines

```ruby
config.before_send = ->(entry) { entry["message"].include?("healthcheck") ? nil : entry }
```

`entry` is a Hash with string keys. Return it (changed or not), or `nil` to drop the line.

## Limits

A message is capped at 32 KB. A whole line is capped at 64 KB: fields over 8 KB become `[TRUNCATED: n bytes]`.
Core columns other than the message are cut at 255 characters.

## Outside Rails

Use `WatchClient.logger` (a `::Logger`) or `WatchClient.log`. See [Without Rails](Without-Rails).
