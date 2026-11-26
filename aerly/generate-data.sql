--
-- pg_fil: aerly -- sample data generator
--
-- Run after schema.sql, into an empty database:
--   psql -d aerly -f generate-data.sql
--   psql -d aerly -v scale=3 -f generate-data.sql     -- 3x the users
--
-- The output is deterministic: every "random" choice is a hash of a key
-- string (see gen.r below), never random() or the clock, so the same scale
-- always gives the same rows on any little-endian server (x86-64, ARM64,
-- ppc64le), in any time zone.
--
-- Trips run from January 2025 to spring 2027 and the data is "as of"
-- 2026-11-01 00:00 UTC: earlier flights have landed (with their delays,
-- gate changes and the odd cancellation), a few are in the air right now,
-- mostly people flying overnight to the Elephant Summit in Lisbon, which
-- opens on 3 November, and later trips are booked but not flown yet.
--
-- Users come in friend circles ("crowds") that tend to go to the same
-- conferences, and some live together as couples who travel together. The
-- cities and airports are real; people, airlines, hotels, restaurants and
-- conferences are made up.
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
    IF EXISTS (SELECT FROM users) THEN
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

-- gen.code(key, n): n characters for a booking reference (no 0/O, 1/I).
CREATE FUNCTION gen.code(k text, n int) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
SELECT string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                         1 + get_byte(decode(md5(k || '#' || (i / 16)), 'hex'), i % 16) % 32, 1), '' ORDER BY i)
FROM generate_series(0, n - 1) AS i
$$;

-- gen.between(a, b, key): an instant between a and b, to the second.
CREATE FUNCTION gen.between(a timestamptz, b timestamptz, k text) RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT date_trunc('second', a + greatest(b - a, interval '0') * gen.r(k)) $$;

-- gen.lt(date, time, zone): the instant of a local wall-clock time.
CREATE FUNCTION gen.lt(d date, t time, tz text) RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT (d + t) AT TIME ZONE tz $$;

-- gen.km(lat1, lon1, lat2, lon2): great-circle distance (haversine).
CREATE FUNCTION gen.km(lat1 float8, lon1 float8, lat2 float8, lon2 float8) RETURNS float8
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
SELECT 2 * 6371 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2)
                            + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

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

-- gen.phone(country calling code, key): a made-up number in a 555 01xx
-- style block.
CREATE FUNCTION gen.phone(cc int, k text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT '+' || cc || ' 555 01' || lpad(gen.ri(k, 0, 99)::text, 2, '0') || ' ' || lpad(gen.ri(k || '#2', 0, 999)::text, 3, '0') $$;

CREATE FUNCTION gen.as_of() RETURNS timestamptz
LANGUAGE sql IMMUTABLE AS $$ SELECT timestamptz '2026-11-01 00:00:00+00' $$;

--
-- Cities, each with its main airport: IATA code, airport and city-centre
-- coordinates, time zone, currency (with a rough rate to the euro), and
-- how likely people are to live there, holiday there or do business there.
--
CREATE TABLE gen.city AS
SELECT row_number() OVER (ORDER BY iata)::int AS cid, c.*
FROM (VALUES
    ('LIS', 'Lisbon', 'Portugal', 'PT', 38.7742, -9.1342, 38.7223, -9.1393, 'Europe/Lisbon', 'EUR', 1.0, 351, 'eu', 4, 5, 2),
    ('MAD', 'Madrid', 'Spain', 'ES', 40.4936, -3.5668, 40.4168, -3.7038, 'Europe/Madrid', 'EUR', 1.0, 34, 'eu', 5, 3, 4),
    ('BCN', 'Barcelona', 'Spain', 'ES', 41.2971, 2.0785, 41.3874, 2.1686, 'Europe/Madrid', 'EUR', 1.0, 34, 'eu', 3, 5, 2),
    ('CDG', 'Paris', 'France', 'FR', 49.0097, 2.5479, 48.8566, 2.3522, 'Europe/Paris', 'EUR', 1.0, 33, 'eu', 6, 4, 5),
    ('AMS', 'Amsterdam', 'Netherlands', 'NL', 52.3105, 4.7683, 52.3676, 4.9041, 'Europe/Amsterdam', 'EUR', 1.0, 31, 'eu', 5, 3, 4),
    ('BRU', 'Brussels', 'Belgium', 'BE', 50.9010, 4.4844, 50.8503, 4.3517, 'Europe/Brussels', 'EUR', 1.0, 32, 'eu', 3, 1, 3),
    ('LHR', 'London', 'United Kingdom', 'GB', 51.4700, -0.4543, 51.5072, -0.1276, 'Europe/London', 'GBP', 0.85, 44, 'eu', 9, 3, 6),
    ('EDI', 'Edinburgh', 'United Kingdom', 'GB', 55.9500, -3.3725, 55.9533, -3.1883, 'Europe/London', 'GBP', 0.85, 44, 'eu', 2, 3, 1),
    ('DUB', 'Dublin', 'Ireland', 'IE', 53.4213, -6.2701, 53.3498, -6.2603, 'Europe/Dublin', 'EUR', 1.0, 353, 'eu', 3, 2, 3),
    ('FRA', 'Frankfurt', 'Germany', 'DE', 50.0379, 8.5622, 50.1109, 8.6821, 'Europe/Berlin', 'EUR', 1.0, 49, 'eu', 4, 1, 5),
    ('BER', 'Berlin', 'Germany', 'DE', 52.3667, 13.5033, 52.5200, 13.4050, 'Europe/Berlin', 'EUR', 1.0, 49, 'eu', 7, 3, 4),
    ('MUC', 'Munich', 'Germany', 'DE', 48.3538, 11.7861, 48.1351, 11.5820, 'Europe/Berlin', 'EUR', 1.0, 49, 'eu', 4, 2, 3),
    ('ZRH', 'Zurich', 'Switzerland', 'CH', 47.4581, 8.5555, 47.3769, 8.5417, 'Europe/Zurich', 'CHF', 0.95, 41, 'eu', 3, 2, 3),
    ('VIE', 'Vienna', 'Austria', 'AT', 48.1103, 16.5697, 48.2082, 16.3738, 'Europe/Vienna', 'EUR', 1.0, 43, 'eu', 3, 3, 2),
    ('PRG', 'Prague', 'Czechia', 'CZ', 50.1008, 14.2600, 50.0755, 14.4378, 'Europe/Prague', 'CZK', 25.0, 420, 'eu', 3, 4, 1),
    ('WAW', 'Warsaw', 'Poland', 'PL', 52.1657, 20.9671, 52.2297, 21.0122, 'Europe/Warsaw', 'PLN', 4.3, 48, 'eu', 4, 1, 2),
    ('BUD', 'Budapest', 'Hungary', 'HU', 47.4369, 19.2556, 47.4979, 19.0402, 'Europe/Budapest', 'HUF', 390.0, 36, 'eu', 2, 3, 1),
    ('CPH', 'Copenhagen', 'Denmark', 'DK', 55.6180, 12.6508, 55.6761, 12.5683, 'Europe/Copenhagen', 'DKK', 7.46, 45, 'eu', 3, 2, 2),
    ('ARN', 'Stockholm', 'Sweden', 'SE', 59.6498, 17.9238, 59.3293, 18.0686, 'Europe/Stockholm', 'SEK', 11.0, 46, 'eu', 3, 2, 2),
    ('OSL', 'Oslo', 'Norway', 'NO', 60.1976, 11.1004, 59.9139, 10.7522, 'Europe/Oslo', 'NOK', 11.5, 47, 'eu', 2, 2, 1),
    ('HEL', 'Helsinki', 'Finland', 'FI', 60.3172, 24.9633, 60.1699, 24.9384, 'Europe/Helsinki', 'EUR', 1.0, 358, 'eu', 2, 1, 1),
    ('ATH', 'Athens', 'Greece', 'GR', 37.9364, 23.9445, 37.9838, 23.7275, 'Europe/Athens', 'EUR', 1.0, 30, 'eu', 2, 5, 1),
    ('IST', 'Istanbul', 'Turkey', 'TR', 41.2753, 28.7519, 41.0082, 28.9784, 'Europe/Istanbul', 'TRY', 45.0, 90, 'eu', 4, 4, 3),
    ('FCO', 'Rome', 'Italy', 'IT', 41.8003, 12.2389, 41.9028, 12.4964, 'Europe/Rome', 'EUR', 1.0, 39, 'eu', 3, 5, 2),
    ('MXP', 'Milan', 'Italy', 'IT', 45.6306, 8.7281, 45.4642, 9.1900, 'Europe/Rome', 'EUR', 1.0, 39, 'eu', 3, 2, 3),
    ('JFK', 'New York', 'United States', 'US', 40.6413, -73.7781, 40.7128, -74.0060, 'America/New_York', 'USD', 1.1, 1, 'na', 6, 3, 6),
    ('BOS', 'Boston', 'United States', 'US', 42.3656, -71.0096, 42.3601, -71.0589, 'America/New_York', 'USD', 1.1, 1, 'na', 2, 1, 2),
    ('ORD', 'Chicago', 'United States', 'US', 41.9742, -87.9073, 41.8781, -87.6298, 'America/Chicago', 'USD', 1.1, 1, 'na', 3, 1, 3),
    ('SFO', 'San Francisco', 'United States', 'US', 37.6213, -122.3790, 37.7749, -122.4194, 'America/Los_Angeles', 'USD', 1.1, 1, 'na', 5, 2, 5),
    ('SEA', 'Seattle', 'United States', 'US', 47.4502, -122.3088, 47.6062, -122.3321, 'America/Los_Angeles', 'USD', 1.1, 1, 'na', 2, 1, 2),
    ('YYZ', 'Toronto', 'Canada', 'CA', 43.6777, -79.6248, 43.6532, -79.3832, 'America/Toronto', 'CAD', 1.5, 1, 'na', 3, 1, 2),
    ('GRU', 'Sao Paulo', 'Brazil', 'BR', -23.4356, -46.4731, -23.5505, -46.6333, 'America/Sao_Paulo', 'BRL', 6.0, 55, 'sa', 2, 1, 2),
    ('DXB', 'Dubai', 'United Arab Emirates', 'AE', 25.2532, 55.3657, 25.2048, 55.2708, 'Asia/Dubai', 'AED', 4.0, 971, 'me', 1, 3, 3),
    ('BLR', 'Bengaluru', 'India', 'IN', 13.1986, 77.7066, 12.9716, 77.5946, 'Asia/Kolkata', 'INR', 95.0, 91, 'as', 3, 1, 3),
    ('SIN', 'Singapore', 'Singapore', 'SG', 1.3644, 103.9915, 1.3521, 103.8198, 'Asia/Singapore', 'SGD', 1.45, 65, 'as', 2, 3, 4),
    ('NRT', 'Tokyo', 'Japan', 'JP', 35.7720, 140.3929, 35.6762, 139.6503, 'Asia/Tokyo', 'JPY', 165.0, 81, 'as', 2, 4, 3),
    ('SYD', 'Sydney', 'Australia', 'AU', -33.9399, 151.1753, -33.8688, 151.2093, 'Australia/Sydney', 'AUD', 1.65, 61, 'oc', 2, 3, 2),
    ('AKL', 'Auckland', 'New Zealand', 'NZ', -37.0082, 174.7850, -36.8485, 174.7633, 'Pacific/Auckland', 'NZD', 1.8, 64, 'oc', 1, 2, 1),
    ('CPT', 'Cape Town', 'South Africa', 'ZA', -33.9715, 18.6021, -33.9249, 18.4241, 'Africa/Johannesburg', 'ZAR', 20.0, 27, 'af', 1, 3, 1)
) AS c(iata, city, country, cc, lat, lon, clat, clon, tz, currency, fx, dial, region, w_home, w_leisure, w_business);

-- gen.bag(weights): city ids repeated by weight, to pick from.
CREATE TABLE gen.bag AS
SELECT (SELECT array_agg(cid ORDER BY cid, n) FROM gen.city, generate_series(1, w_home) AS n) AS home,
       (SELECT array_agg(cid ORDER BY cid, n) FROM gen.city, generate_series(1, w_leisure) AS n) AS leisure,
       (SELECT array_agg(cid ORDER BY cid, n) FROM gen.city, generate_series(1, w_business) AS n) AS business;

-- Made-up airlines: IATA designator, ICAO callsign prefix, name.
CREATE TABLE gen.airline AS
SELECT * FROM (VALUES
    (1, 'FA', 'FIL', 'Fil Air'), (2, 'NJ', 'NJT', 'Northjet'), (3, 'SX', 'SKX', 'Skyway Express'),
    (4, 'OV', 'OVR', 'Overland Air'), (5, 'HB', 'HBR', 'Harbour Airways'), (6, 'ZE', 'ZEP', 'Zephyr'),
    (7, 'KT', 'KTE', 'Kite Airlines'), (8, 'LU', 'LUM', 'Lumen Air')
) AS a(aid, iata, icao, name);

-- Conferences. The Elephant Summit 2026 opens two days after "now".
CREATE TABLE gen.conf AS
SELECT row_number() OVER (ORDER BY starts)::int AS gid, c.name, c.series, ci.cid, c.starts, c.ends, c.size
FROM (VALUES
    ('WAL Street 2025', 'walstreet', 'JFK', date '2025-03-26', date '2025-03-27', 0.07),
    ('Slonik Days 2025', 'slonik', 'PRG', date '2025-05-13', date '2025-05-15', 0.08),
    ('Northern Data Week 2025', 'northern', 'ARN', date '2025-06-10', date '2025-06-12', 0.05),
    ('Vacuum Fest 2025', 'vacuum', 'BER', date '2025-09-16', date '2025-09-17', 0.06),
    ('Elephant Summit 2025', 'elephant', 'ATH', date '2025-10-21', date '2025-10-24', 0.20),
    ('Open Harbour 2025', 'harbour', 'AMS', date '2025-12-02', date '2025-12-04', 0.05),
    ('Index Island 2026', 'index', 'SIN', date '2026-02-24', date '2026-02-26', 0.04),
    ('WAL Street 2026', 'walstreet', 'JFK', date '2026-03-25', date '2026-03-26', 0.08),
    ('Bay Area Data Day 2026', 'bayarea', 'SFO', date '2026-04-21', date '2026-04-21', 0.04),
    ('Slonik Days 2026', 'slonik', 'BUD', date '2026-05-12', date '2026-05-14', 0.09),
    ('Northern Data Week 2026', 'northern', 'HEL', date '2026-06-09', date '2026-06-11', 0.05),
    ('Vacuum Fest 2026', 'vacuum', 'VIE', date '2026-09-15', date '2026-09-16', 0.07),
    ('Elephant Summit 2026', 'elephant', 'LIS', date '2026-11-03', date '2026-11-06', 0.24),
    ('Open Harbour 2026', 'harbour', 'CPH', date '2026-12-01', date '2026-12-03', 0.05),
    ('Index Island 2027', 'index', 'SIN', date '2027-02-23', date '2027-02-25', 0.03),
    ('WAL Street 2027', 'walstreet', 'JFK', date '2027-03-24', date '2027-03-25', 0.06)
) AS c(name, series, iata, starts, ends, size)
JOIN gen.city ci USING (iata);

--
-- Users. Each belongs to a crowd of friends and lives in a city; some
-- travel a lot. A fifth of them imported their earlier trips from TripIt.
--
CREATE TABLE gen.u AS
SELECT i AS uid, n.name, split_part(n.name, ' ', 1) AS first, split_part(n.name, ' ', 2) AS last,
       gen.pick('home:' || i, b.home) AS home,
       1 + floor(gen.r('crowd:' || i) * (60 * :scale))::int AS crowd,
       power(gen.r('travel:' || i), 1.6) AS travel,
       gen.r('tripit:' || i) < 0.2 AS tripit,
       CASE WHEN i = 1 THEN timestamptz '2025-03-01 09:12:00+00'
            ELSE gen.between(timestamptz '2025-03-01', timestamptz '2026-10-25',
                             'joined:' || power(gen.r('joined0:' || i), 1.3)) END AS joined
FROM generate_series(1, 2000 * :scale) AS i,
     LATERAL gen.person('user:' || i) AS n(name),
     gen.bag b;

-- Usernames: first name and last initial, numbered when taken.
CREATE TABLE gen.uname AS
SELECT uid, base || CASE WHEN n > 1 THEN n::text ELSE '' END AS username
FROM (SELECT uid, lower(first || substr(last, 1, 1)) AS base,
             row_number() OVER (PARTITION BY lower(first || substr(last, 1, 1)) ORDER BY uid) AS n
      FROM gen.u) s;

INSERT INTO users (id, name, avatar_url, is_superuser, is_active, last_login_at, created_at, updated_at,
                   username, home_address, session_version, paper_size, hide_explore, hide_maps,
                   home_lat, home_lon, home_tz)
SELECT u.uid, u.name,
       'https://avatars.example.com/u/' || u.uid || '.png',
       u.uid = 1,
       gen.r('active:' || u.uid) >= 0.015,
       gen.between(u.joined, gen.as_of() - interval '10 minutes', 'login:' || u.uid || ':' || power(gen.r('lg:' || u.uid), 0.25)),
       u.joined,
       gen.between(u.joined, gen.as_of() - interval '1 hour', 'upd:' || u.uid),
       n.username,
       CASE WHEN gen.r('addr:' || u.uid) < 0.7 THEN
           gen.ri('hn:' || u.uid, 1, 180) || ' ' || gen.pick('st:' || u.uid, ARRAY['Linden', 'Harbour', 'Mill',
               'Chestnut', 'Station', 'Orchard', 'Market', 'Willow', 'Castle', 'Garden', 'Bridge', 'Park'])
           || ' ' || gen.pick('sts:' || u.uid, ARRAY['Street', 'Road', 'Lane', 'Avenue']) || ', ' || c.city || ', ' || c.country
       ELSE '' END,
       CASE WHEN gen.r('sv:' || u.uid) < 0.1 THEN gen.ri('svn:' || u.uid, 1, 3) ELSE 0 END,
       CASE WHEN c.cc IN ('US', 'CA') THEN 'letter' ELSE 'a4' END,
       gen.r('hx:' || u.uid) < 0.06,
       gen.r('hm:' || u.uid) < 0.03,
       CASE WHEN gen.r('addr:' || u.uid) < 0.7 THEN round((c.clat + 0.06 * (gen.r('hla:' || u.uid) - 0.5))::numeric, 5) END,
       CASE WHEN gen.r('addr:' || u.uid) < 0.7 THEN round((c.clon + 0.08 * (gen.r('hlo:' || u.uid) - 0.5))::numeric, 5) END,
       CASE WHEN gen.r('htz:' || u.uid) < 0.92 THEN c.tz ELSE '' END
FROM gen.u u JOIN gen.uname n USING (uid) JOIN gen.city c ON c.cid = u.home
ORDER BY u.uid;

-- Sign-in identities: GitHub, Google or both.
INSERT INTO user_identities (user_id, provider, provider_user_id, created_at, last_used_at)
SELECT u.uid, p.provider,
       CASE p.provider WHEN 'github' THEN (1000000 + u.uid * 4099 + gen.ri('ghid:' || u.uid, 0, 4000))::text
                       ELSE '10' || lpad(u.uid::text, 8, '0') || lpad(gen.ri('goid:' || u.uid, 0, 999999999)::text, 9, '0') END,
       u.joined + CASE WHEN p.n = 1 THEN interval '0' ELSE make_interval(days => gen.ri('id2:' || u.uid, 1, 200)::int) END,
       us.last_login_at
FROM gen.u u
JOIN users us ON us.id = u.uid
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        (CASE WHEN gen.r('idp:' || u.uid) < 0.7 THEN 'github' ELSE 'google' END, 1),
        (CASE WHEN gen.r('idp:' || u.uid) < 0.7 THEN 'google' ELSE 'github' END, 2)) AS v(provider, n)
    WHERE v.n = 1 OR gen.r('id2?' || u.uid) < 0.25
) p
WHERE u.joined + CASE WHEN p.n = 1 THEN interval '0' ELSE make_interval(days => gen.ri('id2:' || u.uid, 1, 200)::int) END < gen.as_of()
ORDER BY 5, 1, 2;

