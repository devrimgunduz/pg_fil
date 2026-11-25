# ticketing

Event ticketing for five venues: a West End-style theatre, a concert hall
in Vienna, an arena in Rotterdam, a comedy club in Prague and a football
stadium in Manchester. Each venue has a nested seating plan. Every event
gets a seat inventory that buyers hold for a few minutes while they pay.
Tickets can be transferred or resold (capped at 110% of face value) and are
scanned at the gates. Events run from July 2025 to March 2027 and the data
is "as of" 2026-11-01. Past events are completed; upcoming ones are on sale,
with a few seats held by buyers at that moment, or not on sale yet.

This database is about **correctness under concurrency**: selling every
seat once, to one buyer, while thousands of buyers click at the same moment.

## Tables

| Table | What it holds |
|---|---|
| `venue` | 5 venues with time zone and currency |
| `section` | the seating plan as a tree: level > stand > section |
| `seat` | about 14,000 seats with row and number |
| `artist` | bands, shows, comedians and sports teams |
| `event` | 272 events; `during` runs from doors open to close |
| `price_tier` | Premium, A, B and C prices per event |
| `event_seat` | the inventory: one row per seat per event, `available`, `held` or `sold` |
| `customer`, `orders`, `ticket` | buyers, orders and tickets with UUIDv7 barcodes |
| `transfer`, `resale_listing` | tickets changing hands |
| `scan` | gate scans: admitted, duplicate or invalid |

Functions and views: `hold_seats(...)`, `buy_held_seats(...)`,
`release_expired_holds(...)`, `section_path`, `event_sales`.

## Install

Requires PostgreSQL 18+ (btree_gist ships with it).

```
createdb ticketing
psql -d ticketing -f schema.sql
psql -d ticketing -f generate-data.sql             # about 20 seconds
psql -d ticketing -v scale=3 -f generate-data.sql  # or: 3x the customers
psql -d ticketing -f queries.sql                   # the single-session examples
```

`schema.sql` creates a `fil_customer` role (NOLOGIN) for the
row-level security example. Roles are shared by all databases in a cluster,
so it is only created if it doesn't exist yet.

The generator is deterministic, so the same scale always gives the same rows.

## SKIP LOCKED: many buyers, no waiting

`hold_seats()` picks the best available seats in a tier and locks them:

```sql
SELECT es.event_id, es.seat_id
FROM event_seat es JOIN seat s USING (seat_id)
WHERE es.event_id = p_event_id AND es.tier_id = p_tier_id
  AND (es.status = 'available' OR (es.status = 'held' AND es.hold_expires_at < p_now))
ORDER BY s.section_id, s.row_label, s.seat_no
LIMIT p_count
FOR UPDATE OF es SKIP LOCKED
```

Without `SKIP LOCKED`, the second buyer would wait for the first to commit
and then find those seats taken. With it, the second buyer skips the locked
rows and gets the next best seats at once. Try it in two terminals (event
211, tier 842 are on sale in the generated data):

```
-- terminal 1                                  -- terminal 2
BEGIN;
SELECT seat_id FROM hold_seats(211, 842, 4, 101);
--  3713, 3714, 3722, 3723
                                               BEGIN;
                                               SELECT seat_id FROM hold_seats(211, 842, 4, 102);
                                               --  3724, 3725, 3726, 3727  (no waiting)
COMMIT;                                        COMMIT;
```

Then `buy_held_seats(event, customer)` turns a hold into an order and
tickets.

## Advisory locks

Expired holds have to go back on sale. Every app server may run the sweeper,
but only one should work on an event at a time. `release_expired_holds()`
takes `pg_try_advisory_xact_lock()` on the event. Anyone who doesn't get
the lock returns `-1` at once instead of queueing on the same rows:

```
-- terminal 1                                  -- terminal 2
BEGIN;
SELECT release_expired_holds(214, '2026-11-01');
--  6
                                               SELECT release_expired_holds(214, '2026-11-01');
                                               --  -1
COMMIT;
```

## Constraints that can't be bypassed

```sql
-- a seat has at most one valid ticket per event; refunded tickets don't count
CREATE UNIQUE INDEX ticket_one_per_seat ON ticket (event_id, seat_id) WHERE status = 'valid';

-- a venue can't host two events at once
EXCLUDE USING gist (venue_id WITH =, during WITH &&) WHERE (status <> 'cancelled')
```

Resale prices are capped at 110% of the ticket's face value. That check
needs another table, which a `CHECK` constraint can't read, so a
**constraint trigger** (`CREATE CONSTRAINT TRIGGER resale_price_cap`)
enforces it.

## LISTEN / NOTIFY

Every new ticket fires `pg_notify('ticket_sold', ...)` with a JSON payload.
Notifications are delivered on commit, and never if the transaction rolls
back:

```
-- terminal 1                         -- terminal 2
LISTEN ticket_sold;
                                      BEGIN;
                                      SELECT hold_seats(211, 842, 2, 7);
                                      SELECT buy_held_seats(211, 7);
                                      COMMIT;
-- (at its next command, psql prints something like:)
Asynchronous notification "ticket_sold" with payload
"{"event_id" : 211, "seat_id" : 3713, "ticket_id" : 369623, "price" : 54.00}" received ...
```

## Row-level security

The customer app connects as `fil_customer` and sets `app.customer_id`
per request. The policies then hide everyone else's tickets, orders and
transfers:

```sql
BEGIN;
SET LOCAL ROLE fil_customer;
SET LOCAL app.customer_id = '42';
SELECT count(*) FROM ticket;   -- 41, not 369622
ROLLBACK;
```

`fil_customer` can read `event_seat` to see which seats are free, but the
grant lists its columns and leaves out `held_by`, so it can't see who holds
a seat. `SELECT *` on it fails; name the columns instead.

## Recursive CTEs

The seating plan is a tree. The `section_path` view walks it from the
levels down to build names like `Lower Tier > North > 102`, and
`queries.sql` rolls seat counts up the tree:

```sql
WITH RECURSIVE tree AS (
    SELECT section_id, name, 1 AS depth, ARRAY[section_id] AS path
    FROM section WHERE parent_id IS NULL AND venue_id = 3
    UNION ALL
    SELECT c.section_id, c.name, t.depth + 1, t.path || c.section_id
    FROM section c JOIN tree t ON c.parent_id = t.section_id
)
SELECT repeat('    ', depth - 1) || name,
       (SELECT count(*) FROM tree d JOIN seat s USING (section_id)
        WHERE t.section_id = ANY (d.path)) AS seats
FROM tree t ORDER BY path;
```

## Analytics

`queries.sql` also has:
- "best available": runs of 4+ adjacent free seats, as gaps and islands
- sales curves with running totals
- gate scans in 15-minute buckets with `date_bin()`
- no-show rates
- the resale market
- the most loyal customers with `mode()` and `string_agg(DISTINCT ...)`
