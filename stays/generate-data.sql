--
-- pg_fil: stays -- sample data generator
--
-- Run after schema.sql, into an empty database:
--   psql -d stays -f generate-data.sql
--   psql -d stays -v scale=3 -f generate-data.sql     -- 3x the data
--
-- The output is deterministic: every "random" choice is a hash of a key
-- string (see gen.r below), never random() or the clock, so the same scale
-- always gives the same rows on any little-endian server (x86-64, ARM64,
-- ppc64le), in any time zone.
--
-- The data covers 2024-01-01 to 2027-03-31 and is "as of" 2026-11-01:
-- stays that ended before then are completed, later ones are confirmed
-- future bookings.
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
    IF EXISTS (SELECT FROM listing) THEN
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
-- Cities
--
INSERT INTO city (name, country_code, timezone, location)
SELECT name, cc, tz, ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
FROM (VALUES
    ('Lisbon',        'PT', 'Europe/Lisbon',        -9.1393, 38.7223),
    ('Barcelona',     'ES', 'Europe/Madrid',         2.1734, 41.3851),
    ('Istanbul',      'TR', 'Europe/Istanbul',      28.9784, 41.0082),
    ('Antalya',       'TR', 'Europe/Istanbul',      30.7133, 36.8969),
    ('Paris',         'FR', 'Europe/Paris',          2.3522, 48.8566),
    ('Rome',          'IT', 'Europe/Rome',          12.4964, 41.9028),
    ('Amsterdam',     'NL', 'Europe/Amsterdam',      4.9041, 52.3676),
    ('Berlin',        'DE', 'Europe/Berlin',        13.4050, 52.5200),
    ('Prague',        'CZ', 'Europe/Prague',        14.4378, 50.0755),
    ('Athens',        'GR', 'Europe/Athens',        23.7275, 37.9838),
    ('Reykjavik',     'IS', 'Atlantic/Reykjavik',  -21.9426, 64.1466),
    ('London',        'GB', 'Europe/London',        -0.1276, 51.5072),
    ('New York',      'US', 'America/New_York',    -74.0060, 40.7128),
    ('Austin',        'US', 'America/Chicago',     -97.7431, 30.2672),
    ('San Francisco', 'US', 'America/Los_Angeles',-122.4194, 37.7749),
    ('Mexico City',   'MX', 'America/Mexico_City', -99.1332, 19.4326),
    ('Rio de Janeiro','BR', 'America/Sao_Paulo',   -43.1729,-22.9068),
    ('Buenos Aires',  'AR', 'America/Argentina/Buenos_Aires', -58.3816, -34.6037),
    ('Cape Town',     'ZA', 'Africa/Johannesburg',  18.4241,-33.9249),
    ('Marrakesh',     'MA', 'Africa/Casablanca',    -7.9811, 31.6295),
    ('Tokyo',         'JP', 'Asia/Tokyo',          139.6503, 35.6762),
    ('Bali',          'ID', 'Asia/Makassar',       115.1889, -8.4095),
    ('Bangkok',       'TH', 'Asia/Bangkok',        100.5018, 13.7563),
    ('Sydney',        'AU', 'Australia/Sydney',    151.2093,-33.8688)
) AS c(name, cc, tz, lon, lat);

-- Relative price level of each city, used to scale nightly rates.
CREATE TABLE gen.city_price AS
SELECT city_id, CASE name
    WHEN 'London' THEN 1.6 WHEN 'New York' THEN 1.8 WHEN 'San Francisco' THEN 1.7
    WHEN 'Paris' THEN 1.5 WHEN 'Amsterdam' THEN 1.5 WHEN 'Reykjavik' THEN 1.6
    WHEN 'Sydney' THEN 1.4 WHEN 'Tokyo' THEN 1.3 WHEN 'Barcelona' THEN 1.2
    WHEN 'Rome' THEN 1.2 WHEN 'Berlin' THEN 1.1 WHEN 'Austin' THEN 1.2
    WHEN 'Bali' THEN 0.6 WHEN 'Bangkok' THEN 0.5 WHEN 'Marrakesh' THEN 0.6
    WHEN 'Mexico City' THEN 0.7 WHEN 'Antalya' THEN 0.7 WHEN 'Istanbul' THEN 0.8
    ELSE 0.9 END AS level