-- Email addresses: a primary one, and for a third of users a work address
-- too. Booking emails are forwarded from these.
CREATE TABLE gen.email AS
SELECT u.uid, 1 AS n, true AS is_primary,
       lower(u.first || '.' || u.last) || '.' || u.uid || '@' || gen.pick('dom:' || u.uid, ARRAY['example.com', 'example.org', 'example.net', 'mail.example.com']) AS address
FROM gen.u u
UNION ALL
SELECT u.uid, 2, false,
       lower(substr(u.first, 1, 1) || u.last) || u.uid || '@' || gen.pick('wdom:' || u.uid, ARRAY['corp.example.com', 'dbteam.example.org', 'consulting.example.net', 'cloud.example.com'])
FROM gen.u u
WHERE gen.r('email2:' || u.uid) < 0.33;

INSERT INTO user_emails (user_id, address, verified, verify_token, verify_sent_at, verified_at, created_at, is_primary)
SELECT e.uid, e.address, v.verified,
       CASE WHEN NOT v.verified THEN md5('verify:' || e.uid || ':' || e.n) END,
       CASE WHEN e.n = 2 THEN v.added END,
       CASE WHEN v.verified THEN v.added + CASE WHEN e.n = 2 THEN make_interval(mins => gen.ri('vt:' || e.uid, 1, 600)::int) ELSE interval '0' END END,
       v.added, e.is_primary
FROM gen.email e
JOIN gen.u u USING (uid)
CROSS JOIN LATERAL (SELECT e.n = 1 OR gen.r('ver:' || e.uid) < 0.85 AS verified,
                           CASE WHEN e.n = 1 THEN u.joined
                                ELSE gen.between(u.joined, gen.as_of() - interval '1 day', 'e2t:' || e.uid) END AS added) v
ORDER BY v.added, e.uid, e.n;

-- Alert preferences: most people keep the defaults and have no row.
INSERT INTO alert_prefs (user_id, in_app, email, min_delay_min, checkin, departure_summary)
SELECT uid,
       gen.r('pin:' || uid) >= 0.05,
       gen.r('pem:' || uid) >= 0.35,
       gen.pick('pmd:' || uid, ARRAY[15, 15, 15, 10, 20, 30, 30, 45, 60]),
       gen.r('pck:' || uid) < 0.45,
       gen.r('pds:' || uid) >= 0.3
FROM gen.u
WHERE gen.r('prefs?' || uid) < 0.4
ORDER BY uid;

CREATE TABLE gen.pref AS
SELECT u.uid, coalesce(p.in_app, true) AS in_app, coalesce(p.min_delay_min, 15) AS min_delay,
       coalesce(p.checkin, false) AS checkin, coalesce(p.departure_summary, true) AS departure_summary
FROM gen.u u LEFT JOIN alert_prefs p ON p.user_id = u.uid;

INSERT INTO push_kind_prefs (user_id, kind, enabled)
SELECT uid, kind, false
FROM gen.u, unnest(ARRAY['alert', 'share', 'reminder', 'checkin', 'departure']) AS kind
WHERE gen.r('push?' || uid) < 0.15 AND gen.r('pushk:' || uid || kind) < 0.3
ORDER BY uid, kind;

INSERT INTO webpush_subscriptions (user_id, endpoint, p256dh, auth, user_agent, created_at,
                                   last_success_at, last_failure_at, failure_count)
SELECT u.uid,
       'https://push.example.net/wpush/v2/' || md5('ep:' || u.uid || ':' || d) || md5('ep2:' || u.uid || ':' || d),
       'B' || translate(encode(decode(md5('p256:' || u.uid || d) || md5('p256b:' || u.uid || d)
                                       || md5('p256c:' || u.uid || d) || md5('p256d:' || u.uid || d), 'hex'), 'base64'), E'+/=\n', '-_'),
       translate(encode(decode(md5('auth:' || u.uid || d), 'hex'), 'base64'), E'+/=\n', '-_'),
       gen.pick('ua:' || u.uid || ':' || d, ARRAY[
           'Mozilla/5.0 (iPhone; CPU iPhone OS 19_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.1 Mobile/15E148 Safari/604.1',
           'Mozilla/5.0 (Linux; Android 16; Pixel 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Mobile Safari/537.36',
           'Mozilla/5.0 (X11; Linux x86_64; rv:145.0) Gecko/20100101 Firefox/145.0',
           'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36',
           'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36 Edg/141.0']),
       s.created,
       CASE WHEN f.failures < 3 THEN gen.between(s.created, gen.as_of() - interval '5 minutes', 'wps:' || u.uid || d) END,
       CASE WHEN f.failures > 0 THEN gen.between(s.created, gen.as_of() - interval '5 minutes', 'wpf:' || u.uid || d) END,
       f.failures
FROM gen.u u
CROSS JOIN generate_series(1, 2) AS d
CROSS JOIN LATERAL (SELECT gen.between(u.joined, gen.as_of() - interval '1 hour', 'wpc:' || u.uid || ':' || d) AS created) s
CROSS JOIN LATERAL (SELECT CASE WHEN gen.r('wpff:' || u.uid || d) < 0.85 THEN 0 ELSE gen.ri('wpfn:' || u.uid || d, 1, 6)::int END AS failures) f
WHERE gen.r('push-sub:' || u.uid) < 0.45 AND (d = 1 OR gen.r('push-sub2:' || u.uid) < 0.3)
ORDER BY s.created, u.uid, d;

--
-- Couples and friends. Couples are formed within a home city; friends
-- come from the same crowd or the same city.
--
CREATE TABLE gen.couple AS
SELECT least(a.uid, b.uid) AS u1, greatest(a.uid, b.uid) AS u2
FROM (SELECT uid, home, row_number() OVER (PARTITION BY home ORDER BY gen.r('pair:' || uid), uid) AS n FROM gen.u) a
JOIN (SELECT uid, home, row_number() OVER (PARTITION BY home ORDER BY gen.r('pair:' || uid), uid) AS n FROM gen.u) b
  ON b.home = a.home AND b.n = a.n + 1
WHERE a.n % 2 = 1 AND gen.r('couple:' || a.home || ':' || a.n) < 0.3;

CREATE TABLE gen.partner AS
SELECT u1 AS uid, u2 AS partner, true AS leads FROM gen.couple
UNION ALL
SELECT u2, u1, false FROM gen.couple;

CREATE TABLE gen.crowd_member AS
SELECT crowd, uid, row_number() OVER (PARTITION BY crowd ORDER BY uid) AS n, count(*) OVER (PARTITION BY crowd) AS cnt
FROM gen.u;

CREATE TABLE gen.city_member AS
SELECT home, uid, row_number() OVER (PARTITION BY home ORDER BY uid) AS n, count(*) OVER (PARTITION BY home) AS cnt
FROM gen.u;

CREATE TABLE gen.friend_pair AS
SELECT DISTINCT least(a, b) AS u1, greatest(a, b) AS u2, bool_or(couple) OVER (PARTITION BY least(a, b), greatest(a, b)) AS couple
FROM (
    SELECT u.uid AS a, cm.uid AS b, false AS couple
    FROM gen.u u
    CROSS JOIN generate_series(1, 8) AS j
    JOIN gen.crowd_member me ON me.uid = u.uid
    JOIN gen.crowd_member cm ON cm.crowd = u.crowd
                            AND cm.n = 1 + floor(gen.r('fc:' || u.uid || ':' || j) * me.cnt)
    WHERE j <= 2 + floor(6 * gen.r('fn:' || u.uid))
    UNION ALL
    SELECT u.uid, cm.uid, false
    FROM gen.u u
    CROSS JOIN generate_series(1, 2) AS j
    JOIN gen.city_member me ON me.uid = u.uid
    JOIN gen.city_member cm ON cm.home = u.home
                           AND cm.n = 1 + floor(gen.r('fh:' || u.uid || ':' || j) * me.cnt)
    WHERE gen.r('fh?' || u.uid || ':' || j) < 0.5
    UNION ALL
    SELECT u1, u2, true FROM gen.couple
) s
WHERE a <> b;

INSERT INTO friendships (user_low, user_high, status, requested_by, requested_at, accepted_at, invited_email)
SELECT f.u1, f.u2, CASE WHEN x.pending THEN 'pending' ELSE 'accepted' END,
       x.requester, x.requested_at,
       CASE WHEN NOT x.pending THEN least(x.requested_at + make_interval(mins => gen.ri('acc:' || f.u1 || ':' || f.u2, 2, 4000)::int),
                                         gen.as_of() - interval '1 minute') END,
       CASE WHEN x.pending OR gen.r('inv:' || f.u1 || ':' || f.u2) < 0.3
            THEN (SELECT address FROM gen.email e WHERE e.uid = CASE WHEN x.requester = f.u1 THEN f.u2 ELSE f.u1 END AND e.n = 1) END
FROM gen.friend_pair f
JOIN gen.u a ON a.uid = f.u1
JOIN gen.u b ON b.uid = f.u2
CROSS JOIN LATERAL (
    SELECT NOT f.couple AND gen.r('pend:' || f.u1 || ':' || f.u2) < 0.04 AS pending,
           CASE WHEN gen.r('req:' || f.u1 || ':' || f.u2) < 0.5 THEN f.u1 ELSE f.u2 END AS requester,
           gen.between(greatest(a.joined, b.joined), least(greatest(a.joined, b.joined) + interval '120 days', gen.as_of() - interval '2 hours'),
                       'rqt:' || f.u1 || ':' || f.u2) AS requested_at
) x
ORDER BY x.requested_at, f.u1, f.u2;

-- Accepted friends, in both directions, numbered for picking.
CREATE TABLE gen.friend AS
SELECT uid, friend, since, row_number() OVER (PARTITION BY uid ORDER BY friend) AS n, count(*) OVER (PARTITION BY uid) AS cnt
FROM (SELECT user_low AS uid, user_high AS friend, accepted_at AS since FROM friendships WHERE status = 'accepted'
      UNION ALL
      SELECT user_high, user_low, accepted_at FROM friendships WHERE status = 'accepted') s;
CREATE INDEX ON gen.friend (uid, n);

