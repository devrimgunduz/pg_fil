# Changelog

## 2.0

This release fixes integrity, security and partitioning bugs reported in
issue #2 and PR #3. Several schemas changed, so **drop and recreate the
affected databases** (streaming, stays, ticketing, ev-charging,
micromobility) and load `schema.sql` and `generate-data.sql` again; there
are no migration scripts.

### Security

- **Docker Compose:** PostgreSQL and pgAdmin are now published on
  `127.0.0.1` only. Before, both were reachable from every interface of the
  host with their well-known default credentials. pgAdmin now also waits for
  the database container (`depends_on`). (e3f8b35)
- **ticketing:** `fil_customer` could read every row of `transfer`.
  `transfer` now has row-level security with a `transfer_party` policy, so
  customers see only tickets they sent or received. (47cbbe3)
- **ticketing:** `event_seat.held_by` showed which customer held which
  seats. `event_seat` is now granted column by column, leaving out
  `held_by`. (47cbbe3)

### Bug fixes

- **ticketing:** `buy_held_seats()` marked every held seat as sold,
  expired holds included, but created tickets only for the unexpired ones,
  so seats could end up sold without a ticket and never return to sale. The
  seats are now locked up front with `FOR UPDATE`, and the same seat list is
  used for the order, the tickets and the update, which also stops a
  concurrent `hold_seats()` from taking one over. (fadcbfb, PR #3)
- **ticketing:** the `ticket_holder` and `order_buyer` policies failed with
  `invalid input syntax for type integer` on a pooled connection where
  `app.customer_id` had been set with `SET LOCAL` earlier. An empty setting
  now means "no customer" and returns no rows. (fadcbfb, PR #3)
- **streaming, ev-charging, micromobility:** without pg_partman, any row
  dated 2027-01-01 or later failed with `no partition of relation ... found
  for row`. `schema.sql` now creates monthly partitions through 2027-12 and
  a default partition for anything later. (77ab6cc)
- **streaming, ev-charging, micromobility:** `pg_partman-setup.sql` failed
  in sessions whose time zone wasn't UTC, because pg_partman's first
  partition overlapped the UTC partitions from `schema.sql`. The setup
  scripts now `SET TIME ZONE 'UTC'`, start at 2028-01 and keep the default
  partition; the cron example uses `PGTZ=UTC`. (77ab6cc)
- **streaming:** `viewing_session` and `watch_progress` accepted an episode
  from a different title. `episode` now carries its season's `title_id`
  (enforced by a composite foreign key to `season`), and both tables
  reference `episode (episode_id, title_id)`. (946b991)
- **streaming:** a subscription's `region_code` could differ from its
  account's, e.g. a US account paying AU prices. A composite foreign key to
  `account (account_id, region_code)` now ties them together. (946b991)
- **streaming:** `record_session()` failed with a NOT NULL violation on
  `watch_progress.finished` for a series with no episodes yet; it now
  records `false`. (946b991)
- **stays:** an availability block could be added over a confirmed booking.
  A new trigger, `block_check_not_booked`, rejects it. Both the booking and
  the block trigger now lock the listing row (`FOR NO KEY UPDATE`), so a
  booking and a block for the same nights inserted concurrently can no
  longer both commit. `queries.sql` and the README show the new check.
  (142cfa6)

### Docker image

- The image now preloads `pg_partman_bgw` and runs partition maintenance
  hourly in the streaming, ev-charging and micromobility databases, as
  `postgres`. Before, nothing created new partitions. (77ab6cc)

### Documentation

- The pg_partman setup scripts name the PostgreSQL 19 packages
  (`postgresql-19-partman` on apt, `pg_partman_19` on dnf). (8ca4a73)
- The data generators are described as deterministic on any
  **little-endian** server (x86-64, ARM64, ppc64le): `hashtextextended()`
  depends on byte order, so big-endian platforms such as s390x produce
  different rows. (89e4522)
- micromobility: `pricing_rule` is documented as allowing *at most* one
  price per day, not exactly one. (cc8b1bf)
