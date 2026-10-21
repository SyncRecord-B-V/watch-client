# Rake Tasks

In a Rails app the gem adds rake tasks under the `watch:` namespace. Use them to check the setup on a server, send
test data, record deploys, ping heartbeats and look at what the gem would send. They all load the Rails environment.
Outside Rails these tasks are not loaded.

| Command | What it does |
| --- | --- |
| `bin/rails watch:config` | Shows `enabled`, `url`, the API key's last 4 characters (or `missing`), `app_name`, `environment`, `host`, `app_version`, `min_level` |
| `bin/rails watch:test` | Checks the settings and sends one test log line right away. Prints `OK: ...` or the problem. Exits with 1 on failure |
| `bin/rails watch:test_error` | Sends a `WatchClient::TestError` and waits up to 10 s for delivery. Prints `OK` or `FAILED` with the stats |
| `bin/rails watch:deploy [VERSION=…] [REVISION=…] [DEPLOYED_BY=…]` | Records a deploy. See [Deploys](Deploys) |
| `bin/rails watch:check_in TOKEN=… [FAIL=1] [MSG=…]` | Heartbeat check-in. `TOKEN` is the token or the full ping URL. See [Heartbeats](Heartbeats) |
| `bin/rails watch:database [SEND=1]` | Prints one database sample (with top queries and tables); `SEND=1` also sends it. See [Database Monitoring](Database-Monitoring) |
| `bin/rails watch:dependencies [SEND=1]` | Prints the gem count, Ruby and Rails versions and digest; `SEND=1` also sends the gem list |

The generator:

```bash
bin/rails generate watch_client:install   # creates config/initializers/watch_client.rb
```

## What `watch:test` checks

- `url` is set (`WATCH_URL`).
- `api_key` is set (`WATCH_API_KEY`).
- The URL uses `https://` (or is allowed, see [Configuration](Configuration#https-only)).
- `batch_size` is between 1 and 1000.
- `min_level` is a known level.

Then it sends the line and prints the HTTP answer, for example `FAILED: HTTP 401: ...`.

From a console, `WatchClient.test!` does the same.