INSERT INTO pending_friend_invites (email_lower, inviter_id, message, created_at)
SELECT DISTINCT ON (email, u.uid) email, u.uid,
       CASE WHEN gen.r('pfm:' || i) < 0.5 THEN ''
            ELSE gen.pick('pfmsg:' || i, ARRAY['Join me on Aerly so we can see each other''s flights!',
                 'See you at the Elephant Summit?', 'Add me so you know when I land.',
                 'This is the trip app I told you about.']) END,
       gen.between(u.joined, gen.as_of() - interval '1 hour', 'pft:' || i)
FROM generate_series(1, 300 * :scale) AS i
JOIN gen.u u ON u.uid = 1 + floor(gen.r('pfu:' || i) * 2000 * :scale)::int
CROSS JOIN LATERAL (SELECT lower(replace(gen.person('invitee:' || i), ' ', '.')) || '.' || i || '@' ||
                           gen.pick('pfd:' || i, ARRAY['example.com', 'example.org', 'example.net']) AS email) e
ORDER BY email, u.uid;

-- "Always share my new trips with": partners, and a few assistants.
INSERT INTO user_auto_shares (user_id, share_with_id, role, created_at)
SELECT uid, share_with, role, created
FROM (
    SELECT p.uid, p.partner AS share_with,
           CASE WHEN gen.r('asr:' || p.uid) < 0.6 THEN 'passenger' ELSE 'viewer' END AS role,
           gen.between(greatest(u.joined, v.joined), gen.as_of() - interval '1 day', 'ast:' || p.uid) AS created
    FROM gen.partner p JOIN gen.u u ON u.uid = p.uid JOIN gen.u v ON v.uid = p.partner
    WHERE gen.r('as?' || p.uid) < 0.4
    UNION ALL
    SELECT f.uid, f.friend, 'editor', gen.between(greatest(u.joined, v.joined), gen.as_of() - interval '1 day', 'aste:' || f.uid)
    FROM gen.friend f JOIN gen.u u ON u.uid = f.uid JOIN gen.u v ON v.uid = f.friend
    WHERE f.n = 1 AND gen.r('ase?' || f.uid) < 0.03
      AND NOT EXISTS (SELECT FROM gen.partner p WHERE p.uid = f.uid AND p.partner = f.friend)
) s
ORDER BY created, uid;

--
-- Trips. Conference trips come first: a crowd that likes a conference
-- series sends many of its members. Then personal trips: holidays (often
-- with a partner), city breaks, family visits and business trips. Dates
-- are local dates; trips further than "now" thin out with distance.
--
CREATE TABLE gen.trip_raw AS
SELECT 'c' || g.gid || ':' || u.uid AS k, u.uid AS owner, NULL::bigint AS partner, 'conference' AS kind,
       g.cid AS dest, g.gid,
       g.starts - CASE WHEN gen.km(h.lat, h.lon, d.lat, d.lon) > 5000 THEN 2 ELSE 1 END
                - CASE WHEN gen.r('early:' || g.gid || ':' || u.uid) < 0.2 THEN 1 ELSE 0 END AS d_out,
       g.ends + CASE WHEN gen.r('late:' || g.gid || ':' || u.uid) < 0.35 THEN 2 ELSE 1 END AS d_ret,
       1 AS prio
FROM gen.conf g
CROSS JOIN gen.u u
JOIN gen.city h ON h.cid = u.home
JOIN gen.city d ON d.cid = g.cid
WHERE u.home <> g.cid
  AND gen.r('att:' || g.gid || ':' || u.uid)
      < g.size * 4 * gen.r('affinity:' || g.series || ':' || u.crowd) * (0.5 + u.travel)
        * CASE WHEN h.region = d.region THEN 1.0 ELSE 0.45 END
UNION ALL
SELECT t.k, t.owner, t.partner, t.kind, t.dest, NULL, t.d_out,
       t.d_out + t.nights, CASE WHEN t.partner IS NOT NULL THEN 2 ELSE 3 END
FROM (
    SELECT u.uid || ':' || j AS k, u.uid AS owner,
           CASE WHEN p.leads AND kind IN ('holiday', 'citybreak', 'family') AND gen.r('withp:' || u.uid || ':' || j) < 0.75
                THEN p.partner END AS partner,
           kind, dest, nights,
           CASE kind WHEN 'citybreak' THEN day + (5 - extract(isodow FROM day)::int + 7) % 7
                     WHEN 'business' THEN day + (1 - extract(isodow FROM day)::int + 7) % 7
                                          + CASE WHEN gen.r('tue:' || u.uid || ':' || j) < 0.4 THEN 1 ELSE 0 END
                     ELSE day END AS d_out
    FROM gen.u u
    LEFT JOIN gen.partner p ON p.uid = u.uid
    CROSS JOIN gen.bag b
    CROSS JOIN generate_series(1, 9) AS j
    CROSS JOIN LATERAL (
        SELECT CASE WHEN p.uid IS NOT NULL AND NOT p.leads AND x < 0.55 THEN 'business'
                    WHEN x < 0.35 THEN 'holiday' WHEN x < 0.55 THEN 'citybreak'
                    WHEN x < 0.70 THEN 'family' ELSE 'business' END AS kind,
               date '2025-01-04' + gen.ri('day:' || u.uid || ':' || j, 0, 815)::int AS day
        FROM (SELECT gen.r('kind:' || u.uid || ':' || j) AS x) x
    ) k
    CROSS JOIN LATERAL (
        SELECT CASE k.kind
                   WHEN 'holiday' THEN gen.pick('hd:' || u.uid || ':' || j, b.leisure)
                   WHEN 'business' THEN gen.pick('bd:' || u.uid || ':' || j, b.business)
                   WHEN 'family' THEN gen.pick('fam:' || u.uid, b.home)
                   ELSE (SELECT c.cid FROM gen.city c, gen.city h
                         WHERE h.cid = u.home AND c.cid <> u.home
                           AND gen.km(h.lat, h.lon, c.lat, c.lon) < 2500
                         ORDER BY gen.r('cb:' || u.uid || ':' || j || ':' || c.cid) LIMIT 1) END AS dest,
               CASE k.kind WHEN 'holiday' THEN gen.ri('hn:' || u.uid || ':' || j, 5, 14)
                           WHEN 'citybreak' THEN gen.ri('cn:' || u.uid || ':' || j, 2, 3)
                           WHEN 'family' THEN gen.ri('fn:' || u.uid || ':' || j, 2, 7)
                           ELSE gen.ri('bn:' || u.uid || ':' || j, 1, 3) END::int AS nights
    ) d
    WHERE j <= 1 + floor(u.travel * 8)
) t
WHERE t.dest IS NOT NULL AND t.dest <> (SELECT home FROM gen.u WHERE uid = t.owner);

-- Who is on each trip, for weeding out trips that overlap.
CREATE TABLE gen.trip_who AS
SELECT k, owner AS uid, d_out, d_ret, prio FROM gen.trip_raw
UNION ALL
SELECT k, partner, d_out, d_ret, prio FROM gen.trip_raw WHERE partner IS NOT NULL;
CREATE INDEX ON gen.trip_who (uid);

-- Keep a trip unless someone on it is already away on a more important
-- (or earlier-numbered) one; drop the far future thinly; drop trips from
-- before the owner joined, unless they imported them from TripIt.
CREATE TABLE gen.trip AS
SELECT row_number() OVER (ORDER BY t.d_out, t.k)::int AS tid, t.*,
       u.home, (t.d_out < u.joined::date) AS imported
FROM gen.trip_raw t
JOIN gen.u u ON u.uid = t.owner
WHERE NOT EXISTS (
        SELECT FROM gen.trip_who a JOIN gen.trip_who b ON b.uid = a.uid AND b.k <> a.k
        WHERE a.k = t.k
          AND daterange(b.d_out, b.d_ret + 1, '[]') && daterange(a.d_out, a.d_ret + 1, '[]')
          AND (b.prio, b.k) < (a.prio, a.k))
  AND (t.d_out <= date '2026-11-01'
       OR gen.r('future:' || t.k) < exp(-(t.d_out - date '2026-11-01') / 120.0)
       OR t.kind = 'conference')
  AND (t.d_out >= u.joined::date OR u.tripit)
  AND (t.partner IS NULL OR t.d_out >= (SELECT joined::date FROM gen.u WHERE uid = t.partner) OR u.tripit);

-- How each trip travels: by train between nearby European cities, by car
-- for short hops, otherwise by air, through a hub when the route is long
-- and there is no direct flight.
CREATE TABLE gen.trip2 AS
SELECT t.*, x.km,
       CASE WHEN x.km < 250 THEN 'car'
            WHEN x.km < 700 AND h.region = 'eu' AND d.region = 'eu' AND gen.r('train:' || t.k) < 0.65 THEN 'train'
            ELSE 'air' END AS mode,
       CASE WHEN x.km > 3000 AND gen.r('direct:' || least(h.iata, d.iata) || greatest(h.iata, d.iata)) >= 0.45 THEN
           (SELECT hub.cid FROM gen.city hub
            WHERE hub.iata IN ('LHR', 'CDG', 'AMS', 'FRA', 'IST', 'DXB', 'JFK', 'SIN')
              AND hub.cid NOT IN (h.cid, d.cid)
              AND gen.km(h.lat, h.lon, hub.lat, hub.lon) + gen.km(hub.lat, hub.lon, d.lat, d.lon) < 1.25 * x.km
            ORDER BY gen.km(h.lat, h.lon, hub.lat, hub.lon) + gen.km(hub.lat, hub.lon, d.lat, d.lon)
            LIMIT 1) END AS hub
FROM gen.trip t
JOIN gen.city h ON h.cid = t.home
JOIN gen.city d ON d.cid = t.dest
CROSS JOIN LATERAL (SELECT gen.km(h.lat, h.lon, d.lat, d.lon) AS km) x;

--
-- Transport legs. Each directed route has three flights a day at fixed
-- times, so people flying the same route on the same day often share a
-- flight. A connection takes the first onward flight at least 70 minutes
-- after landing.
--
CREATE FUNCTION gen.dep_time(o int, d int, slot int) RETURNS time
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
SELECT make_time(CASE slot WHEN 1 THEN 6 WHEN 2 THEN 11 ELSE 16 END + gen.ri('dh:' || o || '-' || d || ':' || slot, 0, 4)::int,
                 5 * gen.ri('dm:' || o || '-' || d || ':' || slot, 0, 11)::int, 0)
$$;

CREATE FUNCTION gen.block_min(km float8) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT round(km / 13.5 + 28)::int $$;

-- One row per leg: trip, direction, seq (0 or 1 for a connection), from,
-- to, scheduled times.
CREATE TABLE gen.leg AS
WITH dir AS (
    SELECT t.tid, t.k, t.mode, 'out' AS dir, t.home AS o, t.dest AS d, t.hub, t.d_out AS day FROM gen.trip2 t WHERE t.mode <> 'car'
    UNION ALL
    SELECT t.tid, t.k, t.mode, 'ret', t.dest, t.home, t.hub, t.d_ret FROM gen.trip2 t WHERE t.mode <> 'car'
), first_leg AS (
    SELECT dir.*, coalesce(dir.hub, dir.d) AS x,
           gen.ri('slot:' || dir.k || ':' || dir.dir, 1, 3)::int AS slot
    FROM dir
)
SELECT f.tid, f.k, f.mode, f.dir, 0 AS seq, f.o AS from_cid, f.x AS to_cid, f.slot, f.day,
       l.dep, l.dep + make_interval(mins => l.mins) AS arr
FROM first_leg f
JOIN gen.city o ON o.cid = f.o
JOIN gen.city x ON x.cid = f.x
CROSS JOIN LATERAL (
    SELECT CASE WHEN f.mode = 'train'
                THEN gen.lt(f.day, make_time(7 + gen.ri('th:' || f.k || f.dir, 0, 11)::int, 5 * gen.ri('tm:' || f.k || f.dir, 0, 11)::int, 0), o.tz)
                ELSE gen.lt(f.day, gen.dep_time(f.o, f.x, f.slot), o.tz) END AS dep,
           CASE WHEN f.mode = 'train' THEN round(gen.km(o.lat, o.lon, x.lat, x.lon) / 2.4 + 20)::int
                ELSE gen.block_min(gen.km(o.lat, o.lon, x.lat, x.lon)) END AS mins
) l
UNION ALL
SELECT f.tid, f.k, f.mode, f.dir, 1, f.hub, f.d, n.slot, n.day, n.dep, n.dep + make_interval(mins => gen.block_min(gen.km(h.lat, h.lon, d.lat, d.lon)))
FROM first_leg f
JOIN gen.city o ON o.cid = f.o
JOIN gen.city h ON h.cid = f.hub
JOIN gen.city d ON d.cid = f.d
CROSS JOIN LATERAL (
    SELECT s AS slot, f.day + dd AS day, gen.lt(f.day + dd, gen.dep_time(f.hub, f.d, s), h.tz) AS dep
    FROM generate_series(-1, 2) AS dd, generate_series(1, 3) AS s
    WHERE gen.lt(f.day + dd, gen.dep_time(f.hub, f.d, s), h.tz)
          >= gen.lt(f.day, gen.dep_time(f.o, f.hub, f.slot), o.tz)
             + make_interval(mins => gen.block_min(gen.km(o.lat, o.lon, h.lat, h.lon)) + 70)
    ORDER BY 3
    LIMIT 1
) n
WHERE f.hub IS NOT NULL;

-- Arrival and departure at the destination, to fit the rest of the trip
-- around. Car trips set off at 09:00 and drive back at 15:00.
CREATE TABLE gen.stay AS
SELECT t.tid, t.k, t.kind, t.owner, t.partner, t.dest, t.home, t.mode, t.gid, t.imported, t.km,
       t.d_out, t.d_ret,
       coalesce((SELECT max(arr) FROM gen.leg l WHERE l.tid = t.tid AND l.dir = 'out'),
                gen.lt(t.d_out, time '09:00', h.tz) + make_interval(mins => round(t.km / 1.3)::int)) AS arrive,
       coalesce((SELECT min(dep) FROM gen.leg l WHERE l.tid = t.tid AND l.dir = 'ret'),
                gen.lt(t.d_ret, time '15:00', d.tz)) AS leave,
       coalesce((SELECT max(arr) FROM gen.leg l WHERE l.tid = t.tid AND l.dir = 'ret'),
                gen.lt(t.d_ret, time '15:00', d.tz) + make_interval(mins => round(t.km / 1.3)::int)) AS home_again
FROM gen.trip2 t
JOIN gen.city h ON h.cid = t.home
JOIN gen.city d ON d.cid = t.dest;

-- When each trip was created: weeks or months ahead (conferences earlier),
-- never before the owner joined unless imported, and never after "now".
CREATE TABLE gen.trip_created AS
SELECT s.tid,
       CASE WHEN s.imported THEN gen.between(u.joined, u.joined + interval '2 days', 'imp:' || s.k)
            ELSE least(greatest(s.arrive - make_interval(days => CASE s.kind WHEN 'conference' THEN gen.ri('lead:' || s.k, 30, 120)
                                                                           WHEN 'business' THEN gen.ri('lead:' || s.k, 4, 30)
                                                                           ELSE gen.ri('lead:' || s.k, 10, 150) END::int,
                                                       mins => gen.ri('leadm:' || s.k, 0, 1439)::int),
                                u.joined + interval '1 hour'),
                       gen.as_of() - make_interval(mins => gen.ri('nowish:' || s.k, 30, 3000)::int)) END AS created
