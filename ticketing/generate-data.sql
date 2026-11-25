--
-- pg_fil: ticketing -- sample data generator
--
-- Run after schema.sql, into an empty database:
--   psql -d ticketing -f generate-data.sql
--   psql -d ticketing -v scale=3 -f generate-data.sql     -- 3x the customers
--
-- The output is deterministic: every "random" choice is a hash of a key
-- string (see gen.r below), never random() or the clock, so the same scale
-- always gives the same rows on any server, in any time zone.
--
-- Events run from 2025-07 to 2027-03 and the data is "as of" 2026-11-01:
-- earlier events are completed, later ones are on sale (with a few seats
-- held by buyers at that moment) or not on sale yet. The venues and events
-- are the same at every scale; customers grow with it.
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
    IF EXISTS (SELECT FROM venue) THEN
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

--
-- Venues and their seating plans: level > stand > section, or level >
-- area where stands have no sections of their own.
--
CREATE TABLE gen.venue AS
SELECT * FROM (VALUES
    (1, 'Harbour Theatre', 'London', 'GB', 'Europe/London', 'GBP',
        ARRAY['Stalls', 'Dress Circle', 'Upper Circle'], ARRAY['Left', 'Centre', 'Right'],
        ARRAY[1, 0, 1], 0, 12, 15, 1.0),
    (2, 'Grand Concert Hall', 'Vienna', 'AT', 'Europe/Vienna', 'EUR',
        ARRAY['Parterre', 'Balcony'], ARRAY['Left', 'Centre', 'Right'],
        ARRAY[1, 0, 1], 0, 16, 18, 1.15),
    (3, 'Riverside Arena', 'Rotterdam', 'NL', 'Europe/Amsterdam', 'EUR',
        ARRAY['Lower Tier', 'Upper Tier'], ARRAY['North', 'East', 'South', 'West'],
        ARRAY[1, 0, 1, 0], 4, 10, 14, 1.15),
    (4, 'Old Town Comedy Club', 'Prague', 'CZ', 'Europe/Prague', 'CZK',
        ARRAY['Floor'], ARRAY['Front', 'Back'],
        ARRAY[0, 1], 0, 8, 14, 25.0),
    (5, 'Northfield Stadium', 'Manchester', 'GB', 'Europe/London', 'GBP',
        ARRAY['Lower Tier', 'Upper Tier'], ARRAY['North Stand', 'East Stand', 'South Stand', 'West Stand'],
        ARRAY[1, 0, 1, 0], 4, 12, 16, 1.0)
) AS v(venue_id, name, city, cc, tz, currency, levels, stands, stand_penalty, nsections, nrows, nseats, fx);

INSERT INTO venue (venue_id, name, city, country_code, timezone, currency)
SELECT venue_id, name, city, cc, tz, currency FROM gen.venue ORDER BY venue_id;

INSERT INTO section (venue_id, parent_id, name, view_rank)
SELECT v.venue_id, NULL, l.name, NULL
FROM gen.venue v, unnest(v.levels) WITH ORDINALITY AS l(name, n)
ORDER BY v.venue_id, l.n;

INSERT INTO section (venue_id, parent_id, name, view_rank)
SELECT v.venue_id, lv.section_id, st.name,
       CASE WHEN v.nsections = 0 THEN l.n + v.stand_penalty[st.n] END
FROM gen.venue v,
     unnest(v.levels) WITH ORDINALITY AS l(name, n),
     unnest(v.stands) WITH ORDINALITY AS st(name, n),
     LATERAL (SELECT section_id FROM section s
              WHERE s.venue_id = v.venue_id AND s.parent_id IS NULL AND s.name = l.name) AS lv
ORDER BY v.venue_id, l.n, st.n;

