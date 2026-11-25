# streaming

A subscription video streaming service: the video store, twenty years
later. A catalog of 1,200 movies and series is licensed region by region
for limited periods; accounts in 10 regions pick a plan whose price changes
over time, add profiles and devices, get monthly invoices and watch. The
service launched on 2024-01-01 and the data is "as of" 2026-11-01.

This database is about **time**: temporal keys for prices, licenses and
subscriptions, a partitioned event log, and window functions over viewing
history.

## Tables

| Table | What it holds |
|---|---|
| `title`, `season`, `episode` | the catalog; `title.search` is a generated `tsvector` |
| `genre`, `title_genre`, `person`, `title_credit` | genres, cast and crew |
| `title_embedding` | a `vector(24)` per title for "more like this" (pgvector, HNSW index) |
| `region` | 10 markets with currency and time zone |
| `license_window` | when a title may be streamed in a region, temporal key |
| `plan`, `plan_price` | 3 plans and their price history per region, temporal key |
| `account` | UUIDv7 primary key |
| `profile`, `device` | profiles (including kids profiles) and devices with JSONB capabilities |
| `subscription` | which plan an account was on when, temporal key and temporal foreign key |
| `invoice` | monthly invoices in local currency |
| `viewing_session` | every playback session, about 400,000 rows, partitioned by month |
| `watch_progress` | where each profile is in each title, maintained with `MERGE` |
| `rating` | thumbs down, up, or "love it" |

Functions and views: `record_session(...)`, `available_titles(region, day)`,
`playable_runtime_s(title, episode)`, `subscription_price`.

## Install

Requires PostgreSQL 18+ and pgvector (`postgresql-18-pgvector` on apt,
`pgvector_18` on dnf). pg_partman is optional.

```
createdb streaming
psql -d streaming -f schema.sql
psql -d streaming -f generate-data.sql             # about 20 seconds
psql -d streaming -v scale=3 -f generate-data.sql  # or: 3x the accounts
psql -d streaming -f pg_partman-setup.sql          # optional
psql -d streaming -f queries.sql                   # all the examples below
```

The generator is deterministic, including the UUIDv7 account ids, so the
same scale always gives the same rows.

## Temporal tables (PostgreSQL 18)

Three tables use `WITHOUT OVERLAPS` keys on a `daterange` column:

```sql
-- one price per plan, region and day
PRIMARY KEY (plan_id, region_code, valid_at WITHOUT OVERLAPS)    -- plan_price
-- a title's license windows in a region can't overlap
PRIMARY KEY (title_id, region_code, valid_at WITHOUT OVERLAPS)   -- license_window
-- an account has one plan at a time
UNIQUE (account_id, valid_at WITHOUT OVERLAPS)                   -- subscription
```

`subscription` also has a **temporal foreign key**:

```sql
FOREIGN KEY (plan_id, region_code, PERIOD valid_at)
    REFERENCES plan_price (plan_id, region_code, PERIOD valid_at)
```

A normal foreign key would only check that the plan exists. This one checks
that the plan had a price in that region for **every day** of the
subscription. The subscription may span several price periods, as long as
they cover it with no gaps. A subscription starting in 2022, before any
prices existed, is rejected.

Temporal tables join on overlapping periods. The `subscription_price` view
splits each subscription at every price change:

```sql
SELECT s.subscription_id, s.valid_at * p.valid_at AS valid_at, p.monthly_price
FROM subscription s
JOIN plan_price p ON p.plan_id = s.plan_id AND p.region_code = s.region_code
                 AND p.valid_at && s.valid_at;
```

## Partitioning

`viewing_session` is `PARTITION BY RANGE (started_at)`, with one partition
per month (`viewing_session_p20240101` and so on). Queries over a period
only touch the matching partitions:

