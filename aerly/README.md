# aerly

Shared trip planning and live flight tracking. This is the schema of
[Aerly](https://github.com/dpage/aerly), Dave Page's app for "who's
already in the air to the conference?", filled with generated data. A
trip gathers flights, trains, hotels, taxis, hire cars, meals, excursions,
meetings and ice cream stops onto one shared timeline. Friends see each
other's trips; the poller follows every flight, records its track and sends
alerts, check-in nudges and departure summaries; trips can subscribe to a
conference's calendar feed.

The data runs from January 2025 to spring 2027 and is "as of"
2026-11-01 00:00 UTC: midnight in Lisbon, two days before the Elephant
Summit 2026 opens there (3 to 6 November). Eleven flights are in the air
at that moment, most of them carrying people flying overnight from the
Americas to Lisbon. Earlier flights have landed, with their delays, gate
changes and the odd cancellation; later trips are booked and waiting.

This database is about **real-world application data**: an existing app's
schema, unchanged, with time zones, privacy rules and history that queries
have to get right.

## The schema is Aerly's

`schema.sql` is Aerly's schema as its 57 migrations leave it (upstream
commit `b703dad`, October 2026): the same 44 tables, columns, constraints,
indexes and function, so the Aerly app itself can be pointed at the
generated data. `pg_dump --schema-only` of a database loaded from this file
and of one migrated by Aerly are identical. Only the order and the comments
are new. Aerly is under the PostgreSQL License, like pg_fil.

## Tables

| Table | What it holds |
|---|---|
| `users`, `user_identities`, `user_emails` | people, their GitHub or Google sign-ins, and their addresses |
| `alert_prefs`, `push_kind_prefs`, `webpush_subscriptions` | how each person wants to be told about things |
| `friendships`, `pending_friend_invites`, `user_auto_shares` | who sees whose trips |
| `trips`, `trip_members`, `trip_passengers`, `trip_tags` | trips, who can see or edit them, who travels on them |
| `plans` | one booking on a trip, of one of ten types |
| `plan_parts` | the timed pieces of a plan (each flight leg, a hotel stay), each instant with its IANA zone |
| `flight_details`, `train_details`, `hotel_details`, ... | one 1:1 detail table per plan type |
| `positions` | ADS-B fixes along each flight, some dead-reckoned over the ocean |
| `plan_visibility`, `plan_visibility_members` | per-plan privacy: hidden from some members, or only for some |
| `plan_passengers`, `plan_alert_optin`, `plan_reminder_optin` | who travels on, follows, or wants reminding of a plan |
| `flight_alerts`, `notifications` | the in-app inboxes |
| `plan_reminder_sent`, `flight_checkin_sent`, `flight_departure_summary_sent` | "send once" bookkeeping for the nudges |
| `trip_feeds`, `trip_feed_events` | subscribed iCalendar feeds and their events |
| `plan_links`, `plan_attachments`, `calendar_tokens`, `pending_shares`, `email_ingests` | links and files, calendar feed tokens, shares to people with no account yet, the forwarded-email log |

Function: `plan_visible_to_member(plan, user)`.

At the default scale there are 2,000 users, about 5,800 trips, 31,000
plans, 12,800 flight legs and 45,000 positions.

## Install

Requires PostgreSQL 18+; no extensions.

```
createdb aerly
psql -d aerly -f schema.sql
psql -d aerly -f generate-data.sql             # about 15 seconds
psql -d aerly -v scale=3 -f generate-data.sql  # or: 3x the users
psql -d aerly -f queries.sql                   # the examples
```

The generator is deterministic, so the same scale always gives the same rows.

## The data

The cities and airports are real (39 of them, with their coordinates and
time zones); the people, airlines, hotels, restaurants and conferences are
made up. Users belong to friend circles that tend to go to the same
conferences, and some live together as couples who holiday together.

Each route has three flights a day at fixed times, so people flying the
same way on the same day often end up on the same flight, and a flight's
delay, gate and fate are shared by everyone on it. Long routes without a
direct flight connect through a hub. About 2% of flights are cancelled a
few hours before departure; the booking is then reissued a day later, and
the new parts point at the ones they replace.

## Who is in the air right now?

```sql
SELECT fd.ident, fd.origin_iata || ' → ' || fd.dest_iata AS route,
       string_agg(u.name, ', ' ORDER BY u.name) AS on_board, p.lat, p.lon, p.altitude_ft
FROM flight_details fd
JOIN plan_parts pp ON pp.id = fd.plan_part_id
JOIN plan_passengers pas ON pas.plan_id = pp.plan_id
JOIN users u ON u.id = pas.user_id
CROSS JOIN LATERAL (
    SELECT * FROM positions pos
    WHERE pos.plan_part_id = fd.plan_part_id
    ORDER BY pos.ts DESC LIMIT 1
) p
WHERE fd.flight_status = 'Enroute'
GROUP BY 1, 2, 4, 5, 6;
```

