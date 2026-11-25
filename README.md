# pg_fil

Five sample databases for PostgreSQL, set in businesses people use today.

[Pagila](https://github.com/devrimgunduz/pagila) is a DVD rental store, a
fine schema for examples in books, tutorials and talks, but renting DVDs
isn't a 2026 thing. pg_fil keeps the idea: realistic schemas and data that
are fun to query, each built to show off a different part of modern
PostgreSQL.

About the name: MySQL's sample database is Sakila, named after its dolphin
(the name was suggested from SiSwati), and Pagila is Postgres + Sakila.
*Fil* is Turkish for elephant, after Slonik, the PostgreSQL elephant.

| Database | The business | What it shows off |
|---|---|---|
| [streaming](streaming/) | a subscription video service: catalog, regional licenses, plans, viewing history | temporal primary and foreign keys, partitioning, `MERGE`, UUIDv7, window functions, pgvector |
| [stays](stays/) | a short-term vacation rental marketplace | exclusion constraints (no double bookings), multiranges, PostGIS radius search, JSONB and SQL/JSON, full-text search |
| [ev-charging](ev-charging/) | an electric vehicle charging network | time series with partitions and BRIN, `date_bin()`, two-range exclusion constraints, OCPP messages in JSONB, `range_agg()` |
| [ticketing](ticketing/) | concert, sports and theatre tickets | `FOR UPDATE SKIP LOCKED`, advisory locks, partial unique indexes, recursive CTEs, row-level security, `LISTEN`/`NOTIFY` |
| [micromobility](micromobility/) | shared bikes and e-scooters | PostGIS zones, routes, KNN and hexagon grids, `LATERAL`, materialized views, `CUBE` |

### Features by database

| Feature | streaming | stays | ev-charging | ticketing | micromobility |
|---|:-:|:-:|:-:|:-:|:-:|
| Temporal keys (`WITHOUT OVERLAPS`, PG 18) | ✓ | ✓ | | | ✓ |
| Temporal foreign keys (`PERIOD`, PG 18) | ✓ | | | | |
| Exclusion constraints | | ✓ | ✓ | ✓ | ✓ |
| Range types and multiranges | ✓ | ✓ | ✓ | ✓ | ✓ |
| Declarative partitioning (+ optional pg_partman) | ✓ | | ✓ | | ✓ |
| BRIN indexes | | | ✓ | | ✓ |
| `MERGE ... RETURNING merge_action()` | ✓ | | | | |
| UUIDv7 (PG 18) | ✓ | | | ✓ | |
| JSONB, SQL/JSON path, `JSON_TABLE` | ✓ | ✓ | ✓ | | |
| Full-text search, pg_trgm | ✓ | ✓ | | | |
| PostGIS | | ✓ | ✓ | | ✓ |
| pgvector | ✓ | | | | |
| Window functions, gaps and islands | ✓ | ✓ | ✓ | ✓ | ✓ |
| Recursive CTEs | | | | ✓ | |
| `SKIP LOCKED`, advisory locks | | | | ✓ | |
| Row-level security | | | | ✓ | |
| `LISTEN` / `NOTIFY` | | | | ✓ | |
| Generated columns | ✓ | ✓ | ✓ | | ✓ |
| Materialized views | | | | | ✓ |
| `GROUPING SETS` / `ROLLUP` / `CUBE` | ✓ | | | | ✓ |

## What's in each directory

| File | What it is |
|---|---|
| `schema.sql` | tables, constraints, indexes, functions and views, commented to explain each feature |
| `generate-data.sql` | the data generator |
| `queries.sql` | runnable examples for every feature; anything that changes data rolls back |
| `pg_partman-setup.sql` | optional: hand future partitions to pg_partman (partitioned databases only) |
| `README.md` | the story, the tables, and the features with example queries |

## The data

There are no data dumps: each database's `generate-data.sql` builds its data
in SQL, in about 15 to 40 seconds. The generators are **deterministic**:
every "random" choice is a hash of a key string, never `random()` or the
clock. The same scale gives the same rows on any little-endian server
(x86-64, ARM64, ppc64le) and in any time zone, so the results in the
READMEs match what you get. That includes
UUIDv7 values, which are built from the generated timestamps.

`scale` makes a database bigger:

```
psql -d stays -v scale=3 -f generate-data.sql
```

Every database is "as of" 2026-11-01, with history before that date and
some bookings, events or sessions after it. All names, emails
(`example.com` and friends) and companies are made up.

## Requirements

- PostgreSQL 18 or later
- [PostGIS](https://postgis.net/) for stays, ev-charging and micromobility
- [pgvector](https://github.com/pgvector/pgvector) for streaming
- [pg_partman](https://github.com/pgpartman/pg_partman) 5.x, optional, for
  streaming, ev-charging and micromobility

All three are in the PGDG repositories:

| | apt | dnf |
|---|---|---|
| PostGIS | `postgresql-19-postgis-3` | `postgis37_19` |
| pgvector | `postgresql-19-pgvector` | `pgvector_19` |
| pg_partman | `postgresql-19-partman` | `pg_partman_19` |

## Install with Docker or Podman Compose

```
docker compose up --build
```

or

```
podman compose up --build
```

On first start this builds an image from `postgres:19` with the three
extensions and creates all five databases (`streaming`, `stays`,
`ev-charging`, `ticketing`, `micromobility`). The first start takes a few
minutes while the data is generated. Then:

```
docker exec -it pg_fil psql -U postgres -d stays
```

pgAdmin runs on http://localhost:5050 (admin@admin.com / root) with the
server already registered. The PostgreSQL password is `123456`, for local
use only.

## Install into your own server

From the root of this repository, for each database you want (`stays` as
an example):

```
createdb stays
psql -d stays -f stays/schema.sql
psql -d stays -f stays/generate-data.sql
psql -d stays -f stays/queries.sql    # optional: run the examples
```

`scripts/check.sh <database>` does all of that in a scratch database and
fails on the first error. Connection settings come from the usual `PG*`
environment variables:

```
PGHOST=localhost PGUSER=postgres scripts/check.sh ticketing
```

## License

pg_fil is made available under the [PostgreSQL License](LICENSE.txt).