```
streaming=# EXPLAIN (COSTS OFF) SELECT count(*) FROM viewing_session
            WHERE started_at >= '2026-10-01 00:00+00' AND started_at < '2026-11-01 00:00+00';
 Aggregate
   ->  Seq Scan on viewing_session_p20261001 viewing_session
```

`pg_partman-setup.sql` hands partitions from 2027-01 onward to
[pg_partman](https://github.com/pgpartman/pg_partman), which then keeps
four months ahead as long as `CALL partman.run_maintenance_proc()` runs
regularly (from cron, for example). The Docker setup runs it for you.

## MERGE

`record_session()` logs a session and folds it into `watch_progress` with a
single `MERGE`. `RETURNING merge_action()` (PostgreSQL 17+) reports
whether that started a title (`INSERT`) or continued one (`UPDATE`):

```sql
MERGE INTO watch_progress w
USING (SELECT ...) s
ON w.profile_id = s.profile_id AND w.title_id = s.title_id
WHEN MATCHED AND s.ended_at > w.updated_at THEN
    UPDATE SET episode_id = s.episode_id, position_s = s.position_s, ...
WHEN NOT MATCHED THEN
    INSERT (...) VALUES (...)
RETURNING merge_action();
```

The generator builds the initial `watch_progress` with the same kind of
`MERGE`.

## UUIDv7 (PostgreSQL 18)

`account.account_id` defaults to `uuidv7()`. These ids are unique and
random, but ordered by creation time, so they index like a serial and
`uuid_extract_timestamp()` gives the creation time back:

```sql
SELECT account_id, uuid_extract_timestamp(account_id), created_at
FROM account ORDER BY account_id LIMIT 3;
```

## Window functions

Binge streaks are a "gaps and islands" problem: consecutive days with 3+
episodes of the same series. Subtracting `row_number()` from the date gives
every day in an unbroken run the same value:

```sql
WITH binge_days AS (
    SELECT profile_id, title_id, started_at::date AS day
    FROM viewing_session WHERE episode_id IS NOT NULL
    GROUP BY 1, 2, 3 HAVING count(*) >= 3
)
SELECT profile_id, title_id, min(day), max(day), count(*) AS days
FROM (SELECT *, day - row_number() OVER (PARTITION BY profile_id, title_id ORDER BY day)::int AS grp
      FROM binge_days) t
GROUP BY profile_id, title_id, grp
ORDER BY days DESC LIMIT 10;
```

`queries.sql` also has the top titles per region with `rank()`, hours by
genre with `ROLLUP`, and "continue watching" with the next episode found by
a `LATERAL` subquery.

## pgvector

`title_embedding` isn't a language-model embedding. It is built so that
neighbours make sense: dimensions 1-16 are the title's genres, 17-20 its
kind, maturity, era and length, and 21-24 a hidden "tone". An HNSW index
with `vector_cosine_ops` serves the `<=>` (cosine distance) operator:

```sql
SELECT t.title_id, t.name, e1.embedding <=> e2.embedding AS distance
FROM title_embedding e1
JOIN title_embedding e2 ON e2.title_id <> e1.title_id
JOIN available_titles('DE', date '2026-10-31') t ON t.title_id = e2.title_id
WHERE e1.title_id = 1
ORDER BY e1.embedding <=> e2.embedding
LIMIT 5;
```

## JSONB

Devices report different things on different platforms, so `device.info`
is JSONB with a GIN index:

```sql
SELECT info ->> 'os', count(*),
       count(*) FILTER (WHERE info @> '{"screen": {"hdr": ["dolby_vision"]}}') AS dolby_vision
FROM device WHERE kind = 'tv' GROUP BY 1;
```

## Full-text search and pg_trgm

```sql
SELECT name FROM title, websearch_to_tsquery('english', 'detective lighthouse') q
WHERE search @@ q ORDER BY ts_rank(search, q) DESC;

SELECT name, similarity(name, 'the silnt harbour') FROM title
WHERE name % 'the silnt harbour' ORDER BY 2 DESC;
```
