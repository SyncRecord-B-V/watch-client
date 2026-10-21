# Outside API Quotas

Many APIs say in their answer headers how much of their rate limit is left. The gem reads those headers on every
outgoing `Net::HTTP` call and sends the numbers with the per-minute performance report. It also counts 429 (rate
limited) answers per host and per job class. Watch shows them under Performance > Outside APIs and can alert when a
quota runs low. No code is needed in the app.

## Supported headers

| Headers | Quota name | Used by |
| --- | --- | --- |
| `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` | `default` | IETF draft, newer APIs |
| `RateLimit: limit=100, remaining=50, reset=30` (one header) | `default` | IETF draft, single-header form |
| `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` | `default` (`day` for Exact Online) | GitHub and many others |
| `X-RateLimit-Minutely-Limit`, `-Remaining`, `-Reset` | `minute` | Exact Online |
| `X-HubSpot-RateLimit-Daily`, `X-HubSpot-RateLimit-Daily-Remaining` | `day` | HubSpot |
| `Sforce-Limit-Info: api-usage=6247/140000` | `day` | Salesforce (24 hours) |
| `X-Shopify-Shop-Api-Call-Limit: 32/40` | `bucket` | Shopify |

For each quota the gem sends `limit`, `remaining` and `reset_at` (when the API gives a reset). The newest value per
quota name and host in each minute is kept. At most 4 quotas per answer.

Reset values are read as seconds from now (always for the IETF headers, and for small numbers), a Unix time in
seconds or milliseconds, or an HTTP date. A reset more than 60 seconds in the past or more than 400 days ahead is
ignored.

## 429 answers

Every 429 answer is counted per outside host (`rate_limited`), and per job class and host when the call was made
inside a job. See [Background Jobs](Background-Jobs#job-timing).

## Safety

These headers come from another service, and they are read on the app's request or job thread. So:

- Only these quota headers are read; never other headers or the answer body.
- A quota header longer than 256 bytes is ignored before any parsing.
- Numbers have a bounded number of digits and are clamped.
- The free-form `RateLimit` header is read field by field, at most 8 fields.
- Parsing errors are swallowed; the call itself is never affected.

## Requirements

- `performance_monitoring` on (the default).
- The API client uses `Net::HTTP` (Faraday's default adapter and most Ruby SDKs do).
- In Rails nothing else is needed. Outside Rails, call `WatchClient.start!`. See [Without Rails](Without-Rails).