FROM gen.stay s JOIN gen.u u ON u.uid = s.owner;

INSERT INTO trips (id, name, destination, starts_on, ends_on, created_by, created_at, updated_at, country_code,
                   tripit_id, share_all_friends_role, place_reconciled, description)
SELECT s.tid,
       CASE s.kind
           WHEN 'conference' THEN g.name
           WHEN 'holiday' THEN gen.pick('hname:' || s.k, ARRAY[d.city || ' holiday', 'Week in ' || d.city, d.city || ' getaway',
                                                                 CASE WHEN extract(month FROM s.d_out) BETWEEN 6 AND 8 THEN 'Summer in ' ELSE 'Escape to ' END || d.city])
           WHEN 'citybreak' THEN gen.pick('cname:' || s.k, ARRAY['Weekend in ' || d.city, d.city || ' city break', d.city || ' weekend'])
           WHEN 'family' THEN gen.pick('fname:' || s.k, ARRAY['Visiting family in ' || d.city, 'Family time in ' || d.city,
                                                                d.city || ' with the family', 'Home for a few days'])
           ELSE gen.pick('bname:' || s.k, ARRAY[d.city || ' customer visit', 'Offsite in ' || d.city, d.city || ' sales meetings',
                                              d.city || ' workshop', 'Team week in ' || d.city])
       END,
       d.city || ', ' || d.country,
       s.d_out,
       (s.home_again AT TIME ZONE h.tz)::date,
       s.owner, c.created,
       gen.between(c.created, least(gen.as_of() - interval '1 minute', c.created + interval '30 days'), 'tupd:' || s.k),
       d.cc,
       CASE WHEN s.imported THEN 'tripit-' || (100000000 + s.tid * 7 + gen.ri('tiid:' || s.k, 0, 6)) ELSE '' END,
       CASE WHEN x < 0.15 THEN 'viewer' WHEN x < 0.18 THEN 'editor' END,
       gen.r('recon:' || s.k) < 0.93,
       CASE WHEN s.kind = 'conference' AND gen.r('desc:' || s.k) < 0.3 THEN
                '## ' || g.name || E'\n\nTalks, hallway track and catching up with everyone.\n\n'
                || '- [Conference site](https://' || g.series || '.example.org/)' || E'\n'
                || '- Packing: laptop, adapter, ' || gen.pick('pack:' || s.k, ARRAY['umbrella', 'sunglasses', 'warm coat', 'stickers'])
            WHEN s.kind = 'holiday' AND gen.r('desc:' || s.k) < 0.2 THEN
                'Photos: https://photos.example.com/album/' || substr(md5('album:' || s.k), 1, 12)
            ELSE '' END
FROM gen.stay s
JOIN gen.trip_created c USING (tid)
JOIN gen.city d ON d.cid = s.dest
JOIN gen.city h ON h.cid = s.home
LEFT JOIN gen.conf g ON g.gid = s.gid
CROSS JOIN LATERAL (SELECT gen.r('safr:' || s.k) AS x) x
ORDER BY s.tid;

INSERT INTO trip_tags (trip_id, label_norm, label_display)
SELECT DISTINCT ON (s.tid, lower(tag)) s.tid, lower(tag), tag
FROM gen.stay s
LEFT JOIN gen.conf g ON g.gid = s.gid
CROSS JOIN LATERAL unnest(CASE s.kind
    WHEN 'conference' THEN ARRAY['Conference', 'PostgreSQL', CASE WHEN gen.r('spk:' || s.k) < 0.2 THEN 'Speaking' END]
    WHEN 'holiday' THEN ARRAY['Holiday', CASE WHEN extract(month FROM s.d_out) IN (12, 1, 2) THEN 'Winter' ELSE gen.pick('ht:' || s.k, ARRAY['Beach', 'Sightseeing', 'Food', NULL]) END]
    WHEN 'citybreak' THEN ARRAY['Weekend', CASE WHEN gen.r('cbt:' || s.k) < 0.3 THEN 'Food' END]
    WHEN 'family' THEN ARRAY['Family']
    ELSE ARRAY['Work', CASE WHEN gen.r('wt:' || s.k) < 0.3 THEN 'Customer' END] END) AS tag
WHERE tag IS NOT NULL AND gen.r('tags?' || s.k) < 0.8
ORDER BY s.tid, lower(tag);

-- Trip members: the owner, plus friends added by hand (viewers mostly).
INSERT INTO trip_members (trip_id, user_id, role, added_at)
SELECT tid, uid, role, added
FROM (
  SELECT DISTINCT ON (tid, uid) * FROM (
    SELECT s.tid, s.owner AS uid, 'owner' AS role, c.created AS added, 0 AS j
    FROM gen.stay s JOIN gen.trip_created c USING (tid)
    UNION ALL
    SELECT s.tid, f.friend, CASE WHEN gen.r('mrole:' || s.k || ':' || j) < 0.2 THEN 'editor' ELSE 'viewer' END,
           gen.between(greatest(c.created, f.since), least(gen.as_of() - interval '1 minute', greatest(c.created, f.since) + interval '20 days'),
                       'madd:' || s.k || ':' || j), j
    FROM gen.stay s
    JOIN gen.trip_created c USING (tid)
    CROSS JOIN generate_series(1, 3) AS j
    JOIN gen.friend f ON f.uid = s.owner AND f.n = 1 + floor(gen.r('mem:' || s.k || ':' || j) * f.cnt)
    WHERE gen.r('mem?' || s.k) < 0.3 AND j <= gen.ri('memn:' || s.k, 1, 3)
      AND f.friend IS DISTINCT FROM s.partner
  ) a
  ORDER BY tid, uid, j
) m
ORDER BY added, tid, uid;

INSERT INTO trip_passengers (trip_id, user_id, added_at)
SELECT s.tid, s.partner,
       least(greatest(c.created, p.joined) + make_interval(mins => gen.ri('tpadd:' || s.k, 1, 90)::int), gen.as_of() - interval '1 minute')
FROM gen.stay s JOIN gen.trip_created c USING (tid) JOIN gen.u p ON p.uid = s.partner
WHERE s.partner IS NOT NULL
ORDER BY 3, 1;

INSERT INTO trip_reminder_optin (trip_id, user_id, lead_hours)
SELECT s.tid, s.owner, gen.pick('trl:' || s.k, ARRAY[24, 24, 48, 12, 72])
FROM gen.stay s
WHERE gen.r('tro?' || s.k) < 0.08
ORDER BY 1;

--
-- Plans and their parts. gen.plan has one row per plan, gen.part one row
-- per part, and d carries the satellite table's columns. Rebooked flights
-- get a new part (ver 1, 2) that supersedes the cancelled one.
--
CREATE TABLE gen.plan (
    pk text PRIMARY KEY, tid int, type text, title text, confirmation_ref text, notes text, source text,
    created timestamptz, ticket_number text, cost_amount numeric, cost_currency text, supplier_name text,
    contact_email text, contact_phone text, website text, sort_ts timestamptz, owner bigint
);

CREATE TABLE gen.part (
    pk text, seq int, ver int, starts_at timestamptz, ends_at timestamptz, start_tz text, end_tz text,
    start_label text, start_lat float8, start_lon float8, end_label text, end_lat float8, end_lon float8,
    status text, start_address text, end_address text, start_tz_source text, end_tz_source text,
    created timestamptz, dismissed timestamptz, d jsonb
);

-- gen.booked(trip created, starts, key): when a plan was booked.
CREATE FUNCTION gen.booked(created timestamptz, starts timestamptz, k text) RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT gen.between(created, least(gen.as_of() - interval '5 minutes', greatest(created, starts - interval '2 days')), 'bk:' || k) $$;

-- Flight and train bookings: one plan per direction.
INSERT INTO gen.plan
SELECT l.k || ':' || l.dir, l.tid, CASE WHEN l.mode = 'air' THEN 'flight' ELSE 'train' END,
       o.city || ' to ' || d.city,
       gen.code('pnr:' || l.k || l.dir, 6),
       CASE WHEN gen.r('pnote:' || l.k || l.dir) < 0.1
            THEN gen.pick('pnt:' || l.k || l.dir, ARRAY['Window seat booked', 'Checked bag included', 'Lounge access via card',
                                                        'Aisle please', 'Seat 12A', 'Bring the rail pass']) ELSE '' END,
       CASE WHEN x < 0.45 THEN 'manual' WHEN x < 0.7 THEN 'email' WHEN x < 0.85 THEN 'paste' ELSE 'upload' END,
       gen.booked(c.created, l.dep, l.k || l.dir),
       CASE WHEN l.mode = 'air' AND gen.r('tkt?' || l.k || l.dir) < 0.6
            THEN lpad(gen.ri('tkp:' || l.k, 100, 999)::text, 3, '0') || lpad(gen.ri('tkn:' || l.k || l.dir, 0, 9999999999)::text, 10, '0') ELSE '' END,
       CASE WHEN gen.r('cost?' || l.k || l.dir) < 0.7 THEN
           round((CASE WHEN l.mode = 'air' THEN 45 + 0.09 * s.km * (0.7 + 0.8 * gen.r('fare:' || l.k || l.dir))
                       ELSE 20 + 0.12 * s.km * (0.7 + 0.6 * gen.r('fare:' || l.k || l.dir)) END * hc.fx)::numeric,
                 CASE WHEN hc.fx > 20 THEN -1 ELSE 2 END) END,
       hc.currency,
       CASE WHEN l.mode = 'air' THEN a.name ELSE gen.pick('rail:' || least(l.from_cid, l.to_cid) || '-' || greatest(l.from_cid, l.to_cid),
                                                          ARRAY['Continental Rail', 'Channel Link', 'Alpine Express', 'Nordlink', 'Danube Rail', 'Peninsula Rail']) END,
       '', '', '', l.dep, s.owner
FROM gen.leg l
JOIN gen.stay s ON s.tid = l.tid
JOIN gen.trip_created c ON c.tid = l.tid
JOIN gen.city hc ON hc.cid = s.home
JOIN gen.city o ON o.cid = CASE WHEN l.dir = 'out' THEN s.home ELSE s.dest END
JOIN gen.city d ON d.cid = CASE WHEN l.dir = 'out' THEN s.dest ELSE s.home END
JOIN gen.airline a ON a.aid = 1 + gen.ri('al:' || least(l.from_cid, l.to_cid) || '-' || greatest(l.from_cid, l.to_cid), 0, 7)
CROSS JOIN LATERAL (SELECT gen.r('src:' || l.k || l.dir) AS x) x
WHERE l.seq = 0;

-- Flight legs with what happened to them. A flight's fate (delay, gate,
-- cancellation) is keyed by the flight and its date, so everyone on board
-- shares it. Delays are mostly small with a long tail, a few flights are
-- diverted, and about 2% are cancelled a few hours before departure. A
-- cancellation rebooks the traveller's whole booking onto the same flights
-- a day later (ver 1), which can be cancelled in turn (ver 2): the new
-- parts supersede the old ones.
CREATE TABLE gen.fl0 AS
SELECT l.*, l.k || ':' || l.dir AS bk, l.k || ':' || l.dir || ':' || l.seq AS lk,
       1 + gen.ri('al:' || least(l.from_cid, l.to_cid) || '-' || greatest(l.from_cid, l.to_cid), 0, 7)::int AS aid,
       100 + ((l.from_cid - 1) * 39 + (l.to_cid - 1)) * 3 + l.slot AS fno,
       v.ver, v.dep_v, v.dep_v + (l.arr - l.dep) AS arr_v,
       l.from_cid || '-' || l.to_cid || ':' || l.slot || ':' || (v.dep_v AT TIME ZONE o.tz)::date AS fk
FROM gen.leg l
JOIN gen.city o ON o.cid = l.from_cid
CROSS JOIN generate_series(0, 2) AS ver
CROSS JOIN LATERAL (SELECT ver, gen.lt((l.dep AT TIME ZONE o.tz)::date + ver, (l.dep AT TIME ZONE o.tz)::time, o.tz) AS dep_v) v
WHERE l.mode = 'air';

CREATE TABLE gen.fl1 AS
SELECT f.*, x.cancelled_at,
       x.cancelled_at <= gen.as_of() AND gen.r('cx:' || f.fk) < 0.02 AS flight_cancelled
FROM gen.fl0 f
CROSS JOIN LATERAL (SELECT f.dep_v - make_interval(hours => gen.ri('cxt:' || f.fk, 2, 20)::int) AS cancelled_at) x;

-- A booking version is superseded when any of its flights is cancelled;
-- version n exists when every earlier one was superseded.
CREATE TABLE gen.bv AS
SELECT bk, ver, bool_or(flight_cancelled) AS superseded,
       min(cancelled_at) FILTER (WHERE flight_cancelled) AS superseded_at
FROM gen.fl1 GROUP BY bk, ver;

CREATE UNIQUE INDEX ON gen.bv (bk, ver);

CREATE TABLE gen.fl AS
SELECT f.*, bv.superseded AS cancelled, bv.superseded_at,
       (SELECT p.superseded_at FROM gen.bv p WHERE p.bk = f.bk AND p.ver = f.ver - 1) AS rebooked_at,
       CASE WHEN gen.r('late:' || f.fk) < 0.06 THEN gen.ri('tail:' || f.fk, 45, 240)
            ELSE greatest(-8, round(4 + 14 * gen.normal('delay:' || f.fk))) END::int AS delay,
       round(6 * gen.normal('blk:' || f.fk))::int AS block_var,
       gen.r('div:' || f.fk) < 0.003 AS diverted
FROM gen.fl1 f
JOIN gen.bv ON bv.bk = f.bk AND bv.ver = f.ver
WHERE f.ver = 0
   OR (f.ver = 1 AND (SELECT superseded FROM gen.bv p WHERE p.bk = f.bk AND p.ver = 0))
   OR (f.ver = 2 AND (SELECT bool_and(superseded) FROM gen.bv p WHERE p.bk = f.bk AND p.ver < 2));

CREATE TABLE gen.fl2 AS
SELECT f.*, a.iata || f.fno AS ident, a.icao || f.fno AS callsign,
       o.iata AS o_iata, d.iata AS d_iata, o.city AS o_city, d.city AS d_city, o.tz AS o_tz, d.tz AS d_tz,
       o.lat AS o_lat, o.lon AS o_lon, d.lat AS d_lat, d.lon AS d_lon,
       gen.km(o.lat, o.lon, d.lat, d.lon) AS km,
       x.act_out, x.act_in,
       CASE WHEN f.flight_cancelled THEN 'Cancelled'
            WHEN x.act_in <= gen.as_of() AND f.diverted THEN 'Diverted'
            WHEN x.act_in <= gen.as_of() THEN 'Arrived'
            WHEN x.act_out <= gen.as_of() THEN 'Enroute'
            WHEN x.act_out - interval '15 minutes' <= gen.as_of() THEN 'GateClosed'
            ELSE 'Scheduled' END AS status