-- Numbered sections: 101-116 on the lower tier, 201-216 on the upper.
INSERT INTO section (venue_id, parent_id, name, view_rank)
SELECT v.venue_id, sd.section_id, (100 * l.n + 4 * (st.n - 1) + k)::text,
       l.n + v.stand_penalty[st.n] + CASE WHEN k IN (1, 4) THEN 1 ELSE 0 END
FROM gen.venue v,
     unnest(v.levels) WITH ORDINALITY AS l(name, n),
     unnest(v.stands) WITH ORDINALITY AS st(name, n),
     generate_series(1, v.nsections) AS k,
     LATERAL (SELECT s.section_id FROM section s
              JOIN section p ON p.section_id = s.parent_id
              WHERE s.venue_id = v.venue_id AND p.name = l.name AND s.name = st.name) AS sd
ORDER BY v.venue_id, l.n, st.n, k;

-- Leaves: sections with no children hold the seats.
CREATE TABLE gen.leaf AS
SELECT s.section_id, s.venue_id, s.view_rank, v.nrows, v.nseats
FROM section s JOIN gen.venue v USING (venue_id)
WHERE NOT EXISTS (SELECT FROM section c WHERE c.parent_id = s.section_id);

INSERT INTO seat (section_id, row_label, seat_no, is_accessible)
SELECT l.section_id, chr(64 + r), n, r = 1 AND n <= 2
FROM gen.leaf l,
     generate_series(1, l.nrows) AS r,
     generate_series(1, l.nseats) AS n
ORDER BY l.section_id, r, n;

--
-- Artists, shows, comedians and teams
--
INSERT INTO artist (name, kind, genre)
SELECT name, kind, genre FROM (
    SELECT DISTINCT ON (name) name, 'concert'::event_kind AS kind, genre, i
    FROM generate_series(1, 120) AS i,
         LATERAL (SELECT CASE gen.ri('bandpat:' || i, 1, 4)
                    WHEN 1 THEN 'The ' || gen.pick('ba:' || i, ARRAY['Velvet','Paper','Northern','Electric','Silver','Midnight','Copper','Hollow','Neon','Lunar'])
                                || ' ' || gen.pick('bn:' || i, ARRAY['Foxes','Harbours','Satellites','Engines','Orchards','Comets','Lanterns','Tides','Cartographers','Wolves'])
                    WHEN 2 THEN gen.pick('solo:' || i, gen.first_names()) || ' ' || gen.pick('solol:' || i, gen.last_names())
                    WHEN 3 THEN gen.pick('one:' || i, ARRAY['Glasshouse','Saltwater','Lowlight','Moonwake','Afterglow','Kingfisher','Overpass','Wildflower','Undertow','Skyline'])
                    ELSE gen.pick('dj:' || i, ARRAY['DJ','MC','Lil','Big']) || ' ' || gen.pick('djn:' || i, ARRAY['Nova','Echo','Volt','Mira','Kairo','Zed','Juno','Rift'])
                  END AS name,
                  gen.pick('genre:' || i, ARRAY['indie rock','pop','electronic','jazz','hip hop','folk','metal','classical','soul','k-pop']) AS genre) AS n
    ORDER BY name, i
) a
WHERE i <= 120
ORDER BY i
LIMIT 60;

INSERT INTO artist (name, kind, genre) VALUES
    ('The Lighthouse Keeper', 'theatre', 'drama'), ('Midsummer Nights', 'theatre', 'comedy'),
    ('The Clockmaker''s Daughter', 'theatre', 'musical'), ('Salt and Iron', 'theatre', 'drama'),
    ('A Room Upstairs', 'theatre', 'thriller'), ('Paper Moon Cabaret', 'theatre', 'musical'),
    ('The Inheritance Game', 'theatre', 'comedy'), ('Winter Orchard', 'theatre', 'drama'),
    ('Northern Lights: The Musical', 'theatre', 'musical'), ('Twelve Angry Jurors', 'theatre', 'drama'),
    ('Vienna Philharmonic Ensemble', 'concert', 'classical'), ('Danube String Quartet', 'concert', 'classical'),
    ('Northfield FC', 'sports', 'football'), ('Riverside Giants', 'sports', 'basketball');