FROM city;

--
-- Hosts and guests
--
INSERT INTO host (full_name, email, languages, is_superhost, joined_at)
SELECT name,
       gen.email(name, i, 'hosts.example.com'),
       CASE WHEN gen.r('host-lang:' || i) < 0.55 THEN ARRAY['en']
            ELSE ARRAY['en', gen.pick('host-lang2:' || i,
                 ARRAY['es','fr','de','it','pt','tr','ja','nl','el','th','id'])] END,
       gen.r('superhost:' || i) < 0.2,
       gen.ts(date '2018-01-01' + gen.ri('host-joined:' || i, 0, 2000)::int, 'host-joined-t:' || i)
FROM generate_series(1, 600 * :scale) AS i,
     LATERAL gen.person('host:' || i) AS name
ORDER BY i;

INSERT INTO guest (full_name, email, country_code, joined_at)
SELECT name,
       gen.email(name, i, 'guests.example.org'),
       gen.pick('guest-cc:' || i, ARRAY['US','US','US','GB','GB','DE','DE','FR','NL','ES',
                                        'IT','TR','CA','AU','JP','BR','MX','SE','PL','IN']),
       gen.ts(date '2019-01-01' + gen.ri('guest-joined:' || i, 0, 2100)::int, 'guest-joined-t:' || i)
FROM generate_series(1, 12000 * :scale) AS i,
     LATERAL gen.person('guest:' || i) AS name
ORDER BY i;

--
-- Listings
--
CREATE TABLE gen.listing AS
SELECT i, host_id,
       -- Hosts mostly list in their own home city.
       CASE WHEN gen.r('listing-away:' || i) < 0.85
            THEN gen.ri('host-city:' || host_id, 1, 24)
            ELSE gen.ri('listing-city:' || i, 1, 24) END::int AS city_id,
       gen.pick('listing-type:' || i, ARRAY[
           'apartment','apartment','apartment','apartment','apartment','house','house',
           'loft','cabin','villa','tiny_home','boat']::property_type[]) AS ptype,
       gen.r('listing-popularity:' || i) AS popularity,
       3.4 + 1.5 * gen.r('listing-quality:' || i) AS quality
FROM generate_series(1, 1500 * :scale) AS i,
     -- Every host gets one listing; the rest go mostly to early hosts, so
     -- some hosts run many listings.
     LATERAL (SELECT CASE WHEN i <= 600 * :scale THEN i
                     ELSE 1 + floor(power(gen.r('listing-host:' || i), 1.8) * 600 * :scale)::int
                     END AS host_id) AS h;

CREATE TABLE gen.listing2 AS
SELECT g.*,
       CASE g.ptype
           WHEN 'tiny_home' THEN 1 WHEN 'boat' THEN gen.ri('br:' || i, 1, 2)
           WHEN 'apartment' THEN gen.ri('br:' || i, 0, 3)
           WHEN 'loft' THEN gen.ri('br:' || i, 1, 2)
           WHEN 'villa' THEN gen.ri('br:' || i, 3, 6)
           ELSE gen.ri('br:' || i, 2, 4) END::int AS bedrooms
FROM gen.listing g;

INSERT INTO listing (host_id, city_id, title, description, property_type, max_guests,
                     bedrooms, beds, bathrooms, base_nightly_rate, cleaning_fee,
                     min_nights, location, amenities, is_active, created_at)
