# Changelog

This page summarizes version 0.10.0 (unreleased). The full list, with every security detail and the older versions,
is in [CHANGELOG.md](https://github.com/SyncRecord-B-V/watch-client/blob/main/CHANGELOG.md) in the repository. That
file is the source of truth; update this page when it changes.

## 0.10.0 (unreleased)

### Renamed to `watch_client`

A clean break with no old names kept: gem `watch_client`, module `WatchClient`, environment variables `WATCH_*`,
view helper `watch_tag` (loads `watch.js`), rake tasks `watch:*`, generator `watch_client:install`, initializer
`config/initializers/watch_client.rb`. The `syncrecord_watch` and `loghub_client` names are removed. See
[Upgrading](Upgrading).

### New

- **Outside Rails:** `WatchClient.start!` installs outgoing HTTP timing and quotas, per-minute metrics, Sidekiq
  context and error handler, the gem list, and a flush at exit. `WatchClient::RackMiddleware` loads without Rails and,
  after `start!`, reports errors that escape the Rack app. `flush` and `shutdown` also send the buffered metrics.
  See [Without Rails](Without-Rails).
- **Failed jobs:** the error includes the job (class, id, queue, attempt). Arguments only on opt-in, per job
  (`def self.watch_arguments(args)`) or for all jobs (`send_job_arguments`, `WATCH_SEND_JOB_ARGUMENTS=true`), made
  safe and capped at 200 values / about 4 KB. Keys over 100 bytes are left out with their value. See
  [Background Jobs](Background-Jobs).
- **Job timing:** time in SQL (and number of queries) and in outgoing HTTP per job run; outgoing calls counted per job
  class and host.
- **Outside API quotas:** rate-limit headers of outgoing calls (`RateLimit-*`, `X-RateLimit-*`, Salesforce, Shopify,
  HubSpot, Exact Online) and 429 counts, sent with the per-host numbers. Headers over 256 bytes are ignored. See
  [Outside API Quotas](Outside-API-Quotas).

### Fixed

- An error reported through `Rails.error` inside a job was shown in the last nested job. The job running at the time
  now wins.

### Security

- HTTPS required for `WATCH_URL` and ping URLs, except local hosts or `WATCH_ALLOW_HTTP=true`.
- Structured log fields and `with_context` fields are filtered before any text is built from them.
- One SQL-aware sanitizer for breadcrumbs, slow, top and longest-running queries, per database dialect.
- Request URLs, referrers and query strings in errors and request lines have secret or personal values masked and
  the fragment removed; queries are parsed like Rack and filtered as one params hash.
- Every Rails `filter_parameters` rule is supported (procs, dotted rules, regexps), also without Rails.
- Memory and robustness: a log line is capped at 64 KB, each buffer at 16 MB; conversions of app data are bounded
  in depth and detect cycles; entries JSON can't encode are dropped and counted.

See [Privacy and Filtering](Privacy-and-Filtering).
