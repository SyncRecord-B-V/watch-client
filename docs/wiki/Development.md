# Development

This page is for people working on the gem itself. The tests use Minitest (not RSpec) and start a fake Watch on
`127.0.0.1`, so they need no network. Style is checked with RuboCop. The gem must never raise into the host app,
block a request or grow memory without bound; keep that in mind for every change.

## Setup

```bash
git clone https://github.com/SyncRecord-B-V/watch-client.git
cd watch-client
bundle install
```

Ruby 3.2 or newer. The Gemfile includes `minitest`, `rake` and, in the `rails` group, `actionpack`, `activejob` and
`railties` (7.1 or newer) for the Rails test. The gem itself has no Rails dependency.

## Run the tests

```bash
bundle exec rake test                                 # all tests (the default rake task)
bundle exec ruby -Ilib -Itest test/client_test.rb     # one file
```

The tests live in `test/*_test.rb`. `test/test_helper.rb` has `FakeHub`, a small HTTP server that records requests
and answers with queued status codes. `test/railtie_test.rb` boots a small Rails app.

## Style

```bash
rubocop
```

The settings are in `.rubocop.yml` (line length 140, Metrics cops off). RuboCop is not in the Gemfile: install it
with `gem install rubocop`.

## Code review rules

From `AGENTS.md`:

- **Never break or slow down the host app.** No blocking work on the request thread, no exceptions that can escape,
  no buffers without a cap.
- **Off unless configured.** Without `WATCH_URL` and `WATCH_API_KEY`: no threads, no output, `watch_tag` renders
  nothing.
- **Privacy.** Parameters, sessions and headers go through the filter list, SQL values become `?`, cookie values are
  hidden. New data sent to Watch must be filtered.
- **Fork and thread safety.** Background threads restart after a fork (pid check); shared state needs a mutex.

## Layout

| Path | What it is |
| --- | --- |
| `lib/watch_client.rb` | Public API: `configure`, `start!`, `notify`, `log`, `check_in`, `flush`, `shutdown`, `stats` |
| `lib/watch_client/configuration.rb` | All options and their defaults |
| `lib/watch_client/railtie.rb` | Rails integration |
| `lib/watch_client/client.rb`, `transport.rb` | Buffers and delivery |
| `lib/watch_client/filter.rb`, `sql_normalizer.rb` | Filtering and SQL sanitizing |
| `lib/watch_client/metrics.rb`, `api_quota.rb`, `job_timer.rb` | Per-minute performance report |
| `lib/watch_client/job_details.rb` | Job details and arguments on errors |
| `lib/watch_client/database_monitor.rb`, `database_sampler.rb`, `slow_queries.rb` | Database monitoring |
| `lib/watch_client/tasks.rake` | `watch:*` rake tasks |
| `lib/generators/watch_client/install` | The install generator and initializer template |

## Releasing

The gem is private and installed from Git (`allowed_push_host` blocks rubygems.org). Bump
`lib/watch_client/version.rb`, update `CHANGELOG.md`, tag the commit (`v0.10.0`) and push the tag.