SELECT g.host_id,
       g.city_id,
       gen.pick('title-adj:' || i, ARRAY['Sunny','Cozy','Bright','Quiet','Stylish','Charming',
            'Spacious','Modern','Rustic','Elegant','Airy','Hidden','Classic','Minimalist'])
         || ' ' ||
       CASE g.ptype WHEN 'tiny_home' THEN 'tiny home' WHEN 'apartment' THEN
            CASE WHEN g.bedrooms = 0 THEN 'studio' ELSE g.bedrooms || '-bedroom apartment' END
            ELSE g.ptype::text END
         || ' ' ||
       gen.pick('title-tail:' || i, ARRAY['in ' || c.name, 'near the old town',
            'with a view', 'by the water', 'with garden', 'with rooftop terrace',
            'close to the metro', 'in a leafy street', 'steps from cafés',
            'with workspace', 'in the heart of ' || c.name]),
       concat_ws(' ',
           gen.pick('desc1:' || i, ARRAY[
               'A light-filled place to unwind after a day exploring the city.',
               'Our home is a calm base with everything you need for a longer stay.',
               'Freshly renovated with care, mixing original details and modern comfort.',
               'Wake up to birdsong and fresh coffee in this peaceful retreat.',
               'Perfect for couples, solo travellers and remote workers alike.',
               'Families love the space, the fully equipped kitchen and the quiet nights.']),
           gen.pick('desc2:' || i, ARRAY[
               'The neighbourhood is full of bakeries, markets and small restaurants.',
               'Public transport is a five minute walk away.',
               'You can walk to the main sights in about twenty minutes.',
               'The beach and the promenade are just down the road.',
               'Grocery stores, a pharmacy and a park are around the corner.',
               'Evenings are best spent on the terrace watching the sunset.']),
           gen.pick('desc3:' || i, ARRAY[
               'Fast wifi and a proper desk make it easy to work from here.',
               'Self check-in lets you arrive whenever suits you.',
               'Fresh linen and towels are provided for every stay.',
               'We are happy to share our favourite local spots with you.',
               'Please treat the place as your own and respect the neighbours.',
               'Parking is available on request.'])),
       g.ptype,
       greatest(1, g.bedrooms * 2 + gen.ri('mg:' || i, 0, 2))::int,
       g.bedrooms,
       greatest(1, g.bedrooms + gen.ri('beds:' || i, 0, 2))::int,
       greatest(1, ceil(g.bedrooms / 2.0) + CASE WHEN gen.r('bath:' || i) < 0.3 THEN 0.5 ELSE 0 END),
       round((45 + 35 * greatest(g.bedrooms, 0.6)) * p.level
             * CASE g.ptype WHEN 'villa' THEN 1.6 WHEN 'boat' THEN 1.3 WHEN 'loft' THEN 1.2
                            WHEN 'tiny_home' THEN 0.9 ELSE 1 END
             * (0.8 + 0.5 * gen.r('rate:' || i)))::numeric,
       round(15 + 10 * g.bedrooms * p.level),
       gen.pick('min-nights:' || i, ARRAY[1, 1, 1, 2, 2, 3, 5]),
       ST_Project(c.location, 300 + 11000 * sqrt(gen.r('dist:' || i)),
                  2 * pi() * gen.r('azimuth:' || i)),
       jsonb_strip_nulls(jsonb_build_object(
           'wifi', jsonb_build_object('mbps', gen.pick('wifi:' || i, ARRAY[50, 100, 100, 300, 500, 1000])),
           'kitchen', gen.r('kitchen:' || i) < 0.85,
           'washer', gen.r('washer:' || i) < 0.6,
           'air_conditioning', gen.r('ac:' || i) < 0.5,
           'workspace', gen.r('workspace:' || i) < 0.45,
           'pets_allowed', gen.r('pets:' || i) < 0.25,
           'self_check_in', CASE WHEN gen.r('sci:' || i) < 0.7
                THEN gen.pick('sci-kind:' || i, ARRAY['keypad', 'lockbox', 'smart_lock']) END,
           'parking', CASE WHEN gen.r('parking:' || i) < 0.4 THEN jsonb_build_object(
                'spaces', gen.ri('spaces:' || i, 1, 3),
                'ev_charger', gen.r('ev:' || i) < 0.3) END,
           'pool', CASE WHEN g.ptype IN ('villa', 'house') AND gen.r('pool:' || i) < 0.5
                THEN jsonb_build_object('heated', gen.r('heated:' || i) < 0.4) END,
           'hot_tub', CASE WHEN g.ptype IN ('villa', 'cabin', 'house') AND gen.r('hottub:' || i) < 0.3
                THEN true END,
           'views', CASE WHEN gen.r('views:' || i) < 0.35
                THEN to_jsonb((SELECT array_agg(v ORDER BY v COLLATE "C") FROM unnest(ARRAY['sea', 'city', 'mountain', 'garden']) AS v
                               WHERE gen.r('view-' || v || ':' || i) < 0.4)) END)),
       gen.r('active:' || i) >= 0.03,
       greatest(h.joined_at, gen.ts(date '2019-01-01' + gen.ri('created:' || i, 0, 1790)::int, 'created-t:' || i))
