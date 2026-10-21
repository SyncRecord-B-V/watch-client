# Privacy and Filtering

The gem filters data inside the app, before anything is sent. Secrets in parameters, sessions, headers, log fields
and URLs are replaced with `[FILTERED]`. SQL is sent without values. Performance numbers are per-minute totals. Job
arguments and cookie values are off by default. This page lists every rule, so you can check what leaves the app.

## The filter list

Values whose key matches a rule become `[FILTERED]`. The rules are:

- In Rails: the app's `Rails.application.config.filter_parameters`, through `ActiveSupport::ParameterFilter`. Every
  Rails rule works: substrings, regexps, dotted rules like `"account.credential"`, and procs.
- Always, also when the app has no rules of its own: `passw`, `email`, `secret`, `token`, `_key`, `crypt`, `salt`,
  `certificate`, `otp`, `ssn`, `cvv`, `cvc`, `iban` (substring match on the key).
- Outside Rails the same kinds of rules are applied without ActiveSupport.

Set your own list with `config.filter_keys`; the built-in list is still added:

```ruby
config.filter_keys = Rails.application.config.filter_parameters + [:iban, /\Aapi_/]
```

The filter walks every level of nested hashes and arrays. A rule that raises hides all values. Data nested deeper
than 32 levels is masked.

## Where the filter applies

- Structured log fields and the text built from them.
- `with_context` fields.
- Error params, session, headers, CGI variables, cookies and your error context.
- Breadcrumb metadata and warning breadcrumbs.
- Job arguments (when you opt in).
- URL query strings (see below).

## Always hidden

- Headers: `Cookie`, `Authorization`, `Proxy-Authorization`, `X-Api-Key`, `X-CSRF-Token`.
- Headers that repeat the visitor's IP: `X-Forwarded-For`, `X-Real-IP`, `CF-Connecting-IP`, `True-Client-IP`,
  `Forwarded`. The IP is sent once, as `remote_ip`.
- In the session: the CSRF token, `session_id` and `warden.*` keys.
- Cookie values (names are sent). Turn values on with `send_cookie_values = true`.

## URLs

The request URL, referrer, `Referer` header, `QUERY_STRING`, `REQUEST_URI`, `ORIGINAL_FULLPATH` and the path of the
request summary line are filtered:

- Query values are masked when their name matches the filter list, or looks secret or personal: token, secret,
  passw, key, auth, session, signature, code, email, name, phone, tel, address, IBAN, zip, postcode, birth.
- The query is parsed like Rack parses it (`account[credential]` nests, `ids[]` collects), so dotted rules and procs
  work in URLs. Every occurrence of a masked parameter is masked.
- The `#fragment` is removed.
- A query over 4 KB, over 100 parameters or nested deeper than 8 levels is left out entirely.

## SQL

Every SQL the gem sends (slow queries, top queries, the longest running query, query breadcrumbs) goes through one
SQL-aware scanner:

- String and number values, `IN (...)` lists and bind parameters (`$1`) become `?`.
- It handles `''` and `E'...'` escapes, dollar quotes (`$$...$$`, `$tag$...$tag$`) and quoted identifiers.
- Comments (`--`, nested `/* */`, and `#` in MySQL) are removed.
- MySQL, MariaDB and Trilogy connections treat `"..."` as a value and `` `...` `` as an identifier.
- A string whose end depends on backslash settings, or a value cut off in the middle, is dropped with everything
  after it.

```
SELECT * FROM users WHERE email = 'a@b.c' AND id IN (1, 2, 3) LIMIT 10
=> SELECT * FROM users WHERE email = ? AND id IN (?) LIMIT ?
```

## Limits

- A log message is capped at 32 KB, a log line at 64 KB (fields over 8 KB become `[TRUNCATED: n bytes]`).
- An error message is capped at 8 KB; params and each section (headers, session, cookies, CGI) at 16 KB.
- Data nested deeper than 20 levels becomes `[TOO DEEP]`; data that contains itself becomes `[CIRCULAR]`.
- Each buffer is capped at `max_queue` entries and `max_queue_bytes` (16 MB).

## What never leaves the app

- Single requests and their parameters in performance numbers (they are per-minute totals).
- Page query strings and ids in page speed (`/invoices/:id`).
- Source files, except a few lines around your own backtrace lines in errors (`source_frames = 0` turns that off).
- Database contents: only statistics and SQL without values.
- Answer bodies and headers of outside APIs, except the quota headers (see [Outside API Quotas](Outside-API-Quotas)).
- Job arguments, unless you opt in (see [Background Jobs](Background-Jobs)).

## Your own rules

| Hook | Gets | Return `nil` to |
| --- | --- | --- |
| `before_send` | a log line (Hash) | drop the line |
| `before_notify` | an error report (Hash) and the exception | drop the report |
| `before_send_query` | a slow query group (Hash) | drop the query |

An entry that JSON can't encode after a hook (for example circular data) is dropped and counted as
`dropped_unencodable`.