FROM gen.fl f
JOIN gen.airline a ON a.aid = f.aid
JOIN gen.city o ON o.cid = f.from_cid
JOIN gen.city d ON d.cid = f.to_cid
CROSS JOIN LATERAL (SELECT f.dep_v + make_interval(mins => f.delay) AS act_out,
                           f.arr_v + make_interval(mins => f.delay + f.block_var) AS act_in) x;

INSERT INTO gen.part
SELECT f.k || ':' || f.dir, f.seq, f.ver, f.dep_v, f.arr_v, f.o_tz, f.d_tz,
       f.o_city || ' (' || f.o_iata || ')', f.o_lat, f.o_lon, f.d_city || ' (' || f.d_iata || ')', f.d_lat, f.d_lon,
       CASE WHEN f.cancelled THEN 'cancelled' WHEN gen.r('planned:' || f.bk) < 0.05 AND f.dep_v > gen.as_of() THEN 'planned' ELSE 'confirmed' END,
       '', '', 'confirmed', 'confirmed',
       -- imported trips were entered after the fact, rebookings included
       CASE WHEN f.ver = 0 THEN p.created ELSE greatest(p.created, f.rebooked_at + interval '7 minutes') END,
       CASE WHEN f.cancelled AND gen.r('dism:' || f.bk || f.ver) < 0.7
            THEN least(f.superseded_at + make_interval(mins => gen.ri('dismt:' || f.bk || f.ver, 10, 600)::int), gen.as_of() - interval '1 minute') END,
       jsonb_build_object(
           'ident', f.ident,
           'icao24', CASE WHEN f.status <> 'Cancelled' AND f.dep_v < gen.as_of() + interval '1 day'
                          THEN lpad(to_hex(gen.ri('icao:' || f.fk, x'300000'::int, x'4fffff'::int)::int), 6, '0') END,
           'callsign', CASE WHEN f.dep_v < gen.as_of() + interval '1 day' THEN f.callsign END,
           'scheduled_out', f.dep_v, 'scheduled_in', f.arr_v,
           'estimated_out', CASE WHEN f.status <> 'Cancelled' AND f.dep_v < gen.as_of() + interval '2 days' THEN f.act_out END,
           'estimated_in', CASE WHEN f.status <> 'Cancelled' AND f.dep_v < gen.as_of() + interval '2 days' THEN f.act_in END,
           'actual_out', CASE WHEN f.status IN ('Arrived', 'Diverted', 'Enroute') THEN f.act_out END,
           'actual_in', CASE WHEN f.status IN ('Arrived', 'Diverted') THEN f.act_in END,
           'origin_iata', f.o_iata, 'dest_iata', f.d_iata, 'flight_status', f.status,
           'last_polled_at', CASE WHEN f.status IN ('Arrived', 'Diverted', 'Cancelled') THEN least(CASE WHEN f.status = 'Cancelled' THEN f.cancelled_at ELSE f.act_in END + make_interval(mins => gen.ri('lp:' || f.fk, 1, 9)::int), gen.as_of() - interval '1 minute')
                                  WHEN f.dep_v < gen.as_of() + interval '2 days' THEN gen.as_of() - make_interval(secs => gen.ri('lp:' || f.fk, 5, 3500)::int) END,
           'last_resolved_at', p.created + interval '40 seconds',
           'last_alert_sig', CASE WHEN f.status IN ('Cancelled', 'Diverted') OR f.delay >= 15 THEN substr(md5('sig:' || f.fk), 1, 16) END,
           'origin_gate', CASE WHEN f.status <> 'Cancelled' AND f.dep_v < gen.as_of() + interval '1 day'
                               THEN gen.pick('og:' || f.fk, ARRAY['A', 'B', 'C', 'D']) || gen.ri('ogn:' || f.fk, 1, 48) END,
           'dest_gate', CASE WHEN f.status IN ('Arrived', 'Enroute', 'Diverted')
                             THEN gen.pick('dg:' || f.fk, ARRAY['A', 'B', 'C', 'D', 'E']) || gen.ri('dgn:' || f.fk, 1, 60) END,
           'origin_terminal', CASE WHEN f.dep_v < gen.as_of() + interval '1 day' THEN gen.ri('ot:' || f.o_iata || f.aid, 1, 3)::text END,
           'dest_terminal', CASE WHEN f.dep_v < gen.as_of() + interval '1 day' THEN gen.ri('ot:' || f.d_iata || f.aid, 1, 3)::text END,
           'aircraft_type', CASE WHEN f.km < 1500 THEN gen.pick('ac:' || f.ident, ARRAY['A20N', 'B38M', 'E195', 'A21N', 'A320'])
                                 WHEN f.km < 4500 THEN gen.pick('ac:' || f.ident, ARRAY['A21N', 'B39M', 'A321', 'B738'])
                                 ELSE gen.pick('ac:' || f.ident, ARRAY['A359', 'B789', 'B77W', 'A339', 'A35K']) END,
           'dest_baggage_belt', CASE WHEN f.status = 'Arrived' THEN gen.ri('belt:' || f.fk, 1, 14)::text END,
           'resolved', gen.r('unres:' || f.bk) >= 0.03)
FROM gen.fl2 f
JOIN gen.plan p ON p.pk = f.k || ':' || f.dir;

-- Train legs.
INSERT INTO gen.part
SELECT l.k || ':' || l.dir, 0, 0, l.dep, l.arr, o.tz, d.tz,
       o.city || ' Central', o.clat, o.clon, d.city || ' Central', d.clat, d.clon,
       'confirmed', '', '', 'confirmed', 'confirmed', p.created, NULL,
       jsonb_build_object(
           'operator', p.supplier_name,
           'service_no', gen.pick('tsn:' || l.from_cid || '-' || l.to_cid, ARRAY['EC', 'IC', 'RJ', 'ES', 'EN'])
                         || ' ' || (100 + (l.from_cid * 41 + l.to_cid) % 900),
           'coach', gen.ri('coach:' || l.k || l.dir, 1, 14)::text,
           'seat', gen.ri('tseat:' || l.k || l.dir, 11, 98)::text,
           'class', CASE WHEN gen.r('tcl:' || l.k || l.dir) < 0.25 THEN '1st' ELSE '2nd' END,
           'platform', CASE WHEN l.dep < gen.as_of() + interval '1 day' THEN gen.ri('plat:' || l.k || l.dir, 1, 18)::text ELSE '' END)
FROM gen.leg l
JOIN gen.city o ON o.cid = l.from_cid
JOIN gen.city d ON d.cid = l.to_cid
JOIN gen.plan p ON p.pk = l.k || ':' || l.dir
WHERE l.mode = 'train';

-- Somewhere to stay (not when visiting family, usually), from check-in to
-- check-out.
CREATE TABLE gen.hotel AS
SELECT s.*, c.created AS trip_created, d.city, d.country, d.tz, d.clat, d.clon, d.dial, d.currency, d.fx, d.iata,
       greatest(gen.lt((s.arrive AT TIME ZONE d.tz)::date, time '15:00', d.tz), s.arrive + interval '1 hour') AS checkin,
       least(gen.lt((s.leave AT TIME ZONE d.tz)::date, time '11:00', d.tz), s.leave - interval '150 minutes') AS checkout,
       gen.pick('hp:' || s.k, ARRAY['Hotel', 'Hotel', 'The', 'Casa', 'Grand Hotel', 'Pension']) || ' '
           || gen.pick('hw:' || s.k, ARRAY['Lighthouse', 'Harbour View', 'Old Town', 'Riverside', 'Linden', 'Atlas',
                                          'Courtyard Garden', 'Blue Door', 'Station', 'Clocktower', 'Cedar', 'Two Bridges']) AS property
FROM gen.stay s
JOIN gen.trip_created c USING (tid)
JOIN gen.city d ON d.cid = s.dest
WHERE s.kind <> 'family' OR gen.r('famhotel:' || s.k) < 0.25;

-- No room needed when the stay doesn't span a night (a long flight in, a
-- flight out the same day).
DELETE FROM gen.hotel WHERE checkout < checkin + interval '8 hours';

INSERT INTO gen.plan
SELECT h.k || ':hotel', h.tid, 'hotel', h.property, gen.code('hconf:' || h.k, 8), '',
       CASE WHEN x < 0.4 THEN 'manual' WHEN x < 0.75 THEN 'email' WHEN x < 0.9 THEN 'paste' ELSE 'upload' END,
       gen.booked(h.trip_created, h.checkin, h.k || 'h'), '',
       CASE WHEN gen.r('hcost?' || h.k) < 0.75 THEN
           round((greatest(1, (h.checkout::date - h.checkin::date)) * (70 + 110 * gen.r('rate:' || h.k)) * h.fx)::numeric,
                 CASE WHEN h.fx > 20 THEN -1 ELSE 2 END) END,
       h.currency,
       CASE WHEN gen.r('hsup:' || h.k) < 0.5 THEN gen.pick('hsn:' || h.k, ARRAY['StayFinder', 'RoomHub', 'Nightly']) ELSE h.property END,
       CASE WHEN gen.r('hce:' || h.k) < 0.3 THEN 'reservations@' || lower(replace(h.property, ' ', '')) || '.example.com' ELSE '' END,
       CASE WHEN gen.r('hcp:' || h.k) < 0.4 THEN gen.phone(h.dial, 'hph:' || h.k) ELSE '' END,
       CASE WHEN gen.r('hweb:' || h.k) < 0.3 THEN 'https://www.' || lower(replace(h.property, ' ', '')) || '.example.com/' ELSE '' END,
       h.checkin, h.owner
FROM gen.hotel h
CROSS JOIN LATERAL (SELECT gen.r('hsrc:' || h.k) AS x) x;

INSERT INTO gen.part
SELECT h.k || ':hotel', 0, 0, h.checkin, h.checkout, h.tz, h.tz,
       h.property, round((h.clat + 0.03 * (gen.r('hla:' || h.k) - 0.5))::numeric, 5), round((h.clon + 0.04 * (gen.r('hlo:' || h.k) - 0.5))::numeric, 5),
       h.property, NULL, NULL,
       CASE WHEN gen.r('hpl:' || h.k) < 0.08 AND h.checkin > gen.as_of() THEN 'planned' ELSE 'confirmed' END,
       a.address, a.address, 'inferred', 'inferred', p.created, NULL,
       jsonb_build_object(
           'property_name', h.property, 'address', a.address,
           'phone', CASE WHEN gen.r('hdp:' || h.k) < 0.6 THEN gen.phone(h.dial, 'hph:' || h.k) ELSE '' END,
           'room_type', gen.pick('room:' || h.k, ARRAY['Double room', 'Twin room', 'Single room', 'Studio', 'Junior suite', '']),
           'guests', CASE WHEN h.partner IS NOT NULL THEN 2 WHEN gen.r('gst:' || h.k) < 0.8 THEN 1 END,
           'standard_checkin', CASE WHEN gen.r('stdci:' || h.k) < 0.6 THEN gen.pick('sci:' || h.k, ARRAY['14:00', '15:00', '15:00', '16:00']) END,
           'standard_checkout', CASE WHEN gen.r('stdci:' || h.k) < 0.6 THEN gen.pick('sco:' || h.k, ARRAY['10:00', '11:00', '11:00', '12:00']) END,
           'kind', gen.pick('hkind:' || h.k, ARRAY['', '', 'hotel', 'hotel', 'apartment', 'guesthouse', 'hostel', 'B&B']))
FROM gen.hotel h
JOIN gen.plan p ON p.pk = h.k || ':hotel'
CROSS JOIN LATERAL (SELECT gen.ri('hn:' || h.k, 1, 120) || ' ' || gen.pick('hstr:' || h.k, ARRAY['Rua', 'Avenue', 'Strasse', 'Street', 'Via', 'Plaza'])
                           || ' ' || gen.pick('hstn:' || h.k, ARRAY['do Sol', 'des Fleurs', 'Garten', 'Harbour', 'Roma', 'Mayor', 'Market', 'Linden'])
                           || ', ' || h.city || ', ' || h.country AS address) a;

-- Everything else: taxis from the airport, hire cars, restaurants,
-- excursions, concerts and matches, meetings and ice cream.
CREATE TABLE gen.extra AS
SELECT s.*, c.created AS trip_created, d.city, d.country, d.tz, d.clat, d.clon, d.dial, d.currency, d.fx, d.iata,
       h.property, h.checkin,
       greatest(1, (s.leave AT TIME ZONE d.tz)::date - (s.arrive AT TIME ZONE d.tz)::date) AS days,
       (s.arrive AT TIME ZONE d.tz)::date AS first_day,
       (SELECT last FROM gen.u WHERE uid = s.owner) AS owner_last
FROM gen.stay s
JOIN gen.trip_created c USING (tid)
JOIN gen.city d ON d.cid = s.dest
LEFT JOIN gen.hotel h USING (tid);

CREATE TABLE gen.other AS
-- taxi from the airport (or station) to the hotel
SELECT e.k || ':taxi' AS pk, 'ground' AS type, 'Transfer to ' || e.property AS title,
       e.arrive + interval '25 minutes' AS starts_at, e.arrive + make_interval(mins => 45 + gen.ri('tx:' || e.k, 0, 30)::int) AS ends_at,
       CASE WHEN e.mode = 'air' THEN e.city || ' (' || e.iata || ')' ELSE e.city || ' Central' END AS start_label, e.property AS end_label,
       'inferred' AS tzs, e.*, 0 AS n
FROM gen.extra e
WHERE e.mode IN ('air', 'train') AND e.property IS NOT NULL AND gen.r('taxi?' || e.k) < 0.45
UNION ALL
SELECT e.k || ':car', 'vehicle_hire', 'Hire car', e.arrive + interval '40 minutes', e.leave - interval '150 minutes',
       e.city || ' (' || e.iata || ')', e.city || ' (' || e.iata || ')', 'inferred', e.*, 0
FROM gen.extra e
WHERE e.mode = 'air' AND e.kind IN ('holiday', 'family') AND gen.r('car?' || e.k) < 0.3
UNION ALL
SELECT e.k || ':dine' || n, 'dining',
       gen.pick('rn:' || e.k || n, ARRAY['Taberna', 'Bistro', 'Trattoria', 'Brasserie', 'Kitchen', 'Osteria', 'Cantina', 'Supper Club'])
           || ' ' || gen.pick('rw:' || e.k || n, ARRAY['Azul', 'Olive', 'Lantern', 'Copper Pot', 'Fig Tree', 'Harbour', 'Saffron', 'Juniper', 'Little Owl']),
       gen.lt(e.first_day + gen.ri('dd:' || e.k || n, 0, e.days - 1)::int,
              make_time(19 + gen.ri('dh:' || e.k || n, 0, 1)::int, 30 * gen.ri('dm:' || e.k || n, 0, 1)::int, 0), e.tz),
       NULL, '', '',
       CASE WHEN gen.r('float:' || e.k || n) < 0.3 THEN 'floating' ELSE 'inferred' END, e.*, n
FROM gen.extra e, generate_series(1, 3) AS n
WHERE n <= CASE e.kind WHEN 'holiday' THEN gen.ri('dn:' || e.k, 0, 3) WHEN 'citybreak' THEN gen.ri('dn:' || e.k, 1, 2)
                       WHEN 'family' THEN gen.ri('dn:' || e.k, 0, 1) ELSE gen.ri('dn:' || e.k, 0, 2) END
