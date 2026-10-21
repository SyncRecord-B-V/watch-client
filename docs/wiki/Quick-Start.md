# Quick Start

This page connects a Rails app to Watch in about ten minutes. You create the app in Watch, add the gem, set two
environment variables, deploy and check. You need to be an owner or admin of the account in Watch. For a Rack,
Sinatra or plain Ruby app, see [Without Rails](Without-Rails) after step 1.

## 1. Create the app in Watch

1. Sign in to Watch and open **Apps → New app**.
2. Give it a name (for example `Billing API`) and save.
3. Copy the **API key** (`lh_...`). It is shown only once. If you lose it, use **Create new API key** on the app's
   **Edit** page. The old key stops working at once.
4. Optional, for JavaScript errors and page speed: on the **Edit** page, copy the **browser key** (`lhb_...`) and list
   the websites allowed to use it.

Set where alerts go (Slack webhook, alert emails) on the same page. See the
[Watch wiki](https://github.com/SyncRecord-B-V/watch/wiki) for the hub side.

## 2. Add the gem

```ruby
# Gemfile
gem "watch_client", git: "https://github.com/SyncRecord-B-V/watch-client.git", tag: "v0.10.0"
```

```bash
bundle install
bin/rails generate watch_client:install   # creates config/initializers/watch_client.rb
```

The generated initializer works as it is. See [Installation in Rails](Installation-in-Rails).

## 3. Set the environment variables

Set them where the app runs (production, staging). Leave them out locally and in tests: without them the gem sends
nothing, and it never sends in the `test` environment.

```bash
WATCH_URL=https://watch.syncrecord.com
WATCH_API_KEY=lh_your_api_key_here
# optional:
WATCH_BROWSER_KEY=lhb_your_browser_key_here
```

`WATCH_URL` must use `https://`. See [Configuration](Configuration) for all variables.

Where to set them:

- **Heroku:** `heroku config:set WATCH_URL=... WATCH_API_KEY=...`
- **DigitalOcean App Platform:** the app's **Settings → App-Level Environment Variables**. Mark the API key as encrypted.
- **Kamal:** `env.secret` in `config/deploy.yml`, with the values in `.kamal/secrets`.
- **Your own server:** the service's environment (systemd `Environment=`, an `.env` file loaded by your process manager).

## 4. Deploy and check

On the server, from a console or one-off command:

```bash
bin/rails watch:config       # the settings the gem uses
bin/rails watch:test         # sends one log line; prints OK or the problem
bin/rails watch:test_error   # sends a test error (WatchClient::TestError)
```

In Watch, **Apps** shows the app as sending, **Log Tail** shows the test line and **Errors** shows the test error.
Performance numbers arrive once a minute after the first request. The gem list (Security) arrives about 20 seconds
after a server or worker starts.

## 5. Record deploys

Run `bin/rails watch:deploy` after every deploy. See [Deploys](Deploys).

## 6. Optional extras

- JavaScript errors and page speed: [Browser Errors and Page Speed](Browser-Errors-and-Page-Speed).
- Cron jobs and workers: [Heartbeats](Heartbeats).
- The signed-in user on log lines and errors: `config.current_user_id`, see [Logging](Logging).

## Checklist

- [ ] App created in Watch, API key copied, alerts set on the app
- [ ] Gem added, initializer generated
- [ ] `WATCH_URL` and `WATCH_API_KEY` set in every deployed environment
- [ ] `bin/rails watch:test` prints OK on the server
- [ ] `bin/rails watch:deploy` runs after each deploy
- [ ] Optional: `watch_tag` in the layout, `WATCH_BROWSER_KEY` set, CSP updated
- [ ] Optional: heartbeats for cron jobs
- [ ] Optional: `config.current_user_id`