INSERT INTO artist (name, kind, genre)
SELECT DISTINCT ON (name COLLATE "C") name, 'comedy', 'stand-up'
FROM generate_series(1, 30) AS i, LATERAL gen.person('comedian:' || i) AS name
ORDER BY name COLLATE "C"
ON CONFLICT (name) DO NOTHING;

INSERT INTO artist (name, kind, genre)
SELECT name, 'sports', sport FROM (VALUES
    ('Eastport United', 'football'), ('Kingsbridge Rovers', 'football'), ('Ashford Athletic', 'football'),
    ('Millbrook City', 'football'), ('Harrowgate Town', 'football'), ('Westvale Wanderers', 'football'),
    ('Redcliffe Albion', 'football'), ('Stonebury FC', 'football'), ('Larkhill County', 'football'),
    ('Ostend Sharks', 'basketball'), ('Ghent Lions', 'basketball'), ('Utrecht Comets', 'basketball'),
    ('Leiden Owls', 'basketball'), ('Breda Bears', 'basketball')
) AS t(name, sport)
ORDER BY name COLLATE "C";

--
-- Events, 2025-07 to 2027-03. Each venue has its own rhythm.
--
CREATE TABLE gen.event AS
WITH days AS (
    SELECT d::date AS day FROM generate_series(timestamp '2025-07-01', timestamp '2027-03-31', interval '1 day') AS d
), plan AS (
    -- Harbour Theatre: Saturday shows of the current run
    SELECT 1 AS venue_id, day, time '19:30' AS t, 'theatre'::event_kind AS kind, 'run' AS pick
    FROM days WHERE extract(isodow FROM day) = 6 AND gen.r('v1:' || day) < 0.6
    UNION ALL
    -- Grand Concert Hall: Saturday concerts, some classical
    SELECT 2, day, time '19:30', 'concert', 'hall'
    FROM days WHERE extract(isodow FROM day) = 6 AND gen.r('v2:' || day) < 0.4
    UNION ALL
    -- Riverside Arena: Friday concerts, Wednesday basketball in season
    SELECT 3, day, time '20:00', 'concert', 'any'
    FROM days WHERE extract(isodow FROM day) = 5 AND gen.r('v3:' || day) < 0.25
    UNION ALL
    SELECT 3, day, time '19:00', 'sports', 'basketball'
    FROM days WHERE extract(isodow FROM day) = 3 AND extract(month FROM day) NOT IN (6, 7, 8)
                AND gen.r('v3b:' || day) < 0.2
    UNION ALL
    -- Old Town Comedy Club: Thursday and Saturday nights
    SELECT 4, day, time '20:30', 'comedy', 'any'
    FROM days WHERE extract(isodow FROM day) IN (4, 6) AND gen.r('v4:' || day) < 0.5
    UNION ALL
    -- Northfield Stadium: home games every other Saturday in season, a few
    -- summer concerts
    SELECT 5, day, time '15:00', 'sports', 'football'
    FROM days WHERE extract(isodow FROM day) = 6 AND extract(month FROM day) NOT IN (6, 7)
                AND extract(week FROM day)::int % 2 = 0 AND gen.r('v5:' || day) < 0.7
    UNION ALL
    SELECT 5, day, time '19:00', 'concert', 'any'
    FROM days WHERE extract(isodow FROM day) = 6 AND extract(month FROM day) IN (6, 7)
                AND gen.r('v5c:' || day) < 0.5
)
SELECT p.*, v.tz, v.fx,
       (p.day + p.t) AT TIME ZONE v.tz AS starts_at,
       p.venue_id || ':' || p.day AS k
FROM plan p JOIN gen.venue v USING (venue_id);