UNION ALL
SELECT e.k || ':exc' || n, 'excursion',
       gen.pick('ex:' || e.k || n, ARRAY['Old town walking tour', 'Day trip to the coast', 'Boat tour', 'Food market tour',
                                        'Museum pass', 'Wine tasting', 'Cycling tour', 'Cooking class']),
       gen.lt(e.first_day + gen.ri('xd:' || e.k || n, 0, e.days - 1)::int, make_time(9 + gen.ri('xh:' || e.k || n, 0, 4)::int, 30 * gen.ri('xm:' || e.k || n, 0, 1)::int, 0), e.tz),
       NULL, e.city, e.city, 'inferred', e.*, n
FROM gen.extra e, generate_series(1, 2) AS n
WHERE e.kind = 'holiday' AND n <= gen.ri('xn:' || e.k, 0, 2)
UNION ALL
SELECT e.k || ':event', 'event',
       gen.pick('evp:' || e.k, ARRAY['The Velvet Foxes', 'Midnight Lanterns', 'Danube String Quartet', 'Saltwater',
                                    'City derby', 'The Clockmaker''s Daughter', 'Jazz at the Old Mill', 'Copper Comets']),
       gen.lt(e.first_day + gen.ri('evd:' || e.k, 0, e.days - 1)::int, time '19:30', e.tz),
       NULL, e.city, e.city, 'inferred', e.*, 0
FROM gen.extra e
WHERE e.kind IN ('holiday', 'citybreak') AND gen.r('event?' || e.k) < 0.2
UNION ALL
SELECT e.k || ':meet' || n, 'meeting',
       CASE WHEN e.kind = 'conference' THEN gen.pick('cm:' || e.k || n, ARRAY['Speaker briefing', 'Program committee', 'Sponsor meeting', 'Community dinner planning'])
            ELSE gen.pick('bm:' || e.k || n, ARRAY['Quarterly review', 'Architecture workshop', 'Customer kickoff', 'Migration planning',
                                                  'Performance review session', 'Contract negotiation']) END,
       gen.lt(e.first_day + least(gen.ri('md:' || e.k || n, 0, e.days)::int, e.days - 1),
              make_time(9 + gen.ri('mh:' || e.k || n, 0, 7)::int, 0, 0), e.tz),
       NULL, e.city, e.city, 'inferred', e.*, n
FROM gen.extra e, generate_series(1, 3) AS n
WHERE (e.kind = 'business' AND n <= gen.ri('mn:' || e.k, 1, 3))
   OR (e.kind = 'conference' AND n = 1 AND gen.r('cmeet?' || e.k) < 0.2)
UNION ALL
SELECT e.k || ':ice' || n, 'ice_cream',
       gen.pick('icn:' || e.k || n, ARRAY['Gelateria', 'Sorveteria', 'Creamery', 'Glacier', 'Scoop']) || ' '
           || gen.pick('icw:' || e.k || n, ARRAY['Luna', 'do Mar', 'Bella', 'Polar', 'Twin Cones', 'Lemon Tree']),
       gen.lt(e.first_day + gen.ri('icd:' || e.k || n, 0, e.days - 1)::int, make_time(15 + gen.ri('ich:' || e.k || n, 0, 2)::int, 15 * gen.ri('icm:' || e.k || n, 0, 3)::int, 0), e.tz),
       NULL, e.city, e.city, 'inferred', e.*, n
FROM gen.extra e, generate_series(1, 2) AS n
WHERE e.kind IN ('holiday', 'citybreak') AND extract(month FROM e.first_day) BETWEEN 4 AND 10
  AND n <= gen.ri('icn:' || e.k, 0, 2);

INSERT INTO gen.plan
SELECT o.pk, o.tid, o.type, o.title,
       CASE WHEN o.type IN ('vehicle_hire', 'excursion', 'event') OR (o.type = 'dining' AND gen.r('dref:' || o.pk) < 0.3)
            THEN gen.code('ref:' || o.pk, 7) ELSE '' END,
       CASE WHEN o.type = 'dining' AND gen.r('dnote:' || o.pk) < 0.15 THEN gen.pick('dnt:' || o.pk, ARRAY['Terrace table', 'Tasting menu', 'Vegetarian options', 'Birthday!'])
            WHEN o.type = 'meeting' AND gen.r('mnote:' || o.pk) < 0.3 THEN 'Agenda in the shared drive'
            ELSE '' END,
       CASE WHEN o.type IN ('vehicle_hire', 'event', 'excursion') AND gen.r('osrc:' || o.pk) < 0.4 THEN 'email'
            WHEN gen.r('osrc:' || o.pk) < 0.1 THEN 'paste' ELSE 'manual' END,
       gen.booked(o.trip_created, o.starts_at, o.pk), '',
       CASE WHEN o.type IN ('vehicle_hire', 'excursion', 'event') THEN
           round(((CASE o.type WHEN 'vehicle_hire' THEN 35 * greatest(1, o.days) WHEN 'excursion' THEN 30 + 60 * gen.r('xc:' || o.pk)
                               ELSE 40 + 80 * gen.r('evc:' || o.pk) END) * o.fx)::numeric, CASE WHEN o.fx > 20 THEN -1 ELSE 2 END) END,
       CASE WHEN o.type IN ('vehicle_hire', 'excursion', 'event') THEN o.currency ELSE '' END,
       CASE o.type WHEN 'ground' THEN gen.pick('gp:' || o.pk, ARRAY['City Cabs', 'Blue Line Transfers', 'Airport Shuttle Co', 'Metro Taxi'])
                   WHEN 'vehicle_hire' THEN gen.pick('vh:' || o.pk, ARRAY['Drive Away', 'Roadrunner Rentals', 'Open Road Hire'])
                   WHEN 'excursion' THEN gen.pick('xp:' || o.pk, ARRAY['Local Trails', 'City Walks Co', 'Sea and Sun Tours'])
                   ELSE '' END,
       '', CASE WHEN o.type IN ('dining', 'ground') THEN gen.phone(o.dial, 'oph:' || o.pk) ELSE '' END, '',
       o.starts_at, o.owner
FROM gen.other o;

INSERT INTO gen.part
SELECT o.pk, 0, 0,
       CASE WHEN o.tzs = 'floating' THEN (o.starts_at AT TIME ZONE o.tz) AT TIME ZONE 'UTC' ELSE o.starts_at END,
       CASE WHEN o.tzs = 'floating' THEN (o.starts_at AT TIME ZONE o.tz + interval '2 hours') AT TIME ZONE 'UTC'
            WHEN o.type = 'dining' THEN o.starts_at + interval '2 hours'
            WHEN o.type = 'excursion' THEN o.starts_at + make_interval(hours => gen.ri('xl:' || o.pk, 2, 7)::int)
            WHEN o.type = 'event' THEN o.starts_at + interval '150 minutes'
            WHEN o.type = 'meeting' THEN o.starts_at + make_interval(mins => 60 * gen.ri('ml:' || o.pk, 1, 3)::int)
            ELSE o.ends_at END,
       CASE WHEN o.tzs = 'floating' THEN '' ELSE o.tz END,
       CASE WHEN o.tzs = 'floating' OR o.type = 'ice_cream' THEN '' ELSE o.tz END,
       CASE WHEN o.type = 'dining' THEN o.title ELSE o.start_label END,
       CASE WHEN o.tzs = 'floating' THEN NULL ELSE round((o.clat + 0.04 * (gen.r('ola:' || o.pk) - 0.5))::numeric, 5) END,
       CASE WHEN o.tzs = 'floating' THEN NULL ELSE round((o.clon + 0.05 * (gen.r('olo:' || o.pk) - 0.5))::numeric, 5) END,
       coalesce(o.end_label, ''), NULL, NULL,
       CASE WHEN o.type IN ('dining', 'ice_cream', 'meeting') THEN 'planned' ELSE 'confirmed' END,
       '', '',
       o.tzs,
       CASE WHEN o.tzs = 'floating' THEN 'floating' WHEN o.type = 'ice_cream' THEN 'unknown' ELSE o.tzs END,
       p.created, NULL,
       CASE o.type
           WHEN 'ground' THEN jsonb_build_object('provider', p.supplier_name, 'phone', p.contact_phone,
                                                 'vehicle', gen.pick('gv:' || o.pk, ARRAY['Sedan', 'Estate', 'Minivan', 'Electric sedan', '']),
                                                 'driver', CASE WHEN gen.r('gd:' || o.pk) < 0.5 THEN gen.person('driver:' || o.pk) ELSE '' END,
                                                 'pax', CASE WHEN o.partner IS NOT NULL THEN 2 ELSE 1 END)
           WHEN 'vehicle_hire' THEN jsonb_build_object(
                'category', gen.pick('vc:' || o.pk, ARRAY['Economy', 'Compact', 'Intermediate', 'SUV', 'Estate', 'Campervan']),
                'vehicle', gen.pick('vv:' || o.pk, ARRAY['Small hatchback or similar', 'Compact estate or similar', 'Mid-size SUV or similar', 'Electric hatchback or similar']),
                'transmission', CASE WHEN gen.r('vt:' || o.pk) < 0.6 THEN 'Manual' ELSE 'Automatic' END,
                'fuel_policy', gen.pick('vf:' || o.pk, ARRAY['Full to full', 'Full to full', 'Same to same', '']),
                'mileage', gen.pick('vm:' || o.pk, ARRAY['Unlimited', 'Unlimited', '200 km/day', '']),
                'excess_amount', CASE WHEN gen.r('vex?' || o.pk) < 0.8 THEN round((800 + 100 * gen.ri('vex:' || o.pk, 0, 12)) * o.fx) END,
                'excess_currency', CASE WHEN gen.r('vex?' || o.pk) < 0.8 THEN o.currency ELSE '' END,
                'deposit_amount', CASE WHEN gen.r('vdp?' || o.pk) < 0.6 THEN round((200 + 50 * gen.ri('vdp:' || o.pk, 0, 10)) * o.fx) END,
                'deposit_currency', CASE WHEN gen.r('vdp?' || o.pk) < 0.6 THEN o.currency ELSE '' END)
           WHEN 'dining' THEN jsonb_build_object('party_size', CASE WHEN o.partner IS NOT NULL THEN 2 ELSE gen.ri('ps:' || o.pk, 1, 6) END,
                                                 'reservation_name', CASE WHEN gen.r('rnm:' || o.pk) < 0.7 THEN o.owner_last ELSE '' END,
                                                 'phone', p.contact_phone)
           WHEN 'excursion' THEN jsonb_build_object('provider', p.supplier_name,
                                                    'ticket_count', CASE WHEN o.partner IS NOT NULL THEN 2 ELSE 1 END)
           WHEN 'event' THEN jsonb_build_object('performer', o.title,
                                                'category', CASE WHEN o.title = 'City derby' THEN 'Sport' WHEN o.title LIKE 'The Clock%' THEN 'Theatre' ELSE 'Concert' END,
                                                'venue_area', gen.pick('va:' || o.pk, ARRAY['Stalls', 'Balcony', 'Standing', 'Block 112', '']),
                                                'url', 'https://tickets.example.com/e/' || substr(md5('ev:' || o.pk), 1, 10))
           WHEN 'meeting' THEN jsonb_build_object('location', CASE WHEN gen.r('mloc:' || o.pk) < 0.8 THEN 'Office, ' || o.city ELSE '' END,
                                                  'organiser', gen.person('org:' || o.pk),
                                                  'platform', CASE WHEN gen.r('mpl:' || o.pk) < 0.25 THEN 'Video call' ELSE '' END)
           WHEN 'ice_cream' THEN jsonb_build_object('rating', CASE WHEN o.starts_at < gen.as_of() THEN least(5, 2 + gen.ri('icr:' || o.pk, 0, 3) + gen.ri('icr2:' || o.pk, 0, 1)) ELSE 0 END,
                                                    'what_ordered', gen.pick('ico:' || o.pk, ARRAY['Pistachio and lemon', 'Stracciatella', 'Salted caramel',
                                                        'Dark chocolate and raspberry', 'Mango sorbet', 'Hazelnut', 'Two scoops of vanilla', '']))
       END
FROM gen.other o
JOIN gen.plan p ON p.pk = o.pk;

-- Plans and parts get their ids in time order.
CREATE TABLE gen.plan_id AS
SELECT p.pk, row_number() OVER (ORDER BY p.tid, p.sort_ts, p.pk)::bigint AS id FROM gen.plan p;
CREATE UNIQUE INDEX ON gen.plan_id (pk);

CREATE TABLE gen.part_id AS
SELECT pt.pk, pt.seq, pt.ver, row_number() OVER (ORDER BY pi.id, pt.seq, pt.ver)::bigint AS id
FROM gen.part pt JOIN gen.plan_id pi USING (pk);
CREATE UNIQUE INDEX ON gen.part_id (pk, seq, ver);

INSERT INTO plans (id, trip_id, type, title, confirmation_ref, notes, source, created_by, created_at, updated_at,
                   tripit_uid, ticket_number, cost_amount, cost_currency, supplier_name, contact_email, contact_phone,
                   website, share_all_friends)
SELECT pi.id, p.tid, p.type, p.title, p.confirmation_ref, p.notes, p.source, p.owner, p.created,
       gen.between(p.created, least(gen.as_of() - interval '1 minute', p.created + interval '10 days'), 'pupd:' || p.pk),
       CASE WHEN s.imported THEN 'tripit-item-' || substr(md5('tiu:' || p.pk), 1, 12) ELSE '' END,
       p.ticket_number, p.cost_amount, CASE WHEN p.cost_amount IS NULL THEN '' ELSE p.cost_currency END,
       p.supplier_name, p.contact_email, p.contact_phone, p.website,
       gen.r('psaf:' || p.pk) < 0.04
FROM gen.plan p
JOIN gen.plan_id pi USING (pk)
JOIN gen.stay s ON s.tid = p.tid
ORDER BY pi.id;

INSERT INTO plan_parts (id, plan_id, seq, starts_at, ends_at, start_tz, end_tz, start_label, start_lat, start_lon,
                        end_label, end_lat, end_lon, status, supersedes_id, dismissed_at, created_at, updated_at,
                        start_address, end_address, start_coords_pinned, end_coords_pinned, start_tz_source, end_tz_source)
SELECT pti.id, pi.id, pt.seq, pt.starts_at, pt.ends_at, pt.start_tz, pt.end_tz, pt.start_label, pt.start_lat, pt.start_lon,
       pt.end_label, pt.end_lat, pt.end_lon, pt.status, prev.id, pt.dismissed, pt.created,
       greatest(pt.created, coalesce(pt.dismissed, pt.created)),
       pt.start_address, pt.end_address,
       gen.r('pin:' || pt.pk) < 0.03, false, pt.start_tz_source, pt.end_tz_source
FROM gen.part pt
JOIN gen.plan_id pi USING (pk)
JOIN gen.part_id pti USING (pk, seq, ver)
LEFT JOIN gen.part_id prev ON prev.pk = pt.pk AND prev.seq = pt.seq AND prev.ver = pt.ver - 1
ORDER BY pti.id;

