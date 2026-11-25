--
-- pg_fil: micromobility -- sample data generator
--
-- Run after schema.sql, into an empty database:
--   psql -d micromobility -f generate-data.sql
--   psql -d micromobility -v scale=3 -f generate-data.sql     -- 3x the fleet
--
-- The output is deterministic: every "random" choice is a hash of a key
-- string (see gen.r below), never random() or the clock, so the same scale
-- always gives the same rows on any little-endian server (x86-64, ARM64,
-- ppc64le), in any time zone.
--
-- The data covers July to October 2026 and is "as of" 2026-11-01.
--

\if :{?scale}
\else
\set scale 1
\endif

SET client_min_messages = warning;
SET search_path = public;
-- Date arithmetic on timestamptz (adding days, casting to date) follows the
-- session time zone; pin it so the output doesn't depend on the client's.
SET TimeZone = 'UTC';

DO $$
BEGIN
    IF EXISTS (SELECT FROM city) THEN
        RAISE EXCEPTION 'generate-data.sql must run against an empty schema';
    END IF;
END
$$;

--
-- Generator helpers, dropped again at the end.
--
DROP SCHEMA IF EXISTS gen CASCADE;
CREATE SCHEMA gen;

-- gen.r(key): a uniform number in [0, 1), derived from key by hashing.
CREATE FUNCTION gen.r(k text) RETURNS float8
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT (hashtextextended(k, 0) & 9007199254740991)::float8 / 9007199254740992 $$;

-- gen.ri(key, lo, hi): a uniform integer in [lo, hi].
CREATE FUNCTION gen.ri(k text, lo bigint, hi bigint) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT lo + floor(gen.r(k) * (hi - lo + 1))::bigint $$;

-- gen.pick(key, array): one element of the array.
CREATE FUNCTION gen.pick(k text, a anyarray) RETURNS anyelement
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT a[array_lower(a, 1) + floor(gen.r(k) * cardinality(a))::int] $$;

-- gen.normal(key): a standard normal deviate (Box-Muller).
CREATE FUNCTION gen.normal(k text) RETURNS float8
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT sqrt(-2 * ln(1 - gen.r(k || '#u1'))) * cos(2 * pi() * gen.r(k || '#u2')) $$;

CREATE FUNCTION gen.first_names() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT ARRAY[
    'Ada','Aiko','Alejandro','Amara','Ana','Andrei','Anika','Arjun','Astrid','Ayse',
    'Bruno','Carmen','Chen','Chloe','Daniel','Deniz','Diego','Elif','Emeka','Emma',
    'Fatima','Felix','Freya','Gabriel','Hana','Hugo','Ines','Isaac','Ivan','Jamal',
    'Jana','Javier','Kai','Kemal','Lars','Layla','Leon','Lina','Lucas','Maya',
    'Mateo','Mei','Mila','Nadia','Noah','Nora','Olu','Omar','Priya','Rafael',
    'Rosa','Sami','Sara','Sofia','Tariq','Theo','Valentina','Wei','Yara','Zoe'] $$;

CREATE FUNCTION gen.last_names() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT ARRAY[
    'Adeyemi','Almeida','Andersen','Bauer','Becker','Brown','Castillo','Chen','Costa','Demir',
    'Dubois','Eriksson','Fernandes','Fischer','Garcia','Gunduz','Haddad','Hansen','Ibrahim','Ito',
    'Jansen','Kaya','Khan','Kim','Kowalski','Larsen','Lee','Lopez','Martin','Meyer',
    'Moreau','Nakamura','Nguyen','Novak','Okafor','Olsen','Park','Patel','Perez','Petrov',
    'Rossi','Santos','Schmidt','Silva','Singh','Smith','Tanaka','Vargas','Wang','Yilmaz'] $$;