-- Pick the act: theatre runs a show for about three months, the hall
-- favours classical, football and basketball need an opponent.
CREATE TABLE gen.event2 AS
SELECT e.*, a.artist_id, a.name AS act,
       0.25 + 0.75 * gen.r('pop:' || a.artist_id) AS popularity
FROM gen.event e
CROSS JOIN LATERAL (
    SELECT a.artist_id, a.name FROM artist a
    WHERE CASE
        WHEN e.kind = 'theatre' THEN a.kind = 'theatre'
             AND a.artist_id = (SELECT min(artist_id) FROM artist WHERE kind = 'theatre')
                 + ((extract(year FROM e.day)::int * 4 + (extract(month FROM e.day)::int - 1) / 3) % 10)
        WHEN e.pick = 'hall' THEN a.kind = 'concert' AND (a.genre IN ('classical', 'jazz', 'soul', 'folk'))
        WHEN e.pick = 'football' THEN a.kind = 'sports' AND a.genre = 'football' AND a.name <> 'Northfield FC'
        WHEN e.pick = 'basketball' THEN a.kind = 'sports' AND a.genre = 'basketball' AND a.name <> 'Riverside Giants'
        ELSE a.kind = e.kind AND a.kind <> 'sports'
    END
    ORDER BY gen.r('act:' || e.k || ':' || a.artist_id)
    LIMIT 1
) a;

INSERT INTO event (venue_id, artist_id, kind, name, starts_at, during, on_sale_at, status)
SELECT e.venue_id, e.artist_id, e.kind,
       CASE e.pick
           WHEN 'football' THEN 'Northfield FC vs ' || e.act
           WHEN 'basketball' THEN 'Riverside Giants vs ' || e.act
           ELSE e.act || CASE e.kind
               WHEN 'concert' THEN ' - ' || gen.pick('tour:' || e.artist_id, ARRAY['Live', 'World Tour', 'Unplugged',
                                          'Greatest Hits Tour', 'Summer Tour', 'Farewell Tour', 'In Concert'])
               WHEN 'comedy' THEN ': ' || gen.pick('show:' || e.artist_id, ARRAY['Work in Progress', 'No Notes',
                                          'Overthinking It', 'Mostly Harmless', 'Small Talk', 'Late Again'])
               ELSE '' END
       END,
       e.starts_at,
       tstzrange(e.starts_at - CASE WHEN e.kind = 'sports' THEN interval '90 minutes' ELSE interval '60 minutes' END,
                 e.starts_at + interval '3 hours'),
       date_trunc('hour', e.starts_at - make_interval(days => CASE WHEN e.kind = 'sports'
                                                                   THEN gen.ri('sale:' || e.k, 21, 45)
                                                                   ELSE gen.ri('sale:' || e.k, 40, 160) END::int)),
       CASE WHEN gen.r('cancel:' || e.k) < 0.02 THEN 'cancelled'
            WHEN e.starts_at < gen.as_of() THEN 'completed'
            ELSE 'scheduled' END::event_status
FROM gen.event2 e
ORDER BY e.starts_at, e.venue_id;

UPDATE event SET status = 'on_sale' WHERE status = 'scheduled' AND on_sale_at <= gen.as_of();

-- Prices: by kind and popularity, in the venue's currency, four tiers.
INSERT INTO price_tier (event_id, name, price)
SELECT e.event_id, t.name,
       CASE WHEN v.currency = 'CZK' THEN round(base * t.factor * v.fx, -1)
            ELSE round(base * t.factor * v.fx) END
FROM event e
JOIN gen.event2 g ON g.venue_id = e.venue_id AND g.starts_at = e.starts_at
JOIN gen.venue v ON v.venue_id = e.venue_id
CROSS JOIN LATERAL (SELECT (CASE e.kind WHEN 'concert' THEN 35 + 85 * g.popularity
                                       WHEN 'theatre' THEN 30 + 55 * g.popularity
                                       WHEN 'comedy' THEN 10 + 12 * g.popularity
                                       ELSE 25 + 35 * g.popularity END)::numeric AS base) AS b
