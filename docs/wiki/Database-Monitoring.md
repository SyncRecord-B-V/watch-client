# Database Monitoring

In a Rails app with Active Record, the gem reports slow queries and, for PostgreSQL, takes a sample of the database
every minute: connections, the connection pool, transactions, cache hit ratio, deadlocks, long-running queries,
locks, size and replica lag. It also reads the heaviest queries and table sizes. Watch never connects to your
database: the gem reads statistics over the app's own connection. All SQL is sent without values.

## What is sent

| Part | When | Database |
| --- | --- | --- |
| Slow queries: queries at least `slow_query_ms` (500 ms) slow, grouped by SQL without values, with count, total and slowest time, the app line that ran them and the request ID of the slowest | With every sample | Any (Active Record) |
| Connection pool of this process: size, connections, busy, idle, waiting, dead | Every sample | Any |
| Health: connections and `max_connections`, active, idle, idle in transaction, waiting on locks, longest query and idle transaction, database size, replica lag, commits and rollbacks per second, cache hit ratio, deadlocks, temp bytes | Every sample | PostgreSQL |
| Longest running query (when 1 s or longer), without values | Every sample | PostgreSQL |
| Top queries: the 20 heaviest from `pg_stat_statements` | Every 5th sample | PostgreSQL with `pg_stat_statements` |
| Tables: the 30 largest tables, and the 30 largest unused indexes | Every 60th sample | PostgreSQL |

A sample is taken every `database_interval` seconds (default 60, minimum 15), so top queries every 5 minutes and
tables every hour by default. Each process starts its sampler at its first query. At most 200 slow query groups are
kept per interval.

## Top queries

Enable PostgreSQL's `pg_stat_statements` extension (DigitalOcean and Heroku support it):

```ruby
# in a migration
enable_extension "pg_stat_statements"
```

Without it, the gem reports "The pg_stat_statements extension is not installed in this database." instead of
the list.

## Safety

- Only `SELECT`s on PostgreSQL's statistics views, in a short transaction with a 2-second statement timeout.
- Nothing is read while the connection pool is busy, so sampling never takes a connection the app needs.
- The gem's own queries never show up as slow queries or breadcrumbs.
- SQL is normalized by a SQL-aware scanner: string and number values, bind parameters, dollar quotes and comments
  are replaced or removed. `WHERE email = 'a@b.c'` becomes `WHERE email = ?`. MySQL, MariaDB and Trilogy
  connections use MySQL quoting rules. See [Privacy and Filtering](Privacy-and-Filtering#sql).

## Settings

```ruby
config.database_monitoring = false           # or WATCH_DATABASE_MONITORING=false
config.slow_query_ms = 1000                  # or WATCH_SLOW_QUERY_MS=1000
config.before_send_query = ->(query) { query["sql"].include?("pg_sleep") ? nil : query }
config.database_interval = 60
```

`before_send_query` gets each slow query group as a Hash with string keys (`sql`, `name`, `count`, `total_ms`,
`max_ms`, `location`...). Return it, or `nil` to drop it.

## Check it

```bash
bin/rails watch:database          # prints one sample
bin/rails watch:database SEND=1   # prints it and sends it
```