FROM gen.listing2 g
JOIN city c USING (city_id)
JOIN gen.city_price p USING (city_id)
JOIN host h ON h.host_id = g.host_id
ORDER BY g.i;

-- Hosts who joined after their listing was "created" get the listing's
-- date pulled forward instead; listings are all live before 2024.
UPDATE listing SET created_at = least(created_at, timestamptz '2023-12-15 00:00+00');

INSERT INTO listing_photo (listing_id, position, url, caption)
SELECT l.listing_id, n,
       format('https://img.example.com/stays/%s/%s.jpg', l.listing_id, n),
       CASE WHEN n = 1 THEN 'Living area'
            ELSE gen.pick('caption:' || l.listing_id || ':' || n, ARRAY[
                'Bedroom', 'Kitchen', 'Bathroom', 'View from the window', 'Dining corner',
                'Terrace', 'Entrance', 'Neighbourhood', 'Workspace', 'Garden']) END
FROM listing l,
     generate_series(1, gen.ri('photos:' || l.listing_id, 3, 8)::int) AS n
ORDER BY l.listing_id, n;

--
-- Seasonal rates: summer and the holidays every year, plus a discounted
-- low season for some listings.
--
INSERT INTO season_rate (listing_id, valid_at, nightly_rate, label)
SELECT l.listing_id, s.valid_at,
       round(l.base_nightly_rate * s.factor * (1 + 0.15 * gen.r('season:' || l.listing_id || ':' || s.label || y))),
       s.label
FROM listing l,
     generate_series(2024, 2027) AS y,
     LATERAL (VALUES
        ('summer', daterange(make_date(y, 6, 15), make_date(y, 9, 1)), 1.3),
        ('holidays', daterange(make_date(y, 12, 20), make_date(y + 1, 1, 3)), 1.5),
        ('low season', CASE WHEN gen.r('low:' || l.listing_id) < 0.3
                            THEN daterange(make_date(y, 1, 10), make_date(y, 3, 1)) END, 0.8)
     ) AS s(label, valid_at, factor)
WHERE s.valid_at IS NOT NULL
ORDER BY l.listing_id, lower(s.valid_at);

--
-- Bookings. The calendar is cut into 14-day slots per listing; a slot
-- holds at most one stay, which keeps generated stays from overlapping. A
-- listing's popularity decides how many of its slots get booked; a few of
-- the remaining slots get an availability block instead.
--
CREATE TABLE gen.slot AS
SELECT l.listing_id, l.min_nights, l.max_guests, l.cleaning_fee, l.created_at,
       s AS slot_no,
       date '2024-01-01' + 14 * s AS slot_start,
       gen.r('slot:' || l.listing_id || ':' || s) AS roll,
       0.15 + 0.7 * g.popularity AS p_booked
FROM listing l
JOIN gen.listing g ON g.i = l.listing_id,
     generate_series(0, (date '2027-03-31' - date '2024-01-01') / 14 - 1) AS s;

INSERT INTO availability_block (listing_id, during, reason)
SELECT listing_id,
       daterange(slot_start + d, slot_start + d + gen.ri('blocklen:' || k, 2, 7)::int),
       gen.pick('blockwhy:' || k, ARRAY['owner stay', 'maintenance', 'deep cleaning',
                                         'renovation', 'family visit'])
FROM gen.slot,
     LATERAL (SELECT listing_id || ':' || slot_no AS k) AS key,
     LATERAL (SELECT gen.ri('blockstart:' || k, 0, 6)::int AS d) AS start
WHERE roll >= p_booked AND gen.r('block:' || k) < 0.06
ORDER BY listing_id, slot_no;

CREATE TABLE gen.booking AS
SELECT b.*,
       daterange(b.slot_start + b.offs, b.slot_start + b.offs + b.nights) AS stay,
       greatest(b.created_at + interval '1 day',
                gen.ts(b.slot_start + b.offs - b.lead, 'booked-t:' || b.k)) AS booked_at