CROSS JOIN (VALUES (1, 'Premium', 1.8), (2, 'A', 1.35), (3, 'B', 1.0), (4, 'C', 0.7)) AS t(n, name, factor)
ORDER BY e.event_id, t.n;

CREATE TABLE gen.ev AS
SELECT e.event_id, e.venue_id, e.status, e.on_sale_at, e.starts_at, g.popularity,
       least(1.05, 0.3 + 0.8 * g.popularity) AS demand
FROM event e
JOIN gen.event2 g ON g.venue_id = e.venue_id AND g.starts_at = e.starts_at;

--
-- Customers
--
INSERT INTO customer (full_name, email, country_code, created_at)
SELECT name, gen.email(name, i, 'fans.example.org'),
       gen.pick('ccc:' || i, ARRAY['GB','GB','GB','NL','NL','AT','DE','CZ','BE','FR','US','IE']),
       gen.ts(date '2022-06-01' + gen.ri('joined:' || i, 0, 950)::int, 'joined-t:' || i)
FROM generate_series(1, 25000 * :scale) AS i,
     LATERAL gen.person('customer:' || i) AS name
ORDER BY i;

--
-- Sales. Seats in a row are split into groups of friends (1-6 adjacent
-- seats); each group either bought together, as one order, or not at all.
-- Popular events sell better, and most tickets sell soon after going on
-- sale.
--
CREATE TABLE gen.es AS
SELECT x.*,
       sum(x.new_group) OVER (PARTITION BY x.event_id, x.section_id, x.row_label ORDER BY x.seat_no) AS grp
FROM (
    SELECT ev.event_id, ev.status, ev.on_sale_at, ev.starts_at, ev.demand,
           s.seat_id, s.section_id, s.row_label, s.seat_no,
           pt.tier_id, pt.price,
           CASE WHEN s.seat_no = 1 OR gen.r('grp:' || ev.event_id || ':' || s.seat_id) < 0.33
                THEN 1 ELSE 0 END AS new_group,
           CASE WHEN l.view_rank <= 1 THEN 1.12 WHEN l.view_rank = 2 THEN 1.05
                WHEN l.view_rank = 3 THEN 0.97 ELSE 0.9 END AS tier_pull
    FROM gen.ev ev
    JOIN gen.leaf l ON l.venue_id = ev.venue_id
    JOIN seat s ON s.section_id = l.section_id
    JOIN price_tier pt ON pt.event_id = ev.event_id
                      AND pt.name = (ARRAY['Premium', 'A', 'B', 'C'])[least(4, l.view_rank)]
) x;

CREATE TABLE gen.grp AS
SELECT g.*, row_number() OVER (ORDER BY g.created_at, g.event_id, g.section_id, g.row_label COLLATE "C", g.grp) AS order_no
FROM (
    SELECT event_id, section_id, row_label, grp, k,
           min(status::text)::event_status AS status,
           sum(price) AS total,
           count(*) AS seats,
           min(created_at) AS created_at,
           1 + floor(power(gen.r('buyer:' || k), 1.3) * 25000 * :scale)::int AS customer_id
    FROM (
        SELECT es.*, es.event_id || ':' || es.section_id || ':' || es.row_label || ':' || es.grp AS k,
               es.on_sale_at + (es.starts_at - es.on_sale_at)
                   * power(gen.r('when:' || es.event_id || ':' || es.section_id || ':' || es.row_label || ':' || es.grp), 2.5)
                   AS created_at
        FROM gen.es es
    ) s
    WHERE gen.r('buy:' || k) < s.demand * s.tier_pull
    GROUP BY event_id, section_id, row_label, grp, k
) g
WHERE g.created_at < gen.as_of();

INSERT INTO orders (customer_id, event_id, created_at, status, total)
SELECT customer_id, event_id, date_trunc('second', created_at),
       CASE WHEN status = 'cancelled' THEN 'refunded' ELSE 'paid' END::order_status,
       total
