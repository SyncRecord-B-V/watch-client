# watch_client

Ruby gem that connects a Rails app to Watch (logs, errors, deploys, performance, jobs, database, gems).
It runs inside customers' production apps. Tests: `bundle exec rake test`.

## Code Review Rules

### Never break or slow down the host app
- The gem must never raise into the app, block a request, or grow memory without bound. Flag work on the
  request thread that could block (network calls, unbounded loops), exceptions that can escape, and buffers
  without a cap. Safe path: background thread, capped queue, rescue and count failures.

### Off unless configured
- Without `WATCH_URL` and `WATCH_API_KEY` the gem stays silent: no threads, no output, `watch_tag` renders
  nothing. Flag changes that start work or print errors when it isn't configured.

### Privacy
- Nothing personal leaves the app unless needed: parameters, sessions and headers go through the filter list,
  SQL values are replaced by `?`, cookie values are hidden. Flag new data sent to Watch without filtering.

### Fork and thread safety
- Puma and Sidekiq fork: background threads must restart after a fork (pid check) and shared state must be
  thread-safe. Flag new shared state without a mutex or fork handling.
