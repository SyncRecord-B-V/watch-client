# Heartbeats

A heartbeat tells Watch that a cron job or worker ran. You create the heartbeat in Watch, then ping it from the job
with `WatchClient.check_in`. Watch alerts when a ping does not arrive in time, or when the job reports a failure.
Check-ins are synchronous with a short timeout and never raise their own errors.

## Create the heartbeat

In Watch: **Uptime → Heartbeats → New heartbeat**, with how often the job runs. Copy its token. Store it in an
environment variable, for example `WATCH_HEARTBEAT_INVOICE_EXPORT`. The Watch side (periods, grace time, alerts) is
described in the [Watch wiki](https://github.com/SyncRecord-B-V/watch/wiki).

## Ping from Ruby

```ruby
# the job ran
WatchClient.check_in(ENV["WATCH_HEARTBEAT_INVOICE_EXPORT"])

# with a message (at most 250 characters are sent)
WatchClient.check_in(ENV["WATCH_HEARTBEAT_INVOICE_EXPORT"], message: "42 invoices")

# with a block: pings when the block succeeds; when it raises, reports a failure
# (with the error class and message) and re-raises
WatchClient.check_in(ENV["WATCH_HEARTBEAT_INVOICE_EXPORT"]) do
  InvoiceExport.run
end
```

- With a token, the ping goes to `<WATCH_URL>/ping/<token>` (and `/fail` for a failure). A token needs `WATCH_URL`.
- You can also pass the full ping URL (`https://.../ping/<token>`). Then `WATCH_URL` is not needed.
- Check-ins do not need `WATCH_API_KEY`.
- Without a block, `check_in` returns `true` when Watch accepted the ping. With a block, it returns the block's result.
- Check-ins are off in the `test` environment. Force them with `config.check_ins_enabled = true` or `false`.
- The ping URL must use `https://`, with the same exceptions as `WATCH_URL` (see [Configuration](Configuration#https-only)).

## Ping from a shell

```bash
bin/rails watch:check_in TOKEN=your_heartbeat_token
bin/rails watch:check_in TOKEN=your_heartbeat_token FAIL=1 MSG="export failed"
```

Or without the gem, from a crontab:

```bash
0 2 * * * cd /app && bin/rails invoices:export && curl -fsS -m 10 --retry 3 https://watch.syncrecord.com/ping/your_heartbeat_token
```

Call `/ping/<token>/fail` to report a failed run.
