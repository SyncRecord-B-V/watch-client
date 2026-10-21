# Troubleshooting

Start with `bin/rails watch:config` and `bin/rails watch:test` on the server: they show what the gem uses and the
exact problem when sending fails. The gem reports its own problems on `$stderr` as lines starting with
`[watch_client]` (delivery problems at most once per minute per kind). In a console, `WatchClient.stats` shows what was
queued, sent, retried and dropped.

## Problems and checks

| Problem | Check |
| --- | --- |
| Nothing arrives at all | `bin/rails watch:config`: `enabled` must be `true`, url and key set. `bin/rails watch:test` prints the exact problem (wrong URL, 401, network) |
| `enabled: false` with url and key set | The environment is `test`, `config.enabled = false` is set, or the URL is plain `http://` to a remote host |
| `[watch_client] not sending anything: WATCH_URL must use https://` | Use an `https://` URL, or set `WATCH_ALLOW_HTTP=true` for a private network you trust |
| `401` from Watch | The API key is wrong or was rotated, or the app is paused (plan limit) or inactive in Watch |
| Some log lines are missing | `WatchClient.stats` shows dropped entries; `min_level` may be above the line's level; the account may be over its monthly volume (**Plan & usage** in Watch) |
| Errors don't show up | The class may be in `ignore_errors`; errors in `test` are never sent; `before_notify` may return `nil`; `send_errors` may be off |
| Handled `Rails.error` errors missing | `report_handled_errors` may be `false` |
| User IDs missing | `current_user_id` is only used for lines and errors that carry a request ID (web requests, and jobs they enqueued) |
| JavaScript errors or page speed missing | `WATCH_BROWSER_KEY` set? The site listed under the app's allowed websites in Watch? CSP allows Watch in `script-src` and `connect-src`? Page speed needs the Team or Business plan |
| Performance, Jobs or Processes empty | `performance_monitoring` must be on (queues and processes depend on it). A process sends its first report about a minute after its first request, outgoing call or job. Restart after upgrading |
| Outside API quotas missing | The API must send one of the [supported headers](Outside-API-Quotas), and the client must use `Net::HTTP` |
| Database page empty | Needs Active Record; health, top queries and tables need PostgreSQL; top queries need `pg_stat_statements`; `database_monitoring` on |
| Security page empty | The gem list is sent about 20 s after a server or worker starts, not from consoles or rake tasks. Restart, or run `bin/rails watch:dependencies SEND=1` |
| Job arguments missing on errors | Off by default. See [Background Jobs](Background-Jobs#job-arguments-opt-in) |
| Heartbeat pings fail | `WATCH_URL` must be set when you pass a token; check-ins are off in `test`; the ping URL must use `https://` |
| A short script loses its last data | Call `WatchClient.start!` at boot (it delivers at exit) or `WatchClient.flush` before exit |
| Too many alerts | Tune or mute them per app in Watch. See the [Watch wiki](https://github.com/SyncRecord-B-V/watch/wiki) |

## Stats

```ruby
WatchClient.stats
# => { queued: 120, sent: 118, batches_sent: 3, buffered: 2, buffered_bytes: 900, retries: 0,
#      dropped_queue_full: 0, dropped_delivery: 0, errors: { queued: 1, sent: 1, ... } }
```

Counters that are zero may be missing from the Hash.

## Silence the gem's own messages

```ruby
config.diagnostics = nil         # or any IO, e.g. a File
```
