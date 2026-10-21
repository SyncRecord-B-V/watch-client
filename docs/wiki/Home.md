# watch_client

`watch_client` is the Ruby gem that connects an app to Watch (`https://watch.syncrecord.com`). It sends logs,
errors, deploys, performance numbers, background job numbers, process health, database statistics and the gem list
to Watch, in the background. It never slows down or breaks the app: buffers are capped, failed sends are retried and
then dropped, and the gem's own errors are swallowed. This wiki covers gem version 0.10.0.

## Start here

- [Quick Start](Quick-Start): from zero to data in Watch in about ten minutes.
- [Installation in Rails](Installation-in-Rails): the generator, the initializer and what the gem hooks into.
- [Without Rails](Without-Rails): Rack, Sinatra, plain Ruby scripts and workers with `WatchClient.start!`.
- [Configuration](Configuration): every option, its environment variable and its default.

## What the gem does

- [What Is Sent](What-Is-Sent): each kind of data, when it is sent and how to turn it off.
- [Logging](Logging): Rails logs, structured lines, extra fields and user IDs.
- [Errors and Context](Errors-and-Context): automatic error reports, `WatchClient.notify`, `Rails.error`.
- [Background Jobs](Background-Jobs): job details on errors, job arguments (opt-in), job timing.
- [Deploys](Deploys): record each deploy with `bin/rails watch:deploy`.
- [Heartbeats](Heartbeats): tell Watch a cron job or worker ran, with `WatchClient.check_in`.
- [Browser Errors and Page Speed](Browser-Errors-and-Page-Speed): `watch_tag` and `watch.js`.
- [Outside API Quotas](Outside-API-Quotas): quota headers and 429 answers from APIs the app calls.
- [Database Monitoring](Database-Monitoring): slow queries and PostgreSQL health.
- [Performance Metrics](Performance-Metrics): endpoints, outside hosts, jobs, queues and processes.
- [Privacy and Filtering](Privacy-and-Filtering): what is masked and what never leaves the app.

## Reference

- [Rake Tasks](Rake-Tasks)
- [Troubleshooting](Troubleshooting)
- [FAQ](FAQ)
- [Upgrading](Upgrading) (also from `syncrecord_watch` and `loghub_client`)
- [Changelog](Changelog)
- [Development](Development)

## Requirements

- Ruby 3.2 or newer.
- Rails 7.1 or newer for the automatic Rails setup. Other Ruby apps use `WatchClient.start!`.
- No runtime dependencies other than Ruby's standard library and the `logger` gem.

Watch itself (the hub: apps, alerts, plans) is documented in the
[Watch wiki](https://github.com/SyncRecord-B-V/watch/wiki).