-- gen.person(key): a full name.
CREATE FUNCTION gen.person(k text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT gen.pick(k || '#first', gen.first_names()) || ' ' || gen.pick(k || '#last', gen.last_names()) $$;

-- gen.email(name, n, domain): a unique address on a reserved example domain.
CREATE FUNCTION gen.email(name text, n bigint, domain text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT lower(replace(name, ' ', '.')) || '.' || n || '@' || domain $$;

-- gen.ts(date, key): a UTC timestamp at a random time of day on date.
CREATE FUNCTION gen.ts(d date, k text) RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT (d + make_interval(secs => gen.ri(k, 7 * 3600, 23 * 3600))) AT TIME ZONE 'UTC' $$;

-- gen.uuid7(ts, key): a version 7 UUID for timestamp ts, whose "random"
-- bits come from hashing key, so it is reproducible.
CREATE FUNCTION gen.uuid7(ts timestamptz, k text) RETURNS uuid
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
SELECT (lpad(to_hex(floor(extract(epoch FROM ts) * 1000)::bigint), 12, '0')
        || '7' || substr(h, 1, 3)
        || to_hex(8 + (('x' || substr(h, 4, 1))::bit(4)::int & 3)) || substr(h, 5, 3)
        || substr(h, 8, 12))::uuid
FROM md5(k) AS h
$$;

CREATE FUNCTION gen.as_of() RETURNS timestamptz
LANGUAGE sql IMMUTABLE AS $$ SELECT timestamptz '2026-11-01 00:00:00+00' $$;

-- gen.near(point, max_m, key): a point uniformly within max_m metres.
CREATE FUNCTION gen.near(p geometry, max_m float8, k text) RETURNS geometry
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT ST_Project(p::geography, max_m * sqrt(gen.r(k || '#d')), 2 * pi() * gen.r(k || '#a'))::geometry $$;

-- gen.circle(point, radius_m): a polygon approximating a circle.
CREATE FUNCTION gen.circle(p geometry, radius_m float8) RETURNS geometry
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT ST_Buffer(p::geography, radius_m, 'quad_segs=8')::geometry $$;

--
-- Cities, zones and stations
--
INSERT INTO city (city_id, name, country_code, timezone, currency, centre) VALUES
    (1, 'Amsterdam', 'NL', 'Europe/Amsterdam', 'EUR', ST_SetSRID(ST_MakePoint(4.8952, 52.3702), 4326)),
    (2, 'Barcelona', 'ES', 'Europe/Madrid', 'EUR', ST_SetSRID(ST_MakePoint(2.1734, 41.3851), 4326)),
    (3, 'Berlin', 'DE', 'Europe/Berlin', 'EUR', ST_SetSRID(ST_MakePoint(13.4050, 52.5200), 4326));

INSERT INTO zone (city_id, kind, name, area, speed_limit_kmh)
SELECT city_id, kind, name, area, speed FROM (
    SELECT c.city_id, 'service_area'::zone_kind AS kind, c.name || ' service area' AS name,
           gen.circle(c.centre, 5500) AS area, NULL::smallint AS speed, 0 AS n
    FROM city c
    UNION ALL
    SELECT c.city_id, 'no_parking', 'No parking: ' || gen.pick('np:' || c.city_id || ':' || n,
               ARRAY['Station forecourt', 'Market square', 'Hospital entrance', 'Bridge', 'Museum steps',
                     'School gate', 'Bus terminal', 'Shopping street', 'Church square', 'Ferry pier']) || ' ' || n,
           gen.circle(gen.near(c.centre, 3500, 'npz:' || c.city_id || ':' || n),
                      120 + 180 * gen.r('npr:' || c.city_id || ':' || n)),
           NULL, n
    FROM city c, generate_series(1, 14) AS n
    UNION ALL
    SELECT c.city_id, 'no_ride', gen.pick('park:' || c.city_id || ':' || n,
               ARRAY['City Park', 'Botanical Garden', 'Pedestrian Old Town', 'Riverside Promenade', 'Zoo']) || ' ' || n,
           gen.circle(gen.near(c.centre, 4000, 'nrz:' || c.city_id || ':' || n),
                      250 + 250 * gen.r('nrr:' || c.city_id || ':' || n)),
           NULL, n
    FROM city c, generate_series(1, 3) AS n
    UNION ALL
    SELECT c.city_id, 'slow', s.name,
           gen.circle(gen.near(c.centre, CASE WHEN s.n = 1 THEN 300 ELSE 3500 END, 'slz:' || c.city_id || ':' || s.n),
                      CASE WHEN s.n = 1 THEN 1200 ELSE 400 + 400 * gen.r('slr:' || c.city_id || ':' || s.n) END),
           CASE WHEN s.n = 1 THEN 10 ELSE 15 END, s.n
    FROM city c, (VALUES (1, 'Old town'), (2, 'Market'), (3, 'Waterfront'), (4, 'University')) AS s(n, name)
    UNION ALL
    SELECT c.city_id, 'parking_hub', 'Parking hub ' || n,
           gen.circle(gen.near(c.centre, 4500, 'hub:' || c.city_id || ':' || n), 25),
           NULL, n
    FROM city c, generate_series(1, 15) AS n
) z
ORDER BY city_id, kind, n;

INSERT INTO station (city_id, name, location, docks)
SELECT c.city_id,
       gen.pick('st:' || c.city_id || ':' || n, ARRAY['Central', 'Market', 'Harbour', 'University', 'Park',
           'Museum', 'Library', 'Canal', 'Square', 'Bridge', 'Tower', 'Garden', 'Theatre', 'Stadium']) || ' ' || n,
       gen.near(c.centre, 4500, 'station:' || c.city_id || ':' || n),
       gen.ri('docks:' || c.city_id || ':' || n, 10, 30)
FROM city c, generate_series(1, 30) AS n
ORDER BY c.city_id, n;

--
-- Vehicles and prices
--
INSERT INTO vehicle (city_id, kind, serial, model, commissioned_on)
SELECT c.city_id, kind,
       upper(left(c.country_code, 2)) || '-' || upper(left(kind::text, 1)) || lpad(n::text, 5, '0'),
       CASE kind WHEN 'scooter' THEN gen.pick('sm:' || c.city_id || ':' || n, ARRAY['S-200', 'S-200', 'S-300'])
                 WHEN 'ebike' THEN gen.pick('em:' || c.city_id || ':' || n, ARRAY['E-Fleet 2', 'E-Fleet 3'])
                 ELSE 'Classic 1' END,
       date '2024-03-01' + gen.ri('comm:' || c.city_id || ':' || n, 0, 800)::int
FROM city c,
     generate_series(1, 300 * :scale) AS n,
     LATERAL (SELECT gen.pick('vk:' || c.city_id || ':' || n,
                              ARRAY['scooter', 'scooter', 'scooter', 'scooter', 'scooter', 'scooter', 'scooter', 'scooter', 'scooter',
                                    'ebike', 'ebike', 'ebike', 'ebike', 'ebike', 'ebike', 'ebike',
                                    'bike', 'bike', 'bike', 'bike']::vehicle_kind[]) AS kind) AS k
ORDER BY c.city_id, n;

-- Prices went up on 2026-09-01 (except for classic bikes).
INSERT INTO pricing_rule (city_id, kind, valid_at, unlock_fee, per_minute)
SELECT c.city_id, k.kind, p.valid_at,
       k.unlock,
       round(k.per_minute * f.factor * CASE WHEN k.kind = 'bike' THEN 1 ELSE p.bump END, 2)
FROM city c
JOIN (VALUES (1, 1.10), (2, 0.90), (3, 1.00)) AS f(city_id, factor) USING (city_id)
CROSS JOIN (VALUES ('scooter'::vehicle_kind, 1.00, 0.29), ('ebike', 1.00, 0.25), ('bike', 0.50, 0.12)) AS k(kind, unlock, per_minute)
CROSS JOIN (VALUES (daterange('2026-01-01', '2026-09-01'), 1.0), (daterange('2026-09-01', NULL), 1.1)) AS p(valid_at, bump)
ORDER BY 1, 2, lower(p.valid_at);

--
-- Riders and passes
--
INSERT INTO rider (city_id, full_name, email, birth_year, joined_at)
SELECT 1 + (i - 1) % 3, name, gen.email(name, i, 'riders.example.net'),
       2007 - floor(power(gen.r('age:' || i), 1.8) * 50)::int,
       gen.ts(date '2023-01-01' + gen.ri('rjoined:' || i, 0, 1350)::int, 'rjoined-t:' || i)
FROM generate_series(1, 20000 * :scale) AS i,
     LATERAL gen.person('rider:' || i) AS name
ORDER BY i;

INSERT INTO pass (rider_id, kind, valid_at, price)
SELECT rider_id, kind, valid_at, price FROM (
    -- monthly passes for regular commuters
    SELECT r.rider_id, 'monthly'::pass_kind AS kind,
           tstzrange(m::timestamp AT TIME ZONE c.timezone, (m + interval '1 month') AT TIME ZONE c.timezone) AS valid_at,
           CASE WHEN c.city_id = 1 THEN 34.99 ELSE 29.99 END AS price
    FROM rider r JOIN city c USING (city_id),
         generate_series(timestamp '2026-07-01', timestamp '2026-10-01', interval '1 month') AS m
    WHERE gen.r('commuter:' || r.rider_id) < 0.12
      AND gen.r('month:' || r.rider_id || ':' || m) < 0.75
    UNION ALL
    -- day passes for visitors and weekend riders
    SELECT r.rider_id, 'day',
           tstzrange(d::timestamp AT TIME ZONE c.timezone, (d + interval '1 day') AT TIME ZONE c.timezone),
           7.99
    FROM rider r JOIN city c USING (city_id),
         LATERAL (SELECT DISTINCT date '2026-07-01' + gen.ri('dp:' || r.rider_id || ':' || n, 0, 122)::int AS d
                  FROM generate_series(1, gen.ri('dpn:' || r.rider_id, 1, 4)::int) AS n) AS dd
    WHERE gen.r('commuter:' || r.rider_id) >= 0.12 AND gen.r('daypass:' || r.rider_id) < 0.15
) p
ORDER BY lower(valid_at), rider_id;

--
-- Trips. Each vehicle-day gets an "area" it moves around in and a number
-- of rides; ride n goes from waypoint n-1 to waypoint n, so a vehicle ends
-- each ride where the next one starts. Classic bikes go from station to
-- station. Overnight, operations staff move vehicles to the next day's
-- starting point.
--
CREATE TABLE gen.rider_pool AS
SELECT city_id, array_agg(rider_id ORDER BY rider_id) AS riders
FROM rider GROUP BY city_id;

CREATE TABLE gen.vday AS
SELECT v.vehicle_id, v.city_id, v.kind, c.timezone, d::date AS day,
       v.vehicle_id || ':' || d::date AS k,
       gen.near(c.centre, 3500, 'anchor:' || v.vehicle_id || ':' || d::date) AS anchor,
       floor(CASE v.kind WHEN 'scooter' THEN 3.2 WHEN 'ebike' THEN 2.6 ELSE 2.0 END
             * CASE WHEN extract(isodow FROM d) IN (6, 7) THEN 1.2 ELSE 1 END
             * CASE WHEN extract(month FROM d) = 10 THEN 0.75 ELSE 1 END
             -- rainy days: a fifth of the days in each city
             * CASE WHEN gen.r('rain:' || v.city_id || ':' || d::date) < 0.2 THEN 0.4 ELSE 1 END
             * (0.3 + 1.4 * gen.r('busy:' || v.vehicle_id || ':' || d::date)))::int AS n
FROM vehicle v
JOIN city c USING (city_id)
CROSS JOIN generate_series(timestamp '2026-07-01', timestamp '2026-10-31', interval '1 day') AS d;

-- Waypoints 0..n per vehicle-day, bikes snapped to the nearest station.
CREATE TABLE gen.waypoint AS
SELECT w.vehicle_id, w.day, w.seq, w.k,
       coalesce(st.location, w.pt) AS pt, st.station_id
FROM (
    SELECT vd.vehicle_id, vd.day, vd.kind, vd.city_id, s AS seq, vd.k,
           gen.near(vd.anchor, 1800, 'wp:' || vd.k || ':' || s) AS pt
    FROM gen.vday vd, generate_series(0, vd.n) AS s
) w
LEFT JOIN LATERAL (
    SELECT s.station_id, s.location FROM station s
    WHERE w.kind = 'bike' AND s.city_id = w.city_id
    ORDER BY s.location <-> w.pt LIMIT 1
) st ON true;
CREATE UNIQUE INDEX ON gen.waypoint (vehicle_id, day, seq);

-- Start times: commuting peaks and an evening tail, in local time; rides
-- are numbered in time order.
CREATE TABLE gen.ride AS
SELECT vd.*, j,
       row_number() OVER (PARTITION BY vd.vehicle_id, vd.day ORDER BY m.start_min, j) AS seq,
       m.start_min
FROM gen.vday vd,
     generate_series(1, vd.n) AS j,
     LATERAL (SELECT (60 * gen.pick('hour:' || vd.k || ':' || j,
                                   ARRAY[7, 8, 8, 8, 9, 9, 10, 11, 12, 12, 13, 14, 15, 16, 17, 17, 17,
                                         18, 18, 18, 19, 19, 20, 21, 22, 23])
                   + gen.ri('minute:' || vd.k || ':' || j, 0, 59))::int AS start_min) AS m;

CREATE TABLE gen.trip AS
SELECT r.vehicle_id, r.city_id, r.kind, r.day, r.seq, r.k || ':' || r.seq AS tk, r.timezone,
       a.station_id AS start_station_id, b.station_id AS end_station_id,
       route.route,
       (r.day + make_interval(mins => r.start_min)) AT TIME ZONE r.timezone AS started_at
FROM gen.ride r
JOIN gen.waypoint a ON a.vehicle_id = r.vehicle_id AND a.day = r.day AND a.seq = r.seq - 1
JOIN gen.waypoint b ON b.vehicle_id = r.vehicle_id AND b.day = r.day AND b.seq = r.seq
-- The route bends through two points off the straight line.
CROSS JOIN LATERAL (
    SELECT ST_MakeLine(ARRAY[
        a.pt,
        ST_Translate(ST_LineInterpolatePoint(ST_MakeLine(a.pt, b.pt), 0.33),
                     0.002 * (gen.r('bend1x:' || r.k || ':' || r.seq) - 0.5), 0.0015 * (gen.r('bend1y:' || r.k || ':' || r.seq) - 0.5)),
        ST_Translate(ST_LineInterpolatePoint(ST_MakeLine(a.pt, b.pt), 0.66),
                     0.002 * (gen.r('bend2x:' || r.k || ':' || r.seq) - 0.5), 0.0015 * (gen.r('bend2y:' || r.k || ':' || r.seq) - 0.5)),
        b.pt]) AS route
) route
WHERE NOT ST_Equals(a.pt, b.pt);

ALTER TABLE gen.trip ADD COLUMN ended_at timestamptz;
UPDATE gen.trip
SET ended_at = date_trunc('second', started_at + make_interval(secs =>
        ST_Length(route::geography) / CASE kind WHEN 'scooter' THEN 4.2 WHEN 'ebike' THEN 4.7 ELSE 3.4 END
        * (1.1 + 0.5 * gen.r('slow:' || tk)) + gen.ri('unlock:' || tk, 30, 150)));

-- A vehicle can't start a ride before the previous one ended: drop the
-- later of any two that collide.
DELETE FROM gen.trip t
USING (SELECT tk, started_at,
              lag(ended_at) OVER (PARTITION BY vehicle_id ORDER BY started_at, day, seq) AS prev_end
       FROM gen.trip) p
WHERE p.tk = t.tk AND p.started_at < p.prev_end;
DELETE FROM gen.trip WHERE ended_at >= gen.as_of();

INSERT INTO trip (rider_id, vehicle_id, pass_id, started_at, ended_at, start_station_id,
                  end_station_id, route, fare)
SELECT rd.rider_id, t.vehicle_id, ps.pass_id, t.started_at, t.ended_at,
       t.start_station_id, t.end_station_id, t.route,
       price_trip(t.city_id::smallint, t.kind, t.started_at, t.ended_at, ps.pass_id IS NOT NULL)
FROM gen.trip t
JOIN gen.rider_pool rp USING (city_id)
CROSS JOIN LATERAL (SELECT rp.riders[1 + floor(power(gen.r('rider:' || t.tk), 1.6) * cardinality(rp.riders))::int] AS rider_id) AS rd
LEFT JOIN pass ps ON ps.rider_id = rd.rider_id AND ps.valid_at @> t.started_at
ORDER BY t.started_at, t.vehicle_id;

--
-- Telemetry, battery swaps and rebalancing
--

-- Battery: e-scooters use about 2.5% per km, e-bikes 1.2%. A swap brings
-- the battery back to 100% whenever it would drop below 25%.
CREATE TABLE gen.trip_battery AS
SELECT t.trip_id, t.vehicle_id, t.started_at, t.ended_at, t.route, v.kind,
       floor(coalesce(lag(cum) OVER w, 0) / 75) AS swaps_before,
       floor(cum / 75) AS swaps_after,
       CASE WHEN v.kind = 'bike' THEN NULL ELSE 100 - (coalesce(lag(cum) OVER w, 0) % 75) END AS battery_start,
       CASE WHEN v.kind = 'bike' THEN NULL ELSE 100 - (cum % 75) END AS battery_end
FROM (
    SELECT t.*, sum(t.distance_m / 1000.0 * CASE v.kind WHEN 'scooter' THEN 2.5 WHEN 'ebike' THEN 1.2 ELSE 0 END)
                    OVER (PARTITION BY t.vehicle_id ORDER BY t.started_at) AS cum
    FROM trip t JOIN vehicle v USING (vehicle_id)
) t
JOIN vehicle v USING (vehicle_id)
WINDOW w AS (PARTITION BY t.vehicle_id ORDER BY t.started_at);

INSERT INTO vehicle_status (vehicle_id, reported_at, location, battery_pct, is_locked)
SELECT vehicle_id, reported_at, location, battery_pct, is_locked
FROM (
    SELECT vehicle_id, started_at AS reported_at, ST_StartPoint(route) AS location,
           round(battery_start)::smallint AS battery_pct, false AS is_locked
    FROM gen.trip_battery
    UNION ALL
    SELECT vehicle_id, ended_at, ST_EndPoint(route), round(battery_end)::smallint, true
    FROM gen.trip_battery
    UNION ALL
    -- 03:00 heartbeat from wherever the vehicle spent the night
    (SELECT DISTINCT ON (tb.vehicle_id, (tb.ended_at AT TIME ZONE c.timezone)::date)
           tb.vehicle_id,
           (((tb.ended_at AT TIME ZONE c.timezone)::date + 1) + time '03:00') AT TIME ZONE c.timezone,
           ST_EndPoint(tb.route), round(tb.battery_end)::smallint, true
    FROM gen.trip_battery tb
    JOIN vehicle v USING (vehicle_id)
    JOIN city c USING (city_id)
    ORDER BY tb.vehicle_id, (tb.ended_at AT TIME ZONE c.timezone)::date, tb.ended_at DESC)
) s
WHERE reported_at < gen.as_of()
ORDER BY reported_at, vehicle_id, is_locked;

INSERT INTO maintenance_task (vehicle_id, kind, opened_at, closed_at, notes)
SELECT vehicle_id, kind, opened_at,
       CASE WHEN closed_at < gen.as_of() THEN closed_at END, notes
FROM (
    SELECT tb.vehicle_id, 'battery_swap'::task_kind AS kind,
           tb.ended_at + interval '5 minutes' AS opened_at,
           tb.ended_at + make_interval(mins => gen.ri('swap:' || tb.trip_id, 20, 240)::int) AS closed_at,
           'battery at ' || round(tb.battery_end) || '%' AS notes
    FROM gen.trip_battery tb
    WHERE tb.swaps_after > tb.swaps_before
    UNION ALL
    SELECT v.vehicle_id, 'inspection',
           ((d::date + time '06:00') AT TIME ZONE c.timezone),
           ((d::date + time '06:00') AT TIME ZONE c.timezone) + make_interval(mins => gen.ri('insp:' || v.vehicle_id || d, 10, 40)::int),
           'monthly safety check'
    FROM vehicle v JOIN city c USING (city_id),
         generate_series(timestamp '2026-07-01', timestamp '2026-10-01', interval '1 month') AS m,
         LATERAL (SELECT m + make_interval(days => gen.ri('inspday:' || v.vehicle_id || ':' || m, 0, 27)::int) AS d) AS dd
    UNION ALL
    SELECT t.vehicle_id, 'repair',
           t.ended_at + interval '10 minutes',
           t.ended_at + make_interval(hours => gen.ri('fix:' || t.trip_id, 2, 72)::int),
           gen.pick('fault:' || t.trip_id, ARRAY['flat tyre', 'brake adjustment', 'broken bell',
                    'loose handlebar', 'damaged lock', 'light not working', 'reported by rider: wobbly'])
    FROM trip t
    WHERE gen.r('repair:' || t.trip_id) < 0.004
) m
ORDER BY opened_at, vehicle_id, kind;

-- Rebalancing: every morning a vehicle starts where staff left it; record
-- a job when that is more than 300 m from where its last ride ended.
INSERT INTO rebalance_job (vehicle_id, picked_up, dropped_off, done_at)
SELECT vehicle_id, prev_end, start_point,
       ((day + time '04:00') AT TIME ZONE timezone) + make_interval(mins => gen.ri('reb:' || vehicle_id || ':' || day, 0, 150)::int)
FROM (
    SELECT t.vehicle_id, c.timezone, (t.started_at AT TIME ZONE c.timezone)::date AS day,
           ST_StartPoint(t.route) AS start_point,
           lag(ST_EndPoint(t.route)) OVER (PARTITION BY t.vehicle_id ORDER BY t.started_at) AS prev_end,
           lag((t.started_at AT TIME ZONE c.timezone)::date) OVER (PARTITION BY t.vehicle_id ORDER BY t.started_at) AS prev_day
    FROM trip t JOIN vehicle v USING (vehicle_id) JOIN city c USING (city_id)
) x
WHERE prev_day IS NOT NULL AND prev_day < day
  AND ST_DistanceSphere(prev_end, start_point) > 300
ORDER BY 4, 1;

REFRESH MATERIALIZED VIEW daily_city_stats;

DROP SCHEMA gen CASCADE;
ANALYZE;
