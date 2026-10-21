# Upgrading

To upgrade, change the tag in the Gemfile, run `bundle update watch_client` and restart. New features are on by
default. Version 0.10.0 renamed the gem to `watch_client` with no old names kept, so apps on `syncrecord_watch` or
`loghub_client` must change every name at once. This page lists those changes.

## Normal upgrade

```ruby
# Gemfile
gem "watch_client", git: "https://github.com/SyncRecord-B-V/watch-client.git", tag: "v0.10.0"
```

```bash
bundle update watch_client
bin/rails watch:config
bin/rails watch:test
```

## Coming from `syncrecord_watch` (0.9) or `loghub_client`

| Old | New |
| --- | --- |
| `gem "syncrecord_watch"` / `gem "loghub_client"` | `gem "watch_client", git: "https://github.com/SyncRecord-B-V/watch-client.git", tag: "v0.10.0"` |
| `require "syncrecord_watch"` / `require "loghub_client"` | `require "watch_client"` |
| `SyncRecordWatch.…` / `LoghubClient.…` | `WatchClient.…` (for example `WatchClient.notify`, `WatchClient.check_in`) |
| `config/initializers/syncrecord_watch.rb` / `loghub_client.rb` | `config/initializers/watch_client.rb` (rename the file and the constant in it) |
| `SYNCRECORD_WATCH_*` / `LOGHUB_*` environment variables | `WATCH_*`: `WATCH_URL`, `WATCH_API_KEY`, `WATCH_BROWSER_KEY`, `WATCH_APP_NAME`, ... |
| `<%= syncrecord_watch_tag %>` / `<%= loghub_browser_tag %>` | `<%= watch_tag %>` |
| `bin/rails loghub:test`, `loghub:deploy`, ... | `bin/rails watch:test`, `watch:deploy`, ... |
| `bin/rails generate loghub_client:install` | `bin/rails generate watch_client:install` |
| `SyncRecordWatch.notify(...)` / `LogHub.notify(...)` in the browser | `WatchClient.notify(...)` |

Steps:

1. Change the Gemfile line and run `bundle install`.
2. Rename the initializer and replace the module name in it.
3. Rename the environment variables on every platform (Heroku, App Platform, Kamal secrets, servers).
4. Replace the view helper in your layouts.
5. Search the code for the old names (`SyncRecordWatch`, `LoghubClient`, `loghub:`, `syncrecord_watch`) and replace
   them, also in deploy scripts and crontabs.
6. Check that the Content Security Policy allows the host in `WATCH_URL`.
7. Deploy, then run `bin/rails watch:config` and `bin/rails watch:test`.

## Version history in short

0.4 browser errors, 0.5 heartbeats, 0.6 database monitoring, 0.7 performance, outside APIs, page speed and
vulnerable gems, 0.8 background jobs and process health, 0.9 renamed to `syncrecord_watch`, 0.10 renamed to
`watch_client`, `WatchClient.start!`, job details, job timing and API quotas. See [Changelog](Changelog).

## Things to know in 0.10.0

- Job arguments are off by default. Opt in per job or with `WATCH_SEND_JOB_ARGUMENTS=true`. See
  [Background Jobs](Background-Jobs).
- `WATCH_URL` must use `https://` unless the host is local or `WATCH_ALLOW_HTTP=true` is set.
- Outside Rails, replace manual setup with `WatchClient.start!`. See [Without Rails](Without-Rails).
