# FAQ

Short answers to common questions about the gem. For setup, see [Quick Start](Quick-Start). For problems, see
[Troubleshooting](Troubleshooting). For questions about Watch itself (plans, alerts, retention), see the
[Watch wiki](https://github.com/SyncRecord-B-V/watch/wiki).

**Does it slow my app down?**
The work in a request is adding a line to an in-memory buffer or a number to a per-minute total. Sending happens on
background threads, in gzipped batches. If Watch is slow or down, the app does not wait: buffers are capped and the
oldest entries are dropped. Only check-ins, deploys and an explicit `WatchClient.flush` wait for Watch, each with a
timeout.

**Can it break my app?**
The gem catches its own errors and never raises into the app. Exceptions from your code are re-raised unchanged
after they are recorded.

**What about Puma workers, Sidekiq and Solid Queue?**
Each process starts its own background threads, also after a fork. Nothing to configure.

**Staging and production in one Watch app?**
Yes. The environment is sent with everything and is a filter in Watch. Or create one Watch app per environment, each
with its own key.

**Does it send anything in development or tests?**
Not unless `WATCH_URL` and `WATCH_API_KEY` are set. In the `test` environment it never sends, and `watch_tag` renders
nothing.

**Can I use it outside Rails?**
Yes, with `WatchClient.start!`. See [Without Rails](Without-Rails).

**How do I turn it off temporarily?**
Remove `WATCH_API_KEY`, or set `config.enabled = false`.

**Why are job arguments not on my errors?**
They are off by default because positional values cannot be filtered by name. See
[Background Jobs](Background-Jobs#job-arguments-opt-in).

**Can I use plain HTTP?**
Only for local hosts, or with `WATCH_ALLOW_HTTP=true` on a private network you trust. See
[Configuration](Configuration#https-only).

**Which HTTP clients are measured?**
Everything built on `Net::HTTP`: Faraday's default adapter and most Ruby SDKs. Clients with their own HTTP stack
(for example libcurl-based ones) are not measured.

**Is the browser key a secret?**
No. It is public by design, like any key in a web page. The API key (`lh_...`) is secret.

**Where does the gem send data?**
Only to `WATCH_URL` (paths under `/api/v1/` and `/ping/`). See [What Is Sent](What-Is-Sent).