INSERT INTO flight_details
SELECT pti.id, d->>'ident', d->>'icao24', d->>'callsign',
       (d->>'scheduled_out')::timestamptz, (d->>'scheduled_in')::timestamptz,
       (d->>'estimated_out')::timestamptz, (d->>'estimated_in')::timestamptz,
       (d->>'actual_out')::timestamptz, (d->>'actual_in')::timestamptz,
       d->>'origin_iata', d->>'dest_iata', d->>'flight_status',
       (d->>'last_polled_at')::timestamptz, (d->>'last_resolved_at')::timestamptz, d->>'last_alert_sig',
       d->>'origin_gate', d->>'dest_gate', d->>'origin_terminal', d->>'dest_terminal',
       d->>'aircraft_type', d->>'dest_baggage_belt', (d->>'resolved')::boolean
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'ident'
ORDER BY pti.id;

INSERT INTO train_details
SELECT pti.id, d->>'operator', d->>'service_no', d->>'coach', d->>'seat', d->>'class', d->>'platform'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'service_no' ORDER BY pti.id;

INSERT INTO hotel_details
SELECT pti.id, d->>'property_name', d->>'address', d->>'phone', d->>'room_type', (d->>'guests')::int,
       (d->>'standard_checkin')::time, (d->>'standard_checkout')::time, d->>'kind'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'property_name' ORDER BY pti.id;

INSERT INTO ground_details
SELECT pti.id, d->>'provider', d->>'phone', d->>'vehicle', d->>'driver', (d->>'pax')::int
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'pax' ORDER BY pti.id;

INSERT INTO vehicle_hire_details
SELECT pti.id, d->>'category', d->>'vehicle', d->>'transmission', d->>'fuel_policy', d->>'mileage',
       (d->>'excess_amount')::numeric, d->>'excess_currency', (d->>'deposit_amount')::numeric, d->>'deposit_currency'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'transmission' ORDER BY pti.id;

INSERT INTO dining_details
SELECT pti.id, (d->>'party_size')::int, d->>'reservation_name', d->>'phone'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'party_size' ORDER BY pti.id;

INSERT INTO excursion_details
SELECT pti.id, d->>'provider', (d->>'ticket_count')::int
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'ticket_count' ORDER BY pti.id;

INSERT INTO event_details
SELECT pti.id, d->>'performer', d->>'category', d->>'venue_area', d->>'url'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'performer' ORDER BY pti.id;

INSERT INTO meeting_details
SELECT pti.id, d->>'location', d->>'organiser', d->>'platform'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'organiser' ORDER BY pti.id;

INSERT INTO ice_cream_details
SELECT pti.id, (d->>'rating')::smallint, d->>'what_ordered'
FROM gen.part pt JOIN gen.part_id pti USING (pk, seq, ver)
WHERE d ? 'rating' ORDER BY pti.id;

--
-- Who sees and hears about each plan
--

-- Privacy: now and then a dinner on a shared trip is a surprise, hidden
-- from the partner; a few conference meetings are only for one member.
INSERT INTO plan_visibility (plan_id, mode)
SELECT pi.id, v.mode
FROM gen.plan p
JOIN gen.plan_id pi USING (pk)
JOIN gen.stay s ON s.tid = p.tid
CROSS JOIN LATERAL (
    SELECT 'hidden_from' AS mode, s.partner AS uid
    WHERE p.type = 'dining' AND s.partner IS NOT NULL AND gen.r('surprise:' || p.pk) < 0.12
    UNION ALL
    SELECT 'only_visible_to', (SELECT m.user_id FROM trip_members m WHERE m.trip_id = p.tid AND m.role <> 'owner'
                               ORDER BY gen.r('ovm:' || p.pk || ':' || m.user_id) LIMIT 1)
    WHERE p.type = 'meeting' AND gen.r('ovt:' || p.pk) < 0.5
) v
WHERE v.uid IS NOT NULL
GROUP BY pi.id, v.mode
ORDER BY pi.id;

INSERT INTO plan_visibility_members (plan_id, user_id)
SELECT pi.id, v.uid
FROM gen.plan p
JOIN gen.plan_id pi USING (pk)
JOIN plan_visibility pv ON pv.plan_id = pi.id
JOIN gen.stay s ON s.tid = p.tid
CROSS JOIN LATERAL (
    SELECT s.partner AS uid WHERE pv.mode = 'hidden_from'
    UNION ALL
    SELECT (SELECT m.user_id FROM trip_members m WHERE m.trip_id = p.tid AND m.role <> 'owner'
            ORDER BY gen.r('ovm:' || p.pk || ':' || m.user_id) LIMIT 1)
    WHERE pv.mode = 'only_visible_to'
) v
ORDER BY 1, 2;

-- Passengers: the traveller on their own bookings, and trip passengers
-- copied onto every plan they may see (via_trip), as Aerly does.
INSERT INTO plan_passengers (plan_id, user_id, added_at, via_trip)
SELECT pi.id, s.owner, p.created, false
FROM gen.plan p JOIN gen.plan_id pi USING (pk) JOIN gen.stay s ON s.tid = p.tid
WHERE p.type IN ('flight', 'train', 'hotel', 'ground', 'vehicle_hire', 'excursion', 'event')
UNION ALL
SELECT pl.id, tp.user_id, greatest(pl.created_at, tp.added_at), true
FROM plans pl
JOIN trip_passengers tp ON tp.trip_id = pl.trip_id
WHERE plan_visible_to_member(pl.id, tp.user_id)
ORDER BY 1, 2;

-- Friends following a flight's alerts.
INSERT INTO plan_alert_optin (plan_id, user_id)
SELECT pl.id, m.user_id
FROM plans pl JOIN trip_members m ON m.trip_id = pl.trip_id AND m.role <> 'owner'
WHERE pl.type = 'flight' AND gen.r('pao:' || pl.id || ':' || m.user_id) < 0.3
ORDER BY 1, 2;

INSERT INTO plan_reminder_optin (plan_id, user_id, enabled, lead_hours)
SELECT pl.id, pl.created_by, gen.r('proe:' || pl.id) >= 0.1, gen.pick('prol:' || pl.id, ARRAY[24, 24, 2, 3, 12, 48])
FROM plans pl
WHERE gen.r('pro?' || pl.id) < 0.07
ORDER BY 1;

INSERT INTO plan_links (plan_id, "position", title, url, created_at)
SELECT pl.id, n - 1,
       CASE pl.type WHEN 'flight' THEN (ARRAY['E-ticket', 'Boarding pass', 'Manage booking'])[n]
                    WHEN 'hotel' THEN (ARRAY['Booking', 'Directions', 'House rules'])[n]
                    WHEN 'event' THEN (ARRAY['Tickets', 'Venue info', 'Setlist'])[n]
                    ELSE (ARRAY['Booking', 'Map', 'Menu'])[n] END,
       'https://' || CASE pl.type WHEN 'flight' THEN 'book.' WHEN 'hotel' THEN 'stay.' ELSE 'www.' END
           || 'example.com/' || substr(md5('link:' || pl.id || ':' || n), 1, 16),
       gen.between(pl.created_at, least(gen.as_of() - interval '1 minute', pl.created_at + interval '5 days'), 'lnk:' || pl.id || n)
FROM plans pl, generate_series(1, 3) AS n
WHERE gen.r('links?' || pl.id) < 0.15 AND n <= gen.ri('linkn:' || pl.id, 1, 3)
ORDER BY 1, 2;

-- Attachments: the PDF behind every uploaded booking, and a few more.
INSERT INTO plan_attachments (plan_id, uploaded_by, filename, content_type, size_bytes, storage_key, created_at)
SELECT pl.id, CASE WHEN gen.r('upby:' || pl.id) < 0.02 THEN NULL ELSE pl.created_by END,
       CASE pl.type WHEN 'flight' THEN 'eticket-' || lower(pl.confirmation_ref) || '.pdf'
                    WHEN 'hotel' THEN 'booking-confirmation.pdf'
                    WHEN 'train' THEN 'ticket-' || lower(pl.confirmation_ref) || '.pdf'
                    ELSE 'voucher.pdf' END,
       'application/pdf', gen.ri('asz:' || pl.id, 40000, 900000),
       'att/' || to_char(pl.created_at, 'YYYY/MM') || '/' || md5('att:' || pl.id) || '.pdf',
       pl.created_at
FROM plans pl
WHERE pl.source = 'upload' OR gen.r('att?' || pl.id) < 0.03
UNION ALL
SELECT pl.id, pl.created_by, 'boarding-pass-' || lower(fd.ident) || '.png', 'image/png', gen.ri('bpsz:' || pp.id, 30000, 200000),
       'att/' || to_char(fd.scheduled_out - interval '1 day', 'YYYY/MM') || '/' || md5('bp:' || pp.id) || '.png',
       fd.scheduled_out - interval '23 hours'
FROM plans pl JOIN plan_parts pp ON pp.plan_id = pl.id JOIN flight_details fd ON fd.plan_part_id = pp.id
WHERE gen.r('bp?' || pp.id) < 0.08 AND fd.scheduled_out - interval '23 hours' < gen.as_of() AND pp.status <> 'cancelled'
ORDER BY 7, 1;

--
-- Flight tracks: a position every two minutes for every flight in the
-- air during the two weeks before "now", along the great circle. Over the
-- middle of long ocean crossings there is no ADS-B coverage, so those fixes
-- are dead-reckoned (is_estimated).
--
CREATE TABLE gen.track AS
SELECT pp.id AS part_id, fd.actual_out + interval '12 minutes' AS off,
       coalesce(fd.actual_in, fd.estimated_in) - interval '6 minutes' AS land,
       radians(o.lat) AS p1, radians(o.lon) AS l1, radians(d.lat) AS p2, radians(d.lon) AS l2,
       gen.km(o.lat, o.lon, d.lat, d.lon) AS km,
       -- keyed by the flight, so everyone on board gets the same track
       34000 + 1000 * gen.ri('fl:' || fd.ident || fd.scheduled_out, 0, 5) AS cruise_ft,
       440 + gen.ri('gs:' || fd.ident || fd.scheduled_out, 0, 50) AS cruise_kt
FROM plan_parts pp
JOIN flight_details fd ON fd.plan_part_id = pp.id
JOIN gen.city o ON o.iata = fd.origin_iata
JOIN gen.city d ON d.iata = fd.dest_iata
WHERE fd.actual_out IS NOT NULL AND fd.actual_out >= gen.as_of() - interval '14 days';

INSERT INTO positions (ts, lat, lon, altitude_ft, groundspeed_kt, heading_deg, is_estimated, plan_part_id)
SELECT ts, round(degrees(phi)::numeric, 5), round(degrees(lam)::numeric, 5),
       (round(t.cruise_ft * least(1, m.mins / 22, (g.total - m.mins) / 28) / 100) * 100)::int,
       round(150 + (t.cruise_kt - 150) * least(1, m.mins / 15, (g.total - m.mins) / 20))::int,
       ((round(degrees(atan2(sin(t.l2 - lam) * cos(t.p2),
                             cos(phi) * sin(t.p2) - sin(phi) * cos(t.p2) * cos(t.l2 - lam))))::int + 360) % 360)::smallint,
       t.km > 4500 AND m.f BETWEEN 0.35 AND 0.75,
       t.part_id
FROM gen.track t
CROSS JOIN LATERAL (SELECT extract(epoch FROM t.land - t.off) / 60 AS total,
                           acos(least(1, sin(t.p1) * sin(t.p2) + cos(t.p1) * cos(t.p2) * cos(t.l2 - t.l1))) AS delta) g
CROSS JOIN LATERAL generate_series(t.off, least(t.land, gen.as_of()), interval '2 minutes') AS ts
CROSS JOIN LATERAL (SELECT extract(epoch FROM ts - t.off) / 60 AS mins,
                           extract(epoch FROM ts - t.off) / 60 / g.total AS f) m
CROSS JOIN LATERAL (SELECT sin((1 - m.f) * g.delta) / sin(g.delta) AS a, sin(m.f * g.delta) / sin(g.delta) AS b) w
CROSS JOIN LATERAL (SELECT w.a * cos(t.p1) * cos(t.l1) + w.b * cos(t.p2) * cos(t.l2) AS x,
                           w.a * cos(t.p1) * sin(t.l1) + w.b * cos(t.p2) * sin(t.l2) AS y,
                           w.a * sin(t.p1) + w.b * sin(t.p2) AS z) v
CROSS JOIN LATERAL (SELECT atan2(v.z, sqrt(v.x * v.x + v.y * v.y)) AS phi, atan2(v.y, v.x) AS lam) p
ORDER BY t.part_id, ts;

--
-- Alerts. Everyone who flies, and friends who opted in, hear about
-- delays, gate changes, cancellations and diversions; opt-ins get a
-- check-in nudge 24 hours ahead and a departure summary 4 hours ahead.
--
CREATE TABLE gen.recip AS
SELECT pp.plan_id, pp.user_id FROM plan_passengers pp JOIN plans pl ON pl.id = pp.plan_id WHERE pl.type = 'flight'
UNION
SELECT plan_id, user_id FROM plan_alert_optin;

CREATE TABLE gen.alert AS
SELECT r.user_id, pp.id AS part_id, pp.plan_id, pl.trip_id, fd.ident, a.kind, a.status, a.message, a.created_at,
       fd.scheduled_out
FROM gen.recip r
JOIN gen.pref pr ON pr.uid = r.user_id
JOIN plans pl ON pl.id = r.plan_id
JOIN plan_parts pp ON pp.plan_id = pl.id
JOIN flight_details fd ON fd.plan_part_id = pp.id
JOIN gen.city o ON o.iata = fd.origin_iata
CROSS JOIN LATERAL (
    SELECT extract(epoch FROM fd.estimated_out - fd.scheduled_out)::int / 60 AS delay,
           to_char(fd.scheduled_out AT TIME ZONE o.tz, 'HH24:MI') AS sched_local,
           to_char(fd.estimated_out AT TIME ZONE o.tz, 'HH24:MI') AS est_local,
           fd.origin_iata || ' → ' || fd.dest_iata AS route
) x
CROSS JOIN LATERAL (
    SELECT 'departure' AS kind, 'Scheduled' AS status,
           fd.ident || ' ' || x.route || ' departs at ' || x.sched_local
               || coalesce(' from terminal ' || fd.origin_terminal, '') AS message,
           fd.scheduled_out - interval '4 hours' AS created_at
    WHERE pr.departure_summary AND r.user_id IN (SELECT user_id FROM plan_passengers z WHERE z.plan_id = pl.id)
    UNION ALL
    SELECT 'checkin', 'Scheduled', 'Online check-in for ' || fd.ident || ' ' || x.route || ' opens in 5 minutes',
           fd.scheduled_out - interval '24 hours 5 minutes'
    WHERE pr.checkin AND r.user_id IN (SELECT user_id FROM plan_passengers z WHERE z.plan_id = pl.id)
    UNION ALL
    SELECT 'delayed', fd.flight_status, fd.ident || ' ' || x.route || ' is delayed ' || x.delay || ' min, now departing ' || x.est_local,
           fd.scheduled_out - make_interval(mins => gen.ri('dla:' || pp.id, 20, 150)::int)
    WHERE fd.flight_status <> 'Cancelled' AND x.delay >= pr.min_delay
    UNION ALL
    SELECT 'gate', fd.flight_status, fd.ident || ' ' || x.route || ' now departs from gate ' || fd.origin_gate,
           fd.scheduled_out - make_interval(mins => gen.ri('gta:' || pp.id, 35, 90)::int)
    WHERE fd.origin_gate IS NOT NULL AND gen.r('gatechg:' || pp.id) < 0.25
    UNION ALL
    SELECT 'cancelled', 'Cancelled', fd.ident || ' ' || x.route || ' on ' || to_char(fd.scheduled_out AT TIME ZONE o.tz, 'DD Mon') || ' has been cancelled',
           fd.last_polled_at - interval '5 minutes'
    WHERE fd.flight_status = 'Cancelled'
    UNION ALL
    SELECT 'diverted', 'Diverted', fd.ident || ' ' || x.route || ' has been diverted', fd.actual_in - interval '40 minutes'
    WHERE fd.flight_status = 'Diverted'
) a
WHERE pr.in_app AND a.created_at < gen.as_of()
  AND (pp.status <> 'cancelled' OR a.kind = 'cancelled');