FROM (
    SELECT s.*, k.k,
           n.nights,
           gen.ri('offs:' || k.k, 0, 13 - n.nights)::int AS offs,
           -- Lead time: mostly weeks, sometimes months.
           floor(1 + 150 * power(gen.r('lead:' || k.k), 2))::int AS lead
    FROM gen.slot s,
         LATERAL (SELECT s.listing_id || ':' || s.slot_no AS k) AS k,
         LATERAL (SELECT least(13, greatest(s.min_nights,
                     gen.pick('nights:' || k.k, ARRAY[1, 2, 2, 3, 3, 3, 4, 4, 5, 6, 7, 7, 10])))::int AS nights) AS n
    WHERE s.roll < s.p_booked
) b;

DELETE FROM gen.booking WHERE booked_at >= gen.as_of();

INSERT INTO booking (listing_id, guest_id, stay, guests, status, accommodation,
                     cleaning_fee, service_fee, booked_at, cancelled_at)
SELECT b.listing_id,
       1 + floor(power(gen.r('guest:' || b.k), 1.4) * 12000 * :scale)::int,
       b.stay,
       gen.ri('party:' || b.k, 1, b.max_guests)::int,
       CASE WHEN c.cancelled_at IS NOT NULL THEN 'cancelled'
            WHEN upper(b.stay) <= gen.as_of()::date THEN 'completed'
            ELSE 'confirmed' END::booking_status,
       q.amount,
       b.cleaning_fee,
       round(q.amount * 0.12, 2),
       b.booked_at,
       c.cancelled_at
FROM gen.booking b,
     LATERAL (SELECT quote_stay(b.listing_id, b.stay) AS amount) AS q,
     LATERAL (SELECT CASE WHEN gen.r('cancel:' || b.k) < 0.07 THEN
                 least(b.booked_at + (lower(b.stay) - b.booked_at::date) * gen.r('cancel-t:' || b.k) * interval '1 day',
                       gen.as_of() - interval '1 hour')
              END AS cancelled_at) AS c
ORDER BY b.booked_at, b.listing_id, b.slot_no;

--
-- Payments, refunds and host payouts
--
INSERT INTO payment (booking_id, amount, method, status, paid_at)
SELECT booking_id, amount, method, status, paid_at
FROM (
    SELECT b.booking_id, b.total AS amount,
           gen.pick('pay:' || b.booking_id, ARRAY['card', 'card', 'card', 'card', 'wallet',
                                                  'wallet', 'bank_transfer']::payment_method[]) AS method,
           'captured'::payment_status AS status,
           b.booked_at + interval '2 minutes' AS paid_at
    FROM booking b
    UNION ALL
    SELECT b.booking_id, -b.total,
           gen.pick('pay:' || b.booking_id, ARRAY['card', 'card', 'card', 'card', 'wallet',
                                                  'wallet', 'bank_transfer']::payment_method[]),
           'refunded', b.cancelled_at + interval '1 hour'
    FROM booking b
    WHERE b.status = 'cancelled'
) p
ORDER BY paid_at, booking_id, status;

INSERT INTO payout (host_id, booking_id, amount, paid_at)
SELECT l.host_id, b.booking_id,
       b.accommodation + b.cleaning_fee - round(b.accommodation * 0.03, 2),
       (lower(b.stay) + 1 + time '09:00') AT TIME ZONE 'UTC'
FROM booking b
JOIN listing l USING (listing_id)
WHERE b.status = 'completed'
ORDER BY 4, b.booking_id;