FROM gen.grp
ORDER BY order_no;

-- Who holds each ticket in the end: the buyer, a friend it was transferred
-- to, or whoever bought it on resale.
CREATE TABLE gen.ticket AS
SELECT es.event_id, es.seat_id, es.price, g.order_no, g.customer_id AS buyer_id, g.created_at, g.status,
       es.starts_at,
       es.event_id || ':' || es.seat_id AS tk,
       gen.r('fate:' || es.event_id || ':' || es.seat_id) AS fate,
       1 + floor(gen.r('friend:' || es.event_id || ':' || es.seat_id) * 25000 * :scale)::int AS other_id
FROM gen.es es
JOIN gen.grp g ON g.event_id = es.event_id AND g.section_id = es.section_id
              AND g.row_label = es.row_label AND g.grp = es.grp;
-- A ticket can't be transferred to, or resold to, its own buyer.
UPDATE gen.ticket SET other_id = other_id % (25000 * :scale) + 1 WHERE other_id = buyer_id;

INSERT INTO ticket (order_id, event_id, seat_id, holder_id, face_value, barcode, status)
SELECT t.order_no, t.event_id, t.seat_id,
       CASE WHEN t.status = 'cancelled' THEN t.buyer_id
            WHEN t.fate < 0.05 THEN t.other_id                                  -- transferred
            WHEN t.fate < 0.09 AND gen.r('resold:' || t.tk) < 0.6
                 AND t.status <> 'cancelled' THEN t.other_id                    -- resold
            ELSE t.buyer_id END,
       t.price,
       gen.uuid7(t.created_at, 'barcode:' || t.tk),
       CASE WHEN t.status = 'cancelled' THEN 'refunded' ELSE 'valid' END::ticket_status
FROM gen.ticket t
ORDER BY t.order_no, t.seat_id;

INSERT INTO transfer (ticket_id, from_customer, to_customer, transferred_at)
SELECT tk.ticket_id, t.buyer_id, t.other_id,
       date_trunc('second', least(t.created_at + (t.starts_at - t.created_at) * gen.r('xfer-t:' || t.tk),
                                  gen.as_of() - interval '1 minute'))
FROM gen.ticket t
JOIN ticket tk ON tk.event_id = t.event_id AND tk.seat_id = t.seat_id
WHERE t.fate < 0.05 AND t.status <> 'cancelled'
ORDER BY 4, 1;

INSERT INTO resale_listing (ticket_id, seller_id, price, listed_at, status, buyer_id, closed_at)
SELECT tk.ticket_id, t.buyer_id,
       least(round(t.price * (0.8 + 0.3 * gen.r('resale-p:' || t.tk))::numeric, 2), round(t.price * 1.10, 2)),
       l.listed_at,
       CASE WHEN sold THEN 'sold'
            WHEN t.starts_at < gen.as_of() OR gen.r('withdrawn:' || t.tk) < 0.2 THEN 'withdrawn'
            ELSE 'listed' END::resale_status,
       CASE WHEN sold THEN t.other_id END,
       CASE WHEN sold OR t.starts_at < gen.as_of() OR gen.r('withdrawn:' || t.tk) < 0.2
            THEN least(l.listed_at + (t.starts_at - l.listed_at) * gen.r('resale-close:' || t.tk),
                       gen.as_of() - interval '1 minute') END
FROM gen.ticket t
JOIN ticket tk ON tk.event_id = t.event_id AND tk.seat_id = t.seat_id
CROSS JOIN LATERAL (SELECT date_trunc('second', least(t.created_at + (t.starts_at - t.created_at) * 0.5 * gen.r('list-t:' || t.tk),
                                                      gen.as_of() - interval '2 minutes')) AS listed_at,
                           gen.r('resold:' || t.tk) < 0.6 AS sold) AS l
