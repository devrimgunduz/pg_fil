--
-- pg_fil: aerly -- example queries
--
-- Every query here runs against the generated data. "Now" is the data's
-- as-of instant, 2026-11-01 00:00 UTC; it is passed in explicitly rather
-- than using now(). Statements that change data run inside transactions
-- that roll back, so the file can be run any number of times:
--   psql -d aerly -f queries.sql
--

\set now '''2026-11-01 00:00:00+00'''

\echo '== 1. Who is in the air right now? The last fix of every flight that is en route'
-- LATERAL picks each flight's newest position; the (plan_part_id, ts DESC)
-- index makes that one index probe per flight.
SELECT fd.ident, fd.origin_iata || ' → ' || fd.dest_iata AS route,
       string_agg(u.name, ', ' ORDER BY u.name) AS on_board,
       round(p.lat::numeric, 2) AS lat, round(p.lon::numeric, 2) AS lon,
       p.altitude_ft, p.groundspeed_kt AS kt, p.is_estimated AS estimated,
       to_char(fd.estimated_in AT TIME ZONE pp.end_tz, 'Dy HH24:MI') AS lands_local
FROM flight_details fd
JOIN plan_parts pp ON pp.id = fd.plan_part_id
JOIN plan_passengers pas ON pas.plan_id = pp.plan_id
JOIN users u ON u.id = pas.user_id
CROSS JOIN LATERAL (
    SELECT * FROM positions pos
    WHERE pos.plan_part_id = fd.plan_part_id
    ORDER BY pos.ts DESC
    LIMIT 1
) p
WHERE fd.flight_status = 'Enroute'
GROUP BY fd.ident, fd.origin_iata, fd.dest_iata, p.lat, p.lon, p.altitude_ft, p.groundspeed_kt,
         p.is_estimated, fd.estimated_in, pp.end_tz
ORDER BY fd.estimated_in;

\echo '== 2. Who is coming to the Elephant Summit 2026, and when do they land in Lisbon (local time)?'
-- Each attendee's last flight into LIS. Several people often share a
-- flight, because each route has a few flights a day.
SELECT to_char(arr AT TIME ZONE 'Europe/Lisbon', 'Dy DD Mon HH24:MI') AS lands, ident, from_city,
       count(*) AS people, string_agg(name, ', ' ORDER BY name) FILTER (WHERE rn <= 3) || CASE WHEN count(*) > 3 THEN ', ...' ELSE '' END AS who
FROM (
    SELECT DISTINCT ON (t.id) t.id, u.name, fd.ident, pp.start_label AS from_city,
           coalesce(fd.actual_in, fd.estimated_in, fd.scheduled_in) AS arr,
           row_number() OVER (PARTITION BY fd.ident, fd.scheduled_in ORDER BY u.name) AS rn
    FROM trips t
    JOIN users u ON u.id = t.created_by
    JOIN plans pl ON pl.trip_id = t.id AND pl.type = 'flight'
    JOIN plan_parts pp ON pp.plan_id = pl.id AND pp.status <> 'cancelled'
    JOIN flight_details fd ON fd.plan_part_id = pp.id
    WHERE t.name = 'Elephant Summit 2026' AND fd.dest_iata = 'LIS'
    ORDER BY t.id, fd.scheduled_in
) a
GROUP BY arr, ident, from_city
ORDER BY arr
LIMIT 15;

\echo '== 3. Time zones: one connection, in each airport''s own time and in the traveller''s'
-- Instants are timestamptz; the zone each one is local to sits beside it.
-- AT TIME ZONE turns an instant into wall-clock time in any zone.
SELECT pp.seq, fd.ident, fd.origin_iata || ' → ' || fd.dest_iata AS route,
       to_char(pp.starts_at AT TIME ZONE pp.start_tz, 'DD Mon HH24:MI') || ' ' || pp.start_tz AS departs_local,
       to_char(pp.ends_at AT TIME ZONE pp.end_tz, 'DD Mon HH24:MI') || ' ' || pp.end_tz AS arrives_local,
       to_char(pp.ends_at AT TIME ZONE u.home_tz, 'DD Mon HH24:MI') AS arrives_at_home_clock,
       pp.ends_at - pp.starts_at AS block_time
FROM plan_parts pp
JOIN flight_details fd ON fd.plan_part_id = pp.id
JOIN plans pl ON pl.id = pp.plan_id
JOIN users u ON u.id = pl.created_by
WHERE pp.plan_id = (SELECT pp2.plan_id FROM plan_parts pp2
                    JOIN flight_details f2 ON f2.plan_part_id = pp2.id
                    WHERE pp2.seq = 1 AND f2.origin_iata = 'DXB' AND f2.dest_iata = 'SYD'
                    ORDER BY pp2.id LIMIT 1)
