# Performance Metrics

Each process adds up its numbers per minute and sends them once a minute in one performance report. The work done
during a request is adding a number to an in-memory total. The report covers controller actions, outside hosts the app
calls, background jobs, job queues and process health. Single requests and their parameters are never sent.

## What is in the report

| Section | Per | Numbers |
| --- | --- | --- |
| Endpoints (Rails) | controller action (`InvoicesController#show`) | count, 5xx, total and slowest time, histogram, time in database, views and outgoing HTTP |
| Outside hosts | host the app calls (`api.stripe.com`) | count, 5xx and connection failures, 4xx, timeouts, failures, 429s, total and slowest time, histogram, quotas |
| Jobs | job class | runs, failures, total and slowest time, histogram, queue wait, time in SQL, number of queries, time in HTTP |
| Job calls | job class and host | count, failures, 429s, total time |
| Queues | queue (Solid Queue or Sidekiq) | size, oldest job's wait; failed, scheduled, running / retries, dead, scheduled, running |
| Process | process | role (web, worker, other), memory (RSS), threads, uptime, garbage collection since the last report, heap slots; in Puma: running and max threads, pool capacity, backlog, request count |

Histograms use fixed bucket bounds (5 ms to 20 s), so Watch can add up many processes and minutes and still give
p50, p95 and p99.

Caps per minute and process: 300 endpoints, 100 hosts, 200 job classes, 500 job and host pairs, 50 queues. New names
beyond a cap are not counted that minute.

## When

- The report is sent every `database_interval` seconds (default 60, minimum 15).
- A process starts its report thread at its first request, outgoing call or job. An idle process sends nothing.
- `WatchClient.flush` and `WatchClient.shutdown` (also at exit) send the current numbers too.
- A failed report is retried once.

## Settings

```ruby
config.performance_monitoring = false   # or WATCH_PERFORMANCE_MONITORING=false: no report at all
config.job_queue_monitoring = false     # or WATCH_JOB_QUEUE_MONITORING=false
config.process_monitoring = false       # or WATCH_PROCESS_MONITORING=false
```

Queues and process health are part of the performance report: with `performance_monitoring = false` they are not
sent either.

## Outside hosts

Outgoing calls are measured through `Net::HTTP` (Faraday's default adapter and most SDKs). The host includes the
port when it is not 80 or 443. Calls the gem makes to Watch are not counted. See
[Outside API Quotas](Outside-API-Quotas).

## Without Rails

`WatchClient.start!` starts the report for outside hosts, quotas, native Sidekiq jobs, queues and process health.
Endpoints need Rails. See [Without Rails](Without-Rails).