WHERE t.fate >= 0.05 AND t.fate < 0.09 AND t.status <> 'cancelled'
ORDER BY l.listed_at, tk.ticket_id;

--
-- The inventory: sold seats, a few live holds on events on sale, and the
-- rest available.
--
INSERT INTO event_seat (event_id, seat_id, tier_id, status, held_by, hold_expires_at)
SELECT es.event_id, es.seat_id, es.tier_id,
       CASE WHEN tk.ticket_id IS NOT NULL THEN 'sold'
            WHEN h.hold THEN 'held'
            ELSE 'available' END::seat_status,
       CASE WHEN tk.ticket_id IS NULL AND h.hold THEN 1 + floor(gen.r('holder:' || es.event_id || ':' || es.section_id) * 25000 * :scale)::int END,
       CASE WHEN tk.ticket_id IS NULL AND h.hold
            THEN gen.as_of() + make_interval(mins => gen.ri('hold:' || es.event_id || ':' || es.section_id, -30, 9)::int) END
FROM gen.es es
LEFT JOIN ticket tk ON tk.event_id = es.event_id AND tk.seat_id = es.seat_id AND tk.status = 'valid'
CROSS JOIN LATERAL (SELECT es.status = 'on_sale'
                           AND gen.r('hold?' || es.event_id || ':' || es.section_id || ':' || es.row_label) < 0.01
                           AS hold) AS h
ORDER BY es.event_id, es.seat_id;

UPDATE event e SET status = 'sold_out'
WHERE e.status = 'on_sale'
  AND NOT EXISTS (SELECT FROM event_seat es WHERE es.event_id = e.event_id AND es.status <> 'sold');

--
-- Gate scans for past events: most ticket holders turn up, a few try a
-- screenshot twice, and some barcodes are not ours at all.
--
INSERT INTO scan (ticket_id, barcode, gate, scanned_at, result)
SELECT ticket_id, barcode, gate, scanned_at, result
FROM (
    SELECT t.ticket_id, t.barcode,
           'Gate ' || gen.pick('gate:' || t.ticket_id, ARRAY['A', 'B', 'C', 'D', 'E', 'F']) AS gate,
           lower(e.during) + make_interval(secs => gen.ri('arrive:' || t.ticket_id, 0, 9000)) AS scanned_at,
           'admitted'::scan_result AS result
    FROM ticket t JOIN event e USING (event_id)
    WHERE e.status = 'completed' AND t.status = 'valid' AND gen.r('noshow:' || t.ticket_id) >= 0.07
    UNION ALL
    SELECT t.ticket_id, t.barcode,
           'Gate ' || gen.pick('gate2:' || t.ticket_id, ARRAY['A', 'B', 'C', 'D', 'E', 'F']),
           lower(e.during) + make_interval(secs => gen.ri('arrive:' || t.ticket_id, 0, 9000) + gen.ri('again:' || t.ticket_id, 60, 1800)),
           'duplicate'
    FROM ticket t JOIN event e USING (event_id)
    WHERE e.status = 'completed' AND t.status = 'valid' AND gen.r('noshow:' || t.ticket_id) >= 0.07
      AND gen.r('dup:' || t.ticket_id) < 0.004
    UNION ALL
    SELECT NULL, md5('fake:' || e.event_id || ':' || n)::uuid,
           'Gate ' || gen.pick('gate3:' || e.event_id || ':' || n, ARRAY['A', 'B', 'C', 'D', 'E', 'F']),
           lower(e.during) + make_interval(secs => gen.ri('fake-t:' || e.event_id || ':' || n, 0, 9000)),
           'invalid'
    FROM event e, generate_series(1, gen.ri('fakes:' || e.event_id, 0, 5)::int) AS n
    WHERE e.status = 'completed'
) s
ORDER BY scanned_at, gate COLLATE "C", barcode;

DROP SCHEMA gen CASCADE;
ANALYZE;