ORDER BY pp.seq;

\echo '== 4. Floating times: "dinner at 20:00, wherever we are"'
-- A floating part has no zone; its UTC digits are the local wall-clock
-- time. Read it back with AT TIME ZONE 'UTC', never with a real zone.
SELECT pl.title, pp.start_tz_source,
       CASE WHEN pp.start_tz_source = 'floating' THEN to_char(pp.starts_at AT TIME ZONE 'UTC', 'DD Mon HH24:MI') || ' (local)'
            ELSE to_char(pp.starts_at AT TIME ZONE pp.start_tz, 'DD Mon HH24:MI') || ' ' || pp.start_tz END AS starts
FROM plan_parts pp JOIN plans pl ON pl.id = pp.plan_id
WHERE pl.trip_id = (SELECT pl2.trip_id FROM plans pl2 JOIN plan_parts p2 ON p2.plan_id = pl2.id
                    WHERE p2.start_tz_source = 'floating' ORDER BY pl2.trip_id LIMIT 1)
  AND pl.type = 'dining'
ORDER BY pp.starts_at;

SELECT start_tz_source, count(*) FROM plan_parts GROUP BY 1 ORDER BY 2 DESC;

\echo '== 5. Recursive CTE: rebooking chains after cancellations'
-- A rebooked part points at the part it replaces (supersedes_id). Walk
-- from each original part to the end of its chain. When one flight of a
-- connection is cancelled the whole booking is reissued, so a flight that
-- did operate can be superseded too.
WITH RECURSIVE chain AS (
    SELECT pp.id AS first_id, pp.id, 1 AS hops, ARRAY[fd.ident || ' ' || to_char(fd.scheduled_out, 'DD Mon') || ' ' || fd.flight_status] AS history
    FROM plan_parts pp JOIN flight_details fd ON fd.plan_part_id = pp.id
    WHERE pp.supersedes_id IS NULL
      AND EXISTS (SELECT FROM plan_parts n WHERE n.supersedes_id = pp.id)
    UNION ALL
    SELECT c.first_id, n.id, c.hops + 1, c.history || (fd.ident || ' ' || to_char(fd.scheduled_out, 'DD Mon') || ' ' || fd.flight_status)
    FROM chain c
    JOIN plan_parts n ON n.supersedes_id = c.id
    JOIN flight_details fd ON fd.plan_part_id = n.id
)
SELECT DISTINCT ON (first_id) first_id, hops, array_to_string(history, '  ⇒  ') AS history
FROM chain
ORDER BY first_id, hops DESC
LIMIT 8;

\echo '== 6. Friendships are stored once: (low id, high id)'
-- So "my friends" reads both columns. The CHECK (user_low < user_high)
-- rejects the reversed pair.
SELECT u.username, count(*) AS friends
FROM (SELECT user_low AS uid FROM friendships WHERE status = 'accepted'
      UNION ALL
      SELECT user_high FROM friendships WHERE status = 'accepted') f
JOIN users u ON u.id = f.uid
GROUP BY u.username
ORDER BY friends DESC, u.username
LIMIT 5;

BEGIN;
SELECT user_low, user_high FROM friendships ORDER BY 1, 2 LIMIT 1 \gset
\set ON_ERROR_STOP off
INSERT INTO friendships (user_low, user_high, status, requested_by)
VALUES (:user_high, :user_low, 'accepted', :user_low);
\set ON_ERROR_STOP on
ROLLBACK;

\echo '== 7. Mutual friends of two people who are not friends yet ("people you may know")'
WITH f AS (
    SELECT user_low AS a, user_high AS b FROM friendships WHERE status = 'accepted'
    UNION ALL
    SELECT user_high, user_low FROM friendships WHERE status = 'accepted'
)
SELECT ua.username AS person, ub.username AS may_know, count(*) AS mutual_friends
FROM f f1
JOIN f f2 ON f2.a = f1.b AND f2.b <> f1.a
JOIN users ua ON ua.id = f1.a
JOIN users ub ON ub.id = f2.b
WHERE f1.a = 1
  AND NOT EXISTS (SELECT FROM friendships x
                  WHERE x.user_low = least(f1.a, f2.b) AND x.user_high = greatest(f1.a, f2.b))
GROUP BY ua.username, ub.username
ORDER BY mutual_friends DESC, may_know
LIMIT 5;

\echo '== 8. Expression and partial unique indexes'
-- Usernames and email addresses are unique whatever their case, and a
-- user has at most one primary address.
EXPLAIN (COSTS OFF) SELECT id FROM users WHERE lower(username) = lower('AdaK');