INSERT INTO flight_alerts (user_id, plan_part_id, plan_id, trip_id, ident, kind, status, message, created_at, read_at)
SELECT user_id, part_id, plan_id, trip_id, ident, kind, status, message, created_at,
       CASE WHEN gen.r('read:' || part_id || ':' || user_id || kind) < CASE WHEN created_at < gen.as_of() - interval '3 days' THEN 0.93 ELSE 0.5 END
            THEN least(created_at + make_interval(mins => gen.ri('rd:' || part_id || user_id || kind, 1, 2000)::int), gen.as_of() - interval '1 minute') END
FROM gen.alert
UNION ALL
-- Reminders, for any plan: Aerly reuses the flight inbox and puts the
-- plan's title in ident and its type in status.
SELECT r.user_id, pp.id, pl.id, pl.trip_id, pl.title, 'reminder', pl.type, 'Reminder: ' || pl.title,
       pp.starts_at - make_interval(hours => r.lead_hours), NULL
FROM (SELECT pro.plan_id, pro.user_id, pro.lead_hours FROM plan_reminder_optin pro WHERE pro.enabled
      UNION
      SELECT pl.id, tro.user_id, tro.lead_hours
      FROM trip_reminder_optin tro JOIN plans pl ON pl.trip_id = tro.trip_id
      WHERE NOT EXISTS (SELECT FROM plan_reminder_optin pro WHERE pro.plan_id = pl.id AND pro.user_id = tro.user_id)) r
JOIN plans pl ON pl.id = r.plan_id
JOIN plan_parts pp ON pp.plan_id = pl.id AND pp.status <> 'cancelled'
WHERE pp.starts_at - make_interval(hours => r.lead_hours) < gen.as_of()
ORDER BY 9, 2, 1;

-- Reminders older than a few days have been read.
UPDATE flight_alerts SET read_at = created_at + interval '20 minutes'
WHERE kind = 'reminder' AND created_at < gen.as_of() - interval '2 days' AND gen.r('rrd:' || id) < 0.9;

INSERT INTO plan_reminder_sent (plan_part_id, user_id, sent_at)
SELECT plan_part_id, user_id, created_at FROM flight_alerts WHERE kind = 'reminder' ORDER BY 3, 1, 2;

INSERT INTO flight_checkin_sent (plan_part_id, user_id, sent_at)
SELECT plan_part_id, user_id, created_at + interval '2 seconds' FROM flight_alerts WHERE kind = 'checkin' ORDER BY 3, 1, 2;

INSERT INTO flight_departure_summary_sent (plan_part_id, user_id, sent_at)
SELECT plan_part_id, user_id, created_at + interval '2 seconds' FROM flight_alerts WHERE kind = 'departure' ORDER BY 3, 1, 2;

-- Sharing notices: someone added you to their trip.
INSERT INTO notifications (user_id, kind, actor_id, trip_id, plan_id, message, created_at, read_at)
SELECT m.user_id, 'share', t.created_by, t.id, NULL::bigint,
       u.name || ' shared the trip "' || t.name || '" with you' || CASE WHEN m.role = 'editor' THEN ' as an editor' ELSE '' END,
       m.added_at,
       CASE WHEN gen.r('nrd:' || m.trip_id || ':' || m.user_id) < CASE WHEN m.added_at < gen.as_of() - interval '7 days' THEN 0.95 ELSE 0.4 END
            THEN least(m.added_at + make_interval(mins => gen.ri('nrt:' || m.trip_id || m.user_id, 1, 3000)::int), gen.as_of() - interval '1 minute') END
FROM trip_members m
JOIN trips t ON t.id = m.trip_id
JOIN users u ON u.id = t.created_by
WHERE m.role <> 'owner'
UNION ALL
SELECT tp.user_id, 'share', t.created_by, t.id, NULL::bigint,
       u.name || ' added you as a passenger on "' || t.name || '"', tp.added_at,
       CASE WHEN tp.added_at < gen.as_of() - interval '2 days' THEN tp.added_at + interval '3 hours' END
FROM trip_passengers tp
JOIN trips t ON t.id = tp.trip_id
JOIN users u ON u.id = t.created_by
ORDER BY 7, 1;

-- Shares with people who have no account yet.
INSERT INTO pending_shares (email_lower, kind, target_id, role, inviter_id, created_at)
SELECT lower(replace(gen.person('guest:' || x.id), ' ', '.')) || '.' || x.id || '@example.net',
       x.kind, x.id, CASE WHEN x.kind = 'trip' THEN 'viewer' END, x.owner,
       gen.between(x.created, gen.as_of() - interval '1 hour', 'psh:' || x.kind || x.id)
FROM (SELECT 'trip' AS kind, id, created_by AS owner, created_at AS created FROM trips WHERE gen.r('pshare:' || id) < 0.03
      UNION ALL
      SELECT 'plan', id, created_by, created_at FROM plans WHERE type IN ('hotel', 'dining') AND gen.r('pshare:p' || id) < 0.004) x
ORDER BY 6, 3;

--
-- Forwarded booking emails: one per plan that came in by email, plus the
-- ones that didn't work out.
--
INSERT INTO email_ingests (received_at, message_id, from_address, subject, dkim_pass, user_id, status,
                           flights_added, flights_failed, error)
SELECT received_at, message_id, from_address, subject, dkim_pass, user_id, status, flights_added, flights_failed, error
FROM (
    SELECT pl.created_at - interval '9 seconds' AS received_at,
           '<' || md5('msg:' || pl.id) || '@mail.example.com>' AS message_id,
           e.address AS from_address,
           CASE pl.type WHEN 'flight' THEN 'Fwd: Your booking confirmation ' || pl.confirmation_ref
                        WHEN 'hotel' THEN 'Fwd: Reservation confirmed - ' || pl.title
                        ELSE 'Fwd: Booking ' || pl.confirmation_ref END AS subject,
           true AS dkim_pass, pl.created_by AS user_id,
           CASE WHEN pl.type = 'flight' AND gen.r('part:' || pl.id) < 0.05 THEN 'partial' ELSE 'ok' END AS status,
           CASE WHEN pl.type = 'flight' THEN (SELECT count(*) FROM plan_parts pp WHERE pp.plan_id = pl.id AND pp.supersedes_id IS NULL) ELSE 0 END AS flights_added,
           CASE WHEN pl.type = 'flight' AND gen.r('part:' || pl.id) < 0.05 THEN 1 ELSE 0 END AS flights_failed,
           CASE WHEN pl.type = 'flight' AND gen.r('part:' || pl.id) < 0.05 THEN 'could not resolve one flight' ELSE '' END AS error
    FROM plans pl
    JOIN user_emails e ON e.user_id = pl.created_by AND e.is_primary
    WHERE pl.source = 'email'
    UNION ALL
    SELECT gen.between(u.joined, gen.as_of() - interval '1 hour', 'bad:' || i),
           '<' || md5('badmsg:' || i) || '@mail.example.com>',
           CASE WHEN s.status = 'no_user' THEN 'someone.' || i || '@example.org' ELSE e.address END,
           gen.pick('bsub:' || i, ARRAY['Fwd: Your itinerary', 'Fwd: Newsletter', 'Fwd: Receipt', 'Fwd: Trip details', 'Fwd: Booking update']),
           gen.r('dkim:' || i) < 0.9,
           CASE WHEN s.status = 'no_user' THEN NULL ELSE u.uid END,
           s.status, 0,
           CASE WHEN s.status = 'all_failed' THEN gen.ri('af:' || i, 1, 2) ELSE 0 END,
           CASE s.status WHEN 'all_failed' THEN 'no flight matched the date and number'
                         WHEN 'nothing_found' THEN 'no bookings found in message'
                         WHEN 'no_user' THEN 'sender is not a verified address'
                         WHEN 'rate_limited' THEN 'too many messages in the last hour' END
    FROM generate_series(1, 150 * :scale) AS i
    JOIN gen.u u ON u.uid = 1 + floor(gen.r('badu:' || i) * 2000 * :scale)::int
    JOIN gen.email e ON e.uid = u.uid AND e.n = 1
    CROSS JOIN LATERAL (SELECT gen.pick('bst:' || i, ARRAY['nothing_found', 'nothing_found', 'nothing_found', 'all_failed', 'no_user', 'no_user', 'rate_limited']) AS status) s
) x
ORDER BY received_at, message_id;

--
-- Conference schedules as calendar feeds: some attendees subscribe their
-- trip to the conference's .ics feed of talks.
--
CREATE TABLE gen.talk AS
SELECT g.gid, d AS day, n,
       gen.lt(d, make_time(CASE WHEN n = 0 THEN 9 ELSE 9 + n END, CASE WHEN n = 0 THEN 0 ELSE 30 END, 0), c.tz) AS starts_at,
       CASE WHEN n = 0 THEN 'Keynote: ' || gen.pick('kn:' || g.gid || d, ARRAY['Twenty years of MVCC', 'The elephant in the cloud',
                                         'Why your query is slow', 'Postgres at planet scale', 'What''s next for the community'])
            ELSE gen.pick('tt:' || g.gid || d || n, ARRAY['Partitioning without tears', 'Understanding EXPLAIN', 'Logical replication in practice',
                    'Indexes you didn''t know you needed', 'Vacuum demystified', 'Time zones are hard', 'Writing a background worker',
                    'Row-level security in multi-tenant apps', 'Upgrading with zero downtime', 'JSON or columns?',
                    'Connection pooling explained', 'Backups you can restore', 'Recursive CTEs for fun and profit',
                    'Tuning autovacuum', 'Extensions in Rust', 'Monitoring that matters'])
                 || ' (' || gen.person('speaker:' || g.gid || d || n) || ')' END AS summary,
       CASE WHEN n = 0 THEN 'Main hall' ELSE gen.pick('room:' || g.gid || d || n, ARRAY['Room A', 'Room B', 'Room C']) END AS room,
       c.tz, c.city
FROM gen.conf g
JOIN gen.city c ON c.cid = g.cid
CROSS JOIN LATERAL generate_series(g.starts, g.ends, interval '1 day') AS dd
CROSS JOIN LATERAL (SELECT dd::date AS d) x
CROSS JOIN generate_series(0, 7) AS n;

INSERT INTO trip_feeds (trip_id, url, name, etag, last_modified, last_fetched_at, last_error, created_at, updated_at, timezone)
SELECT s.tid, 'https://' || g.series || '.example.org/' || extract(year FROM g.starts) || '/schedule.ics',
       g.name || ' schedule',
       '"' || substr(md5('etag:' || g.gid), 1, 16) || '"',
       to_char(least(g.starts - 3, date '2026-10-31'), 'Dy, DD Mon YYYY') || ' 08:00:00 GMT',
       least(gen.as_of() - interval '20 minutes', g.ends + interval '2 days'),
       CASE WHEN gen.r('ferr:' || s.k) < 0.03 THEN 'GET: 503 Service Unavailable' ELSE '' END,
       f.created, f.created, ''
FROM gen.stay s
JOIN gen.conf g ON g.gid = s.gid
JOIN gen.trip_created c USING (tid)
CROSS JOIN LATERAL (SELECT gen.between(c.created, least(gen.as_of() - interval '1 hour', g.starts - 1), 'fc:' || s.k) AS created) f
WHERE gen.r('feed?' || s.k) < 0.25
ORDER BY f.created, s.tid;

INSERT INTO trip_feed_events (feed_id, uid, summary, description, location, starts_at, ends_at, start_tz, all_day, start_tz_source)
SELECT f.id, md5('talk:' || t.gid || ':' || t.day || ':' || t.n) || '@' || g.series || '.example.org',
       t.summary, '', t.room || ', ' || t.city, t.starts_at,
       t.starts_at + CASE WHEN t.n = 0 THEN interval '60 minutes' ELSE interval '50 minutes' END,
       t.tz, false, 'confirmed'
FROM trip_feeds f
JOIN gen.stay s ON s.tid = f.trip_id
JOIN gen.conf g ON g.gid = s.gid
JOIN gen.talk t ON t.gid = g.gid
UNION ALL
-- each feed also has an all-day "conference day" event per day
SELECT f.id, md5('day:' || g.gid || ':' || d) || '@' || g.series || '.example.org',
       g.name || ' day ' || (d - g.starts + 1), '', c.city, (d::timestamp AT TIME ZONE 'UTC'), NULL, '', true, 'unknown'
FROM trip_feeds f
JOIN gen.stay s ON s.tid = f.trip_id
JOIN gen.conf g ON g.gid = s.gid
JOIN gen.city c ON c.cid = g.cid
CROSS JOIN LATERAL generate_series(g.starts, g.ends, interval '1 day') AS dd
CROSS JOIN LATERAL (SELECT dd::date AS d) x
ORDER BY 1, 6, 2;

-- Calendar feed tokens.
INSERT INTO calendar_tokens (user_id, scope, token, created_at, resource_id)
SELECT user_id, scope, md5('cal:' || user_id || scope || resource_id) || md5('cal2:' || user_id || scope || resource_id),
       created, resource_id
FROM (
    SELECT uid AS user_id, 'me' AS scope, 0::bigint AS resource_id, gen.between(joined, gen.as_of() - interval '1 hour', 'calme:' || uid) AS created
    FROM gen.u WHERE gen.r('calme?' || uid) < 0.3
    UNION ALL
    SELECT uid, 'friends', 0, gen.between(joined, gen.as_of() - interval '1 hour', 'calfr:' || uid)
    FROM gen.u WHERE gen.r('calfr?' || uid) < 0.1
    UNION ALL
    SELECT created_by, 'trip', id, gen.between(created_at, gen.as_of() - interval '1 hour', 'caltr:' || id)
    FROM trips WHERE gen.r('caltr?' || id) < 0.04
) s
ORDER BY created, user_id;

--
-- Point the sequences past the explicit ids, and clean up.
--
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'trips', 'plans', 'plan_parts'] LOOP
        EXECUTE format('SELECT setval(pg_get_serial_sequence(%L, ''id''), (SELECT max(id) FROM %I))', t, t);
    END LOOP;
END
$$;

DROP SCHEMA gen CASCADE;
ANALYZE;