```
 ident  |   route   |                         on_board                         | ...
--------+-----------+----------------------------------------------------------+
 FA2628 | JFK → LIS | Deniz Yilmaz, Gabriel Eriksson, Maya Schmidt, Mei Nguyen |
 KT3914 | SFO → LIS | Chen Martin, Noah Meyer                                  |
 NJ2277 | GRU → LIS | Gabriel Haddad, Mei Silva                                |
 ...
```

`LATERAL` takes the newest fix of each flight, one probe of the
`(plan_part_id, ts DESC)` index per flight. Over the middle of an ocean
crossing the fix is dead-reckoned (`is_estimated`), and a partial index
(`WHERE is_estimated = false`) serves "last real fix".

## Time zones

Every instant is a `timestamptz`, and the zone it is local to is kept
beside it, with where that zone came from: `confirmed` (the airport),
`inferred` (from the coordinates), `unknown`, or `floating`. A connection
through Dubai, in each airport's own time and in the traveller's:

```sql
SELECT fd.ident,
       to_char(pp.starts_at AT TIME ZONE pp.start_tz, 'DD Mon HH24:MI') AS departs_local,
       to_char(pp.ends_at AT TIME ZONE pp.end_tz, 'DD Mon HH24:MI') AS arrives_local,
       to_char(pp.ends_at AT TIME ZONE u.home_tz, 'DD Mon HH24:MI') AS at_home
FROM plan_parts pp ...
```

```
 ident  | departs_local | arrives_local | at_home
--------+---------------+---------------+--------------
 LU496  | 18 Aug 20:40  | 19 Aug 02:10  | 19 Aug 01:10
 KT1841 | 19 Aug 07:00  | 20 Aug 04:20  | 19 Aug 21:20
```

A **floating** time has no zone: "dinner at 20:00, wherever we are". Its
UTC digits are the wall-clock time, so it is read back with
`AT TIME ZONE 'UTC'`. A CHECK constraint keeps the zone and its source
consistent: `(start_tz = '') = (start_tz_source IN ('unknown', 'floating'))`.

Trip dates (`starts_on`, `ends_on`) are plain `date`s: calendar days, not
instants.

## Constraints and indexes worth a look

```sql
-- a friendship is stored once, lowest id first
CHECK (user_low < user_high),
CHECK (requested_by = user_low OR requested_by = user_high),
CHECK (status <> 'pending' OR invited_email IS NOT NULL)

-- unique whatever the case, and one primary address per user
CREATE UNIQUE INDEX users_username_lower_idx ON users (lower(username));
CREATE UNIQUE INDEX user_emails_one_primary ON user_emails (user_id) WHERE is_primary;

-- TripIt re-imports dedupe only when there is an id
CREATE UNIQUE INDEX trips_creator_tripit_id_uidx ON trips (created_by, tripit_id) WHERE tripit_id <> '';

-- the unread badge counts only unread rows
CREATE INDEX flight_alerts_user_unread_idx ON flight_alerts (user_id) WHERE read_at IS NULL;
```

## Rebookings, with a recursive CTE

A rebooked part points at the part it replaces (`supersedes_id`). Walking
the chain shows what happened to a booking:

```
 hops |                                    history
------+-------------------------------------------------------------------------------
    2 | HB2738 13 Feb Cancelled  ⇒  HB2738 14 Feb Arrived
    3 | FA1280 30 Mar Cancelled  ⇒  FA1280 31 Mar Cancelled  ⇒  FA1280 01 Apr Arrived
```

## Privacy as a function

A plan can be `hidden_from` some trip members (the surprise dinner) or
`only_visible_to` some. `plan_visible_to_member(plan, user)` is the rule,
and queries call it like any other function:

```sql
SELECT pl.title, u.username, plan_visible_to_member(pl.id, u.id) AS visible
FROM plan_visibility pv JOIN plans pl ON pl.id = pv.plan_id ...
```

## More in queries.sql

- who lands in Lisbon for the summit, grouped by shared flight
- mutual friends ("people you may know")
- great-circle distance in plain SQL: who flew furthest in 2025
- delay percentiles per airline with `percentile_cont()`
- real and dead-reckoned stretches of a track, as gaps and islands
- a whole trip's timeline across all the detail tables
- the ice cream league, with `mode()`
- the conference schedule from a subscribed calendar feed
- how the forwarded-email parser did