BEGIN;
\set ON_ERROR_STOP off
INSERT INTO users (username) SELECT upper(username) FROM users WHERE id = 1;
\set ON_ERROR_STOP on
ROLLBACK;

BEGIN;
\set ON_ERROR_STOP off
INSERT INTO user_emails (user_id, address, is_primary) VALUES (1, 'second.primary@example.com', true);
\set ON_ERROR_STOP on
ROLLBACK;

\echo '== 9. Per-plan privacy: a surprise dinner hidden from the partner'
-- plan_visible_to_member() is the rule as Aerly applies it to trip members
-- and passengers.
SELECT t.name AS trip, pl.title, pv.mode, u.username AS member,
       plan_visible_to_member(pl.id, u.id) AS visible
FROM plan_visibility pv
JOIN plans pl ON pl.id = pv.plan_id
JOIN trips t ON t.id = pl.trip_id
JOIN trip_passengers tp ON tp.trip_id = t.id
JOIN users u ON u.id = tp.user_id
WHERE pv.mode = 'hidden_from'
ORDER BY pl.id
LIMIT 5;

\echo '== 10. What a member sees: the plans of a shared trip, with hidden ones left out'
SELECT m.user_id, count(*) AS plans_on_trip,
       count(*) FILTER (WHERE plan_visible_to_member(pl.id, m.user_id)) AS visible_to_them
FROM trip_members m
JOIN plans pl ON pl.trip_id = m.trip_id
WHERE m.role <> 'owner'
  AND m.trip_id IN (SELECT pl2.trip_id FROM plans pl2 JOIN plan_visibility v ON v.plan_id = pl2.id AND v.mode = 'only_visible_to')
GROUP BY m.trip_id, m.user_id
ORDER BY m.trip_id, m.user_id
LIMIT 6;

\echo '== 11. Great-circle distance in plain SQL: who flew furthest in 2025?'
-- Haversine on the airports' coordinates kept on each part; no PostGIS
-- needed. rank() leaves gaps on ties, dense_rank() does not.
SELECT rank() OVER (ORDER BY km DESC) AS rank, username, flights, round(km::numeric) AS km,
       round((km / 40075)::numeric, 2) AS times_round_the_earth
FROM (
    SELECT u.username, count(*) AS flights,
           sum(2 * 6371 * asin(sqrt(power(sin(radians(pp.end_lat - pp.start_lat) / 2), 2)
                + cos(radians(pp.start_lat)) * cos(radians(pp.end_lat))
                  * power(sin(radians(pp.end_lon - pp.start_lon) / 2), 2)))) AS km
    FROM plan_passengers pas
    JOIN users u ON u.id = pas.user_id
    JOIN plan_parts pp ON pp.plan_id = pas.plan_id
    JOIN flight_details fd ON fd.plan_part_id = pp.id
    WHERE fd.flight_status IN ('Arrived', 'Diverted')
      AND fd.actual_out >= '2025-01-01' AND fd.actual_out < '2026-01-01'
    GROUP BY u.username
) s
ORDER BY rank, username
LIMIT 10;

\echo '== 12. Punctuality by airline: delay percentiles and on-time share'
-- One row per flight (several travellers can share one), then ordered-set
-- aggregates.
SELECT airline, count(*) AS flights,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY delay_min)::numeric, 1) AS median_delay,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY delay_min)::numeric, 1) AS p90_delay,
       round(100.0 * count(*) FILTER (WHERE delay_min <= 15) / count(*), 1) AS pct_on_time,
       count(*) FILTER (WHERE status = 'Cancelled') AS cancelled
FROM (
    SELECT DISTINCT ON (ident, scheduled_out) left(ident, 2) AS airline, flight_status AS status,
           extract(epoch FROM coalesce(actual_out, scheduled_out) - scheduled_out) / 60 AS delay_min
    FROM flight_details
    WHERE scheduled_out < :now
) f
GROUP BY airline
ORDER BY pct_on_time DESC;

\echo '== 13. A flight track: real and dead-reckoned fixes, as islands'
-- Gaps and islands: number the fixes, and every switch between real and
-- estimated starts a new island.
SELECT is_estimated, min(ts) AS from_ts, max(ts) AS to_ts, count(*) AS fixes,
       max(altitude_ft) AS max_alt_ft
FROM (
    SELECT ts, is_estimated, altitude_ft,
           row_number() OVER (ORDER BY ts) - row_number() OVER (PARTITION BY is_estimated ORDER BY ts) AS island
    FROM positions
    WHERE plan_part_id = (SELECT plan_part_id FROM positions WHERE is_estimated ORDER BY plan_part_id LIMIT 1)
) s
GROUP BY is_estimated, island
ORDER BY from_ts;

