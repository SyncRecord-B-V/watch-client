# Deploys

Record every deploy so Watch can show which deploy an error started in and compare response times before and after
each deploy. You run `bin/rails watch:deploy` once per deploy, on one machine. The deploy is sent right away (not
queued), and the task prints whether Watch accepted it.

## The rake task

```bash
bin/rails watch:deploy
bin/rails watch:deploy VERSION=a1b2c3d4e5f6 REVISION=a1b2c3d4e5f6 DEPLOYED_BY=ci
```

| Value | Where it comes from |
| --- | --- |
| version | `VERSION=...`, else `app_version` (`WATCH_APP_VERSION`, `HEROKU_SLUG_COMMIT`, `GIT_SHA`, `SOURCE_VERSION`), else `git rev-parse --short=12 HEAD`. The task stops with `No version found` when none is found |
| environment | `environment` (see [Configuration](Configuration)) |
| revision | `REVISION=...` (optional) |
| deployed by | `DEPLOYED_BY=...`, else `$USER` |

## Per platform

| Platform | How |
| --- | --- |
| Heroku | `Procfile`: `release: bin/rails db:migrate && bin/rails watch:deploy` |
| DigitalOcean App Platform | A job component of kind **Post-deploy** with run command `bin/rails watch:deploy` |
| Kamal | `.kamal/hooks/post-deploy`: `kamal app exec --reuse "bin/rails watch:deploy VERSION=$KAMAL_VERSION"` |
| Capistrano | `after "deploy:finished", "watch:deploy"` (a task that runs `bin/rails watch:deploy` on one app server) |

## From Ruby

```ruby
WatchClient.notify_deploy(version: "a1b2c3d4e5f6", revision: nil, deployed_by: "ci")
```

`notify_deploy` also takes `environment:`. It returns `true` when Watch accepted the deploy, and `false` when Watch is
off, no version is known, or the request failed (the reason goes to `diagnostics`).

## The version elsewhere

The same `app_version` is sent with every log line, error and performance report, so set `WATCH_APP_VERSION` (or one
of the platform variables) in the running app too.