--
-- Reviews: most completed stays get one, its rating drawn around the
-- listing's hidden quality score.
--
INSERT INTO review (booking_id, rating, cleanliness, location_rating, value_rating, body, created_at)
SELECT booking_id, rating,
       least(5, greatest(1, round(g.quality + 0.8 * gen.normal('clean:' || booking_id))))::int,
       least(5, greatest(1, round(g.quality + 0.3 + 0.6 * gen.normal('loc:' || booking_id))))::int,
       least(5, greatest(1, round(g.quality - 0.2 + 0.8 * gen.normal('value:' || booking_id))))::int,
       concat_ws(' ',
           CASE rating
               WHEN 5 THEN gen.pick('r5:' || booking_id, ARRAY[
                   'Absolutely loved our stay!', 'One of the best places we have stayed in.',
                   'Wonderful home, exactly as pictured.', 'Perfect in every way.',
                   'We did not want to leave!'])
               WHEN 4 THEN gen.pick('r4:' || booking_id, ARRAY[
                   'Lovely place and a great host.', 'Really nice stay overall.',
                   'Comfortable and well located.', 'Very good value for the location.'])
               WHEN 3 THEN gen.pick('r3:' || booking_id, ARRAY[
                   'Decent place for a short stay.', 'It was okay, a few things could be better.',
                   'Mixed feelings about this one.'])
               ELSE gen.pick('r1:' || booking_id, ARRAY[
                   'Disappointing stay.', 'Not as described.', 'Would not stay here again.'])
           END,
           CASE WHEN rating >= 4 THEN gen.pick('rp:' || booking_id, ARRAY[
                   'The bed was super comfortable and the kitchen had everything we needed.',
                   'Spotless and quiet, with a beautiful view in the morning.',
                   'The location is perfect for walking everywhere.',
                   'Check-in was easy and the wifi was fast enough for video calls.',
                   'The terrace was the highlight, we had breakfast there every day.',
                   'Our host gave us great restaurant recommendations.'])
                ELSE gen.pick('rn:' || booking_id, ARRAY[
                   'The apartment was noisy at night because of the street.',
                   'Cleanliness was not great, the bathroom needed attention.',
                   'The wifi kept dropping, which made working hard.',
                   'Check-in was confusing and the host was slow to answer.',
                   'Photos made it look bigger than it is.',
                   'The heating did not work properly.']) END,
           CASE WHEN gen.r('rx:' || booking_id) < 0.5 THEN gen.pick('rc:' || booking_id, ARRAY[
                   'Highly recommended.', 'Thanks again!', 'Hope to come back soon.',
                   'Good for families.', 'Great for a work trip.', 'Bring earplugs.'])
           END),
       gen.ts(upper(stay) + gen.ri('review-day:' || booking_id, 0, 14)::int, 'review-t:' || booking_id)
FROM (
    SELECT b.booking_id, b.stay, b.listing_id,
           least(5, greatest(1, round(g.quality + 0.7 * gen.normal('rating:' || b.booking_id))))::int AS rating
    FROM booking b
    JOIN gen.listing g ON g.i = b.listing_id
    WHERE b.status = 'completed' AND gen.r('reviewed:' || b.booking_id) < 0.65
) r
JOIN gen.listing g ON g.i = r.listing_id
WHERE upper(stay) + 15 <= gen.as_of()::date
ORDER BY 7, booking_id;

--
-- Messages: a guest question and the host's answer before some stays.
--
INSERT INTO message (booking_id, sender, body, sent_at)
SELECT booking_id, sender, body, sent_at
FROM (
    SELECT b.booking_id, 'guest'::message_sender AS sender,
           gen.pick('mq:' || b.booking_id, ARRAY[
               'Hi! Is early check-in possible on our arrival day?',
               'Hello, is there a place to store luggage after check-out?',
               'Could you recommend a good place for dinner nearby?',
               'Is the parking spot available during our stay?',
               'We are travelling with a baby, do you have a cot?',
               'What is the best way to get there from the airport?',
               'Hi, we might arrive late in the evening, is that okay?']) AS body,
           b.booked_at + interval '1 hour' * gen.ri('mq-t:' || b.booking_id, 2, 72) AS sent_at
    FROM booking b
    WHERE b.status <> 'cancelled' AND gen.r('msg:' || b.booking_id) < 0.4
    UNION ALL
    SELECT b.booking_id, 'host',
           gen.pick('ma:' || b.booking_id, ARRAY[
               'Of course, happy to help! I will send the details closer to the date.',
               'Yes, no problem at all. Looking forward to hosting you.',
               'Thanks for asking! I have left a guide with all our tips in the apartment.',
               'Sure, just let me know your arrival time.',
               'Good question, I will check and get back to you today.']),
           b.booked_at + interval '1 hour' * (gen.ri('mq-t:' || b.booking_id, 2, 72)
                                              + gen.ri('ma-t:' || b.booking_id, 1, 10))
    FROM booking b
    WHERE b.status <> 'cancelled' AND gen.r('msg:' || b.booking_id) < 0.4
) m
WHERE sent_at < gen.as_of()
ORDER BY sent_at, booking_id, sender;

DROP SCHEMA gen CASCADE;
ANALYZE;