\echo '== 14. Unread inbox badges (served by partial indexes WHERE read_at IS NULL)'
SELECT u.username,
       (SELECT count(*) FROM flight_alerts a WHERE a.user_id = u.id AND a.read_at IS NULL) AS unread_alerts,
       (SELECT count(*) FROM notifications n WHERE n.user_id = u.id AND n.read_at IS NULL) AS unread_notices
FROM users u
ORDER BY unread_alerts DESC, u.username
LIMIT 5;

EXPLAIN (COSTS OFF) SELECT count(*) FROM flight_alerts WHERE user_id = 42 AND read_at IS NULL;

\echo '== 15. What kinds of alerts go out, by month'
SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month,
       count(*) FILTER (WHERE kind = 'delayed') AS delayed,
       count(*) FILTER (WHERE kind = 'gate') AS gate,
       count(*) FILTER (WHERE kind = 'cancelled') AS cancelled,
       count(*) FILTER (WHERE kind = 'checkin') AS checkin,
       count(*) FILTER (WHERE kind = 'departure') AS departure,
       count(*) FILTER (WHERE kind = 'reminder') AS reminder
FROM flight_alerts
WHERE created_at >= '2026-05-01'
GROUP BY 1
ORDER BY 1;

\echo '== 16. A trip''s timeline, every kind of plan, in local time'
-- The 1:1 detail tables join on the part id; only the one for the plan's
-- type has a row.
SELECT pl.type, pl.title,
       to_char(pp.starts_at AT TIME ZONE coalesce(nullif(pp.start_tz, ''), 'UTC'), 'Dy DD Mon HH24:MI') AS starts,
       coalesce(fd.ident || ' ' || fd.flight_status, td.service_no, hd.room_type, gd.provider,
                dd.party_size || ' people', md.organiser, vd.category, '') AS detail
FROM plans pl
JOIN plan_parts pp ON pp.plan_id = pl.id AND pp.status <> 'cancelled'
LEFT JOIN flight_details fd ON fd.plan_part_id = pp.id
LEFT JOIN train_details td ON td.plan_part_id = pp.id
LEFT JOIN hotel_details hd ON hd.plan_part_id = pp.id
LEFT JOIN ground_details gd ON gd.plan_part_id = pp.id
LEFT JOIN dining_details dd ON dd.plan_part_id = pp.id
LEFT JOIN meeting_details md ON md.plan_part_id = pp.id
LEFT JOIN vehicle_hire_details vd ON vd.plan_part_id = pp.id
WHERE pl.trip_id = (SELECT t.id FROM trips t
                    WHERE EXISTS (SELECT FROM plans p WHERE p.trip_id = t.id AND p.type = 'vehicle_hire')
                      AND EXISTS (SELECT FROM plans p WHERE p.trip_id = t.id AND p.type = 'dining')
                      AND EXISTS (SELECT FROM plans p WHERE p.trip_id = t.id AND p.type = 'ground')
                    ORDER BY t.id LIMIT 1)
ORDER BY pp.starts_at, pp.seq;

\echo '== 17. Ice cream league: best-rated cities (rated visits only)'
SELECT split_part(t.destination, ',', 1) AS city, count(*) AS visits,
       round(avg(ic.rating), 2) AS avg_rating,
       mode() WITHIN GROUP (ORDER BY ic.what_ordered) AS favourite
FROM ice_cream_details ic
JOIN plan_parts pp ON pp.id = ic.plan_part_id
JOIN plans pl ON pl.id = pp.plan_id
JOIN trips t ON t.id = pl.trip_id
WHERE ic.rating > 0 AND ic.what_ordered <> ''
GROUP BY 1
HAVING count(*) >= 5
ORDER BY avg_rating DESC, visits DESC
LIMIT 8;

\echo '== 18. Trip tags: prefix search with text_pattern_ops'
SELECT label_display, count(*) FROM trip_tags WHERE label_norm LIKE 'w%' GROUP BY 1 ORDER BY 2 DESC;

\echo '== 19. Calendar feeds: the first talks of the Elephant Summit, for one subscribed trip'
SELECT to_char(e.starts_at AT TIME ZONE e.start_tz, 'Dy HH24:MI') AS local_time, e.summary, e.location
FROM trip_feed_events e
JOIN trip_feeds f ON f.id = e.feed_id
WHERE f.id = (SELECT min(id) FROM trip_feeds WHERE name = 'Elephant Summit 2026 schedule')
  AND NOT e.all_day
ORDER BY e.starts_at
LIMIT 5;

\echo '== 20. Forwarded booking emails: how the parser did'
SELECT status, count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
       count(*) FILTER (WHERE NOT dkim_pass) AS dkim_failed
FROM email_ingests
GROUP BY status
ORDER BY 2 DESC;
