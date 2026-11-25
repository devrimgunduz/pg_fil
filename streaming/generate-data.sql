--
-- pg_fil: streaming -- sample data generator
--
-- Run after schema.sql, into an empty database:
--   psql -d streaming -f generate-data.sql
--   psql -d streaming -v scale=3 -f generate-data.sql     -- 3x the accounts
--
-- The output is deterministic: every "random" choice is a hash of a key
-- string (see gen.r below), never random() or the clock, so the same scale
-- always gives the same rows on any server, in any time zone. That includes
-- the UUIDv7 account ids, built by gen.uuid7() from the sign-up time.
--
-- The service launched on 2024-01-01 and the data is "as of" 2026-11-01.
-- The catalog (1,200 titles) is the same at every scale; accounts, and
-- everything that hangs off them, grow with it.
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
    IF EXISTS (SELECT FROM title) THEN
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
-- Reference data
--
INSERT INTO genre (genre_id, name) VALUES
    (1, 'Drama'), (2, 'Comedy'), (3, 'Thriller'), (4, 'Crime'), (5, 'Documentary'),
    (6, 'Sci-Fi'), (7, 'Fantasy'), (8, 'Animation'), (9, 'Romance'), (10, 'Horror'),
    (11, 'Action'), (12, 'Family'), (13, 'Mystery'), (14, 'Reality'), (15, 'Anime'),
    (16, 'History');

INSERT INTO region (region_code, name, currency, timezone) VALUES
    ('US', 'United States', 'USD', 'America/New_York'),
    ('GB', 'United Kingdom', 'GBP', 'Europe/London'),
    ('DE', 'Germany', 'EUR', 'Europe/Berlin'),
    ('FR', 'France', 'EUR', 'Europe/Paris'),
    ('TR', 'Türkiye', 'TRY', 'Europe/Istanbul'),
    ('BR', 'Brazil', 'BRL', 'America/Sao_Paulo'),
    ('MX', 'Mexico', 'MXN', 'America/Mexico_City'),
    ('JP', 'Japan', 'JPY', 'Asia/Tokyo'),
    ('IN', 'India', 'INR', 'Asia/Kolkata'),
    ('AU', 'Australia', 'AUD', 'Australia/Sydney');

INSERT INTO plan (plan_id, name, max_streams, max_quality, has_ads) VALUES
    (1, 'Standard with ads', 2, 'HD', true),
    (2, 'Standard', 2, 'HD', false),
    (3, 'Premium', 4, 'UHD', false);

-- Prices in local currency. Every region had two price rises, on
-- 2025-02-01 (+15%) and 2026-07-01 (+30% on the original price);
-- Türkiye's were steeper.
INSERT INTO plan_price (plan_id, region_code, valid_at, monthly_price)
SELECT p.plan_id, b.region_code, per.valid_at,
       CASE WHEN r.currency IN ('JPY', 'INR', 'MXN')
            THEN round(base.price * per.factor ^ b.steep, -1)
            ELSE round(base.price * per.factor ^ b.steep) - 0.01 END
FROM (VALUES
    ('US', 1, 6.99, 15.49, 22.99), ('GB', 1, 5.99, 12.99, 18.99),
    ('DE', 1, 4.99, 13.99, 19.99), ('FR', 1, 5.99, 13.49, 19.99),
    ('TR', 3, 149.99, 229.99, 299.99), ('BR', 1, 20.90, 44.90, 59.90),
    ('MX', 1, 119, 219, 299), ('JP', 1, 890, 1590, 2290),
    ('IN', 1, 149, 499, 649), ('AU', 1, 7.99, 18.99, 25.99)
) AS b(region_code, steep, p1, p2, p3)
JOIN region r USING (region_code)
CROSS JOIN plan p
CROSS JOIN LATERAL (SELECT CASE p.plan_id WHEN 1 THEN b.p1 WHEN 2 THEN b.p2 ELSE b.p3 END AS price) AS base
CROSS JOIN (VALUES
    (daterange('2023-01-01', '2025-02-01'), 1.0),
    (daterange('2025-02-01', '2026-07-01'), 1.15),
    (daterange('2026-07-01', NULL), 1.3)
) AS per(valid_at, factor)
ORDER BY 1, 2, 3;

--
-- People and titles. The catalog has the same size at every scale.
--
INSERT INTO person (full_name, birth_year)
SELECT gen.person('person:' || i), gen.ri('born:' || i, 1940, 2008)
FROM generate_series(1, 5000) AS i
ORDER BY i;

CREATE TABLE gen.title AS
SELECT i AS title_id,
       CASE WHEN gen.r('kind:' || i) < 0.3 THEN 'series' ELSE 'movie' END::title_kind AS kind,
       g1, g2, g3,
       2026 - floor(power(gen.r('year:' || i), 2.2) * 50)::int AS release_year,
       gen.r('quality:' || i) AS quality
FROM generate_series(1, 1200) AS i,
     LATERAL (SELECT gen.ri('g1:' || i, 1, 16)::int AS g1) AS a,
     LATERAL (SELECT CASE WHEN gen.r('g2?' || i) < 0.7 THEN gen.ri('g2:' || i, 1, 16)::int END AS g2,
                     CASE WHEN gen.r('g3?' || i) < 0.25 THEN gen.ri('g3:' || i, 1, 16)::int END AS g3) AS b;

-- Kids' genres only mix with each other.
UPDATE gen.title SET g2 = CASE WHEN g2 IS NOT NULL THEN 12 END, g3 = NULL
WHERE g1 IN (8, 12) AND g2 NOT IN (8, 12, 2, 7);
UPDATE gen.title SET g2 = NULL WHERE g2 = g1;
UPDATE gen.title SET g3 = NULL WHERE g3 IN (g1, g2) OR g1 IN (8, 12);
-- Documentaries and reality shows are their own thing.
UPDATE gen.title SET g2 = NULL, g3 = NULL WHERE g1 IN (5, 14);
UPDATE gen.title SET kind = 'series' WHERE g1 = 14;

INSERT INTO title (kind, name, original_language, release_year, maturity, runtime_min, synopsis, added_at)
SELECT t.kind,
       CASE gen.ri('pattern:' || i, 1, 4)
           WHEN 1 THEN 'The ' || adj || ' ' || noun
           WHEN 2 THEN plural || ' of the ' || noun
           WHEN 3 THEN adj || ' ' || plural
           ELSE noun || ' ' || gen.pick('suffix:' || i, ARRAY['Road', 'Files', 'Club', 'Hours', 'Line', 'Point', 'Diaries', 'Rising'])
       END,
       CASE WHEN t.g1 = 15 THEN 'ja'
            ELSE gen.pick('lang:' || i, ARRAY['en','en','en','en','en','en','es','fr','de','ja',
                                              'ko','ko','tr','hi','pt','it','da']) END,
       t.release_year,
       CASE WHEN t.g1 IN (8, 12) THEN gen.pick('kidrating:' || i, ARRAY['TV-Y', 'TV-G', 'TV-G', 'TV-PG'])
            WHEN t.g1 = 10 THEN 'TV-MA'
            ELSE gen.pick('rating:' || i, ARRAY['TV-PG', 'TV-14', 'TV-14', 'TV-MA', 'TV-MA']) END::maturity_rating,
       CASE WHEN t.kind = 'movie' THEN
            CASE WHEN t.g1 IN (8, 12) THEN 75 + gen.ri('runtime:' || i, 0, 30)
                 WHEN t.g1 = 5 THEN 70 + gen.ri('runtime:' || i, 0, 50)
                 ELSE 88 + floor(abs(gen.normal('runtime:' || i)) * 30)::int END END,
       CASE WHEN t.g1 IN (5, 14) THEN
           gen.pick('doc1:' || i, ARRAY['An intimate look at', 'The inside story of',
                'A year with', 'Behind the scenes of', 'An investigation into'])
           || ' ' ||
           gen.pick('doc2:' || i, ARRAY['the chefs of a three-star kitchen',
                'a city racing to beat rising seas', 'the people who build the world''s fastest trains',
                'a football club fighting relegation', 'the hidden economy of the deep ocean',
                'twelve strangers renovating a ruined castle', 'the last glaciers of the Alps',
                'a family-run olive farm', 'the rise and fall of a tech startup',
                'young dancers competing for a single spot'])
           || '. ' ||
           gen.pick('doc3:' || i, ARRAY['Filmed over three years.', 'Told by the people who lived it.',
                'With never-before-seen footage.', 'Surprising, moving and often funny.'])
       ELSE
           initcap(left(who, 1)) || substr(who, 2) || ' ' ||
           gen.pick('verb:' || i, ARRAY['must uncover the truth behind', 'must race against time to stop',
                'must protect their home from', 'will stop at nothing to solve',
                'must team up to survive', 'cannot escape', 'must make peace with',
                'will risk everything to find'])
           || ' ' ||
           gen.pick('what:' || i, ARRAY['a series of mysterious disappearances',
                'a forgotten family secret', 'an AI that wants to be human', 'a heist gone wrong',
                'a rival restaurant', 'a storm that cuts the town off', 'a conspiracy inside the government',
                'a lost treasure map', 'a dragon egg', 'a failing football club', 'a haunted lighthouse',
                'a signal from deep space', 'a cursed painting', 'a reality show gone wrong'])
           || ' ' ||
           gen.pick('where:' || i, ARRAY['in 1970s Istanbul', 'on a remote Norwegian island',
                'in near-future Tokyo', 'in a small Texas town', 'aboard a generation ship',
                'in Victorian London', 'in the hills above Rio', 'in a Mumbai high-rise',
                'in post-war Berlin', 'in a sleepy coastal village', 'in Seoul''s busiest market',
                'on the Moon''s first colony'])
           || '. ' ||
           (ARRAY['A moving story about family and second chances.',
                  'Sharp, warm and very funny.', 'Tense from the first minute to the last.',
                  'A gripping crime story with a twist.', '',
                  'Big ideas, bigger spaceships.', 'Magic, monsters and old prophecies.',
                  'Beautifully animated and full of heart.', 'Romantic, bittersweet and charming.',
                  'Do not watch this one alone.', 'Explosive action and car chases.',
                  'Fun for the whole family.', 'Nothing is what it seems.', '',
                  'Spectacular anime adventure.', 'Based on true events.'])[t.g1]
       END,
       least(date '2026-10-15',
             greatest(make_date(t.release_year, 1 + gen.ri('month:' || i, 0, 9)::int, 1)
                          + gen.ri('day:' || i, 0, 27)::int,
                      date '2023-01-01' + gen.ri('added:' || i, 0, 1380)::int))
FROM gen.title t,
     LATERAL (SELECT t.title_id AS i) AS k,
     LATERAL (SELECT
        gen.pick('adj:' || i, ARRAY['Silent','Last','Hidden','Broken','Golden','Northern','Endless',
            'Crimson','Quiet','Lost','Bright','Wild','Hollow','Burning','Frozen','Distant','Electric',
            'Secret','Little','Midnight','Second','Final','Paper','Iron','Glass','Velvet']) AS adj,
        gen.pick('noun:' || i, ARRAY['Harbor','Signal','Kingdom','Garden','Frontier','Witness','Orbit',
            'Season','River','Empire','Island','Protocol','Inheritance','Lighthouse','Circuit',
            'Detective','Summer','Archive','Republic','Cartographer','Orchard','Station','Horizon',
            'Tide','Code','Promise']) AS noun,
        gen.pick('plural:' || i, ARRAY['Echoes','Shadows','Rivers','Ghosts','Letters','Wolves',
            'Machines','Strangers','Daughters','Kings','Lies','Stars','Bridges','Secrets','Storms']) AS plural,
        gen.pick('who:' || i, ARRAY['a retired detective', 'two estranged sisters', 'a young engineer',
            'a small-town baker', 'an ambitious journalist', 'a group of teenagers', 'a disgraced chef',
            'a lonely astronaut', 'a family of farmers', 'an undercover agent', 'a gifted violinist',
            'a stubborn mayor', 'a talking fox', 'a pair of rival magicians']) AS who
     ) AS w
ORDER BY t.title_id;

-- The catalog can't list a title before it was released.
UPDATE title SET added_at = make_date(release_year, 1, 1) + 30
WHERE added_at < make_date(release_year, 1, 1);

INSERT INTO title_genre (title_id, genre_id)
SELECT title_id, g FROM gen.title, unnest(ARRAY[g1, g2, g3]) AS g
WHERE g IS NOT NULL
ORDER BY 1, 2;

-- Seasons come out yearly, episodes all at once.
INSERT INTO season (title_id, season_no, released_on)
SELECT t.title_id, s, d
FROM title t,
     generate_series(1, 1 + floor(power(gen.r('seasons:' || t.title_id), 1.6) * 6)::int) AS s,
     LATERAL (SELECT greatest(t.added_at,
                     make_date(t.release_year + s - 1, 1 + gen.ri('smonth:' || t.title_id, 0, 11)::int, 1)
                     + gen.ri('sday:' || t.title_id || ':' || s, 0, 27)::int) AS d) AS x
WHERE t.kind = 'series' AND (s = 1 OR d < date '2026-10-31')
ORDER BY 1, 2;

INSERT INTO episode (season_id, title_id, episode_no, name, runtime_min)
SELECT s.season_id, s.title_id, e,
       CASE WHEN s.season_no = 1 AND e = 1 THEN 'Pilot'
            ELSE gen.pick('ep:' || s.season_id || ':' || e, ARRAY[
                'The Arrival','Crossroads','Old Friends','Blackout','The Long Night','Homecoming',
                'Fault Lines','Ghost Signal','The Offer','Low Tide','Northbound','Paper Trail',
                'Second Chances','The Visitor','Thin Ice','Undertow','Wildfire','Zero Hour',
                'Checkmate','First Light','Open Water','Static','The Reckoning','Afterglow']) END,
       CASE WHEN g.g1 IN (2, 8, 12, 15) THEN 22 + gen.ri('eplen:' || s.season_id || ':' || e, 0, 8)
            ELSE 42 + gen.ri('eplen:' || s.season_id || ':' || e, 0, 18) END
FROM season s
JOIN gen.title g ON g.title_id = s.title_id,
     generate_series(1, CASE WHEN g.g1 = 14 THEN gen.ri('eps:' || s.season_id, 8, 12)
                             ELSE gen.ri('eps:' || s.season_id, 6, 10) END::int) AS e
ORDER BY s.season_id, e;

INSERT INTO title_credit (title_id, person_id, role, character_name, billing_order)
SELECT title_id, person_id, role, character_name, billing_order
FROM (
    SELECT t.title_id,
           1 + floor(power(gen.r('dir:' || t.title_id), 1.3) * 5000)::int AS person_id,
           CASE t.kind WHEN 'movie' THEN 'director' ELSE 'creator' END::credit_role AS role,
           NULL::text AS character_name, 1 AS billing_order
    FROM title t
    UNION ALL
    SELECT t.title_id, 1 + floor(power(gen.r('writer:' || t.title_id), 1.3) * 5000)::int,
           'writer', NULL, 2
    FROM title t
    UNION ALL
    SELECT t.title_id, 1 + floor(power(gen.r('actor:' || t.title_id || ':' || n), 1.6) * 5000)::int,
           'actor',
           CASE WHEN g.g1 IN (5, 14) THEN 'Self'
                ELSE gen.pick('char:' || t.title_id || ':' || n, gen.first_names())
                     || CASE WHEN gen.r('charlast:' || t.title_id || ':' || n) < 0.5
                             THEN ' ' || gen.pick('charl:' || t.title_id || ':' || n, gen.last_names())
                             ELSE '' END END,
           2 + n
    FROM title t
    JOIN gen.title g USING (title_id),
         generate_series(1, gen.ri('cast:' || t.title_id, 3, 8)::int) AS n
) c
ORDER BY title_id, billing_order
ON CONFLICT DO NOTHING;

-- Embeddings: genres (1-16), kind, maturity, era and length (17-20), and a
-- hidden tone (21-24).
INSERT INTO title_embedding (title_id, embedding)
SELECT t.title_id,
       ((SELECT array_agg(CASE WHEN d = g.g1 THEN 1.0
                              WHEN d IN (g.g2, g.g3) THEN 0.6
                              ELSE 0 END ORDER BY d)
        FROM generate_series(1, 16) AS d)
       || ARRAY[
           CASE t.kind WHEN 'series' THEN 0.5 ELSE 0 END,
           0.5 * (array_position(enum_range(NULL::maturity_rating), t.maturity) - 1) / 4.0,
           0.5 * (t.release_year - 1975) / 51.0,
           0.5 * least(1, coalesce(t.runtime_min, 45) / 180.0),
           0.8 * gen.r('tone1:' || t.title_id), 0.8 * gen.r('tone2:' || t.title_id),
           0.8 * gen.r('tone3:' || t.title_id), 0.8 * gen.r('tone4:' || t.title_id)])::float4[]::vector
FROM title t
JOIN gen.title g USING (title_id)
ORDER BY 1;

-- License windows: most titles stay in every region from the day they are
-- added. Some are never licensed in a region, and some leave after a year
-- or two (a few of those come back later).
INSERT INTO license_window (title_id, region_code, valid_at)
SELECT title_id, region_code, valid_at
FROM (
    SELECT t.title_id, r.region_code,
           CASE WHEN x < 0.8 THEN daterange(t.added_at, NULL)
                ELSE daterange(t.added_at, t.added_at + gen.ri('lw:' || k, 200, 700)::int) END AS valid_at
    FROM title t CROSS JOIN region r,
         LATERAL (SELECT t.title_id || ':' || r.region_code AS k) AS key,
         LATERAL (SELECT gen.r('license:' || k) AS x) AS l
    WHERE x < 0.95
    UNION ALL
    SELECT t.title_id, r.region_code,
           daterange(t.added_at + gen.ri('lw:' || k, 200, 700)::int + gen.ri('lw-back:' || k, 90, 300)::int, NULL)
    FROM title t CROSS JOIN region r,
         LATERAL (SELECT t.title_id || ':' || r.region_code AS k) AS key,
         LATERAL (SELECT gen.r('license:' || k) AS x) AS l
    WHERE x >= 0.8 AND x < 0.95 AND gen.r('comeback:' || k) < 0.3
) w
WHERE lower(valid_at) < date '2026-11-01'
ORDER BY 1, 2, 3;

--
-- Accounts, subscriptions and invoices
--
CREATE TABLE gen.account AS
SELECT n, name, region_code, created_at,
       gen.uuid7(created_at, 'account:' || n) AS account_id,
       plan1, plan2, change_day, cancel_day
FROM (
    SELECT n, gen.person('account:' || n) AS name,
           gen.pick('region:' || n, ARRAY['US','US','US','US','GB','DE','DE','FR','TR','BR',
                                          'BR','MX','JP','IN','IN','AU']) AS region_code,
           -- Sign-ups accelerate over time.
           gen.ts(date '2024-01-01' + floor(sqrt(gen.r('signup:' || n)) * 1020)::int, 'signup-t:' || n) AS created_at,
           gen.pick('plan1:' || n, ARRAY[1, 1, 2, 2, 2, 3]) AS plan1,
           gen.ri('plan2:' || n, 1, 3)::int AS plan2,
           CASE WHEN gen.r('change?' || n) < 0.3 THEN gen.ri('change:' || n, 30, 500)::int END AS change_after,
           CASE WHEN gen.r('cancel?' || n) < 0.25 THEN gen.ri('cancel:' || n, 40, 700)::int END AS cancel_after
    FROM generate_series(1, 6000 * :scale) AS n
) a,
LATERAL (SELECT CASE WHEN change_after IS NOT NULL AND plan2 <> plan1
                      AND created_at::date + change_after < date '2026-11-01'
                      AND (cancel_after IS NULL OR change_after < cancel_after)
                     THEN created_at::date + change_after END AS change_day,
                CASE WHEN created_at::date + cancel_after < date '2026-11-01'
                     THEN created_at::date + cancel_after END AS cancel_day) AS d;

INSERT INTO account (account_id, email, region_code, created_at)
SELECT account_id, gen.email(name, n, 'stream.example.net'), region_code, created_at
FROM gen.account
ORDER BY account_id;

INSERT INTO subscription (account_id, plan_id, region_code, valid_at)
SELECT account_id, plan_id, region_code, valid_at
FROM (
    SELECT account_id, plan1 AS plan_id, region_code,
           daterange(created_at::date, coalesce(change_day, cancel_day)) AS valid_at
    FROM gen.account
    UNION ALL
    SELECT account_id, plan2, region_code, daterange(change_day, cancel_day)
    FROM gen.account
    WHERE change_day IS NOT NULL
) s
ORDER BY lower(valid_at), account_id;

-- Monthly invoices on the subscription's anniversary day; a period cut
-- short by a plan change or cancellation is prorated.
INSERT INTO invoice (subscription_id, period, amount, currency, issued_at, paid_at)
SELECT s.subscription_id, i.period,
       round(p.monthly_price * (upper(i.period) - lower(i.period))
             / ((lower(i.period) + interval '1 month')::date - lower(i.period)),
             CASE WHEN r.currency IN ('JPY', 'INR', 'MXN') THEN 0 ELSE 2 END),
       r.currency,
       (lower(i.period) + time '06:00') AT TIME ZONE 'UTC',
       CASE WHEN gen.r('unpaid:' || s.subscription_id || ':' || lower(i.period)) >= 0.01
            THEN (lower(i.period) + time '06:00') AT TIME ZONE 'UTC'
                 + make_interval(secs => gen.ri('paid:' || s.subscription_id || ':' || lower(i.period), 5, 7200)) END
FROM subscription s
JOIN region r USING (region_code)
CROSS JOIN LATERAL (SELECT daterange(d::date, least((d + interval '1 month')::date, upper(s.valid_at))) AS period
              FROM generate_series(lower(s.valid_at),
                                   coalesce(upper(s.valid_at), date '2026-11-01') - 1,
                                   interval '1 month') AS d
              WHERE d < date '2026-11-01') AS i
JOIN plan_price p ON p.plan_id = s.plan_id AND p.region_code = s.region_code
                 AND p.valid_at @> lower(i.period)
ORDER BY lower(i.period), s.subscription_id;

--
-- Profiles and devices
--
CREATE TABLE gen.profile AS
SELECT row_number() OVER (ORDER BY a.n, k) AS profile_id, a.n, k, a.account_id,
       k > 1 AND k = nprof AND nprof >= 3 AND gen.r('kids:' || a.n) < 0.6 AS is_kids
FROM gen.account a,
     LATERAL (SELECT gen.pick('nprof:' || a.n, ARRAY[1, 1, 2, 2, 2, 3, 3, 4, 5]) AS nprof) AS np,
     generate_series(1, nprof) AS k;

INSERT INTO profile (account_id, name, is_kids, language)
SELECT p.account_id,
       CASE WHEN p.is_kids THEN 'Kids'
            WHEN p.k = 1 THEN split_part(a.name, ' ', 1)
            -- Stepping through the name list keeps an account's names distinct.
            ELSE (gen.first_names())[1 + (array_position(gen.first_names(), split_part(a.name, ' ', 1))
                                          + 7 * (p.k - 1) - 1) % 60] END,
       p.is_kids,
       CASE a.region_code WHEN 'DE' THEN 'de' WHEN 'FR' THEN 'fr' WHEN 'TR' THEN 'tr'
            WHEN 'BR' THEN 'pt' WHEN 'MX' THEN 'es' WHEN 'JP' THEN 'ja'
            WHEN 'IN' THEN gen.pick('inlang:' || p.profile_id, ARRAY['en', 'hi'])
            ELSE 'en' END
FROM gen.profile p
JOIN gen.account a USING (n)
ORDER BY p.profile_id;

CREATE TABLE gen.device AS
SELECT row_number() OVER (ORDER BY a.n, k) AS device_id, a.n, k, ndev, a.account_id, a.created_at,
       CASE WHEN k = 1 THEN gen.pick('dev:' || a.n || ':' || k, ARRAY['tv', 'tv', 'phone', 'browser'])
            ELSE gen.pick('dev:' || a.n || ':' || k, ARRAY['tv', 'phone', 'phone', 'tablet', 'browser', 'console'])
       END::device_kind AS kind
FROM gen.account a,
     LATERAL (SELECT gen.pick('ndev:' || a.n, ARRAY[1, 2, 2, 3, 3, 4]) AS ndev) AS nd,
     generate_series(1, ndev) AS k;
CREATE UNIQUE INDEX ON gen.device (n, k);

INSERT INTO device (account_id, kind, info, first_seen)
SELECT d.account_id, d.kind,
       jsonb_build_object('app_version',
            '9.' || gen.ri('appv:' || key, 0, 14) || '.' || gen.ri('appp:' || key, 0, 9))
       || CASE d.kind
          WHEN 'tv' THEN jsonb_build_object(
              'os', gen.pick('os:' || key, ARRAY['Tizen 8', 'webOS 24', 'Android TV 14', 'tvOS 18', 'Fire OS 8', 'Roku OS 14']),
              'screen', jsonb_build_object(
                  'resolution', gen.pick('res:' || key, ARRAY['2160p', '2160p', '2160p', '1080p']),
                  'hdr', gen.pick('hdr:' || key, ARRAY[
                      '["dolby_vision", "hdr10"]', '["hdr10"]', '["hdr10", "hlg"]', '[]']::jsonb[])),
              'codecs', gen.pick('codecs:' || key, ARRAY['["av1", "hevc", "h264"]', '["hevc", "h264"]']::jsonb[]))
          WHEN 'phone' THEN jsonb_build_object(
              'os', gen.pick('os:' || key, ARRAY['iOS 18', 'iOS 19', 'Android 15', 'Android 16']),
              'model', gen.pick('model:' || key, ARRAY['iPhone 16', 'iPhone 17', 'Pixel 9', 'Pixel 10', 'Galaxy S25', 'Xiaomi 15']),
              'screen', jsonb_build_object('resolution', '1080p', 'hdr', '["hdr10"]'::jsonb),
              'codecs', '["av1", "hevc", "h264"]'::jsonb,
              'downloads', true)
          WHEN 'tablet' THEN jsonb_build_object(
              'os', gen.pick('os:' || key, ARRAY['iPadOS 18', 'Android 15', 'Fire OS 8']),
              'screen', jsonb_build_object('resolution', '1080p', 'hdr', '[]'::jsonb),
              'codecs', '["hevc", "h264"]'::jsonb,
              'downloads', true)
          WHEN 'console' THEN jsonb_build_object(
              'os', gen.pick('os:' || key, ARRAY['PlayStation 5', 'Xbox Series X', 'Nintendo Switch 2']),
              'screen', jsonb_build_object('resolution', '2160p', 'hdr', '["hdr10"]'::jsonb),
              'codecs', '["hevc", "h264"]'::jsonb)
          ELSE jsonb_build_object(
              'os', gen.pick('os:' || key, ARRAY['Windows 11', 'macOS 15', 'ChromeOS', 'Ubuntu 24.04']),
              'browser', gen.pick('browser:' || key, ARRAY['Chrome', 'Chrome', 'Firefox', 'Safari', 'Edge']),
              'screen', jsonb_build_object('resolution', '1080p', 'hdr', '[]'::jsonb),
              'codecs', '["av1", "h264"]'::jsonb)
          END,
       least(gen.as_of() - interval '1 day',
             d.created_at + make_interval(days => CASE WHEN d.k = 1 THEN 0
                                                       ELSE gen.ri('seen:' || key, 1, 300)::int END))
FROM gen.device d,
     LATERAL (SELECT d.n || ':' || d.k AS key) AS kk
ORDER BY d.device_id;

--
-- Viewing. Each profile starts a number of titles over its account's
-- lifetime, favouring popular ones. Movies are watched in one sitting,
-- split over two, or abandoned; series are binged in order, a few episodes
-- a day.
--
CREATE TABLE gen.popular AS
SELECT array_agg(title_id ORDER BY score DESC, title_id) AS all_titles,
       array_agg(title_id ORDER BY score DESC, title_id) FILTER (WHERE kids) AS kids_titles
FROM (
    SELECT t.title_id, t.maturity <= 'TV-PG' AS kids,
           0.6 * g.quality + 0.4 * gen.r('buzz:' || t.title_id) AS score
    FROM title t JOIN gen.title g USING (title_id)
) s;

CREATE TABLE gen.ep AS
SELECT s.title_id, e.episode_id, e.runtime_min, s.released_on,
       row_number() OVER (PARTITION BY s.title_id ORDER BY s.season_no, e.episode_no) AS seq,
       count(*) OVER (PARTITION BY s.title_id) AS total
FROM episode e JOIN season s USING (season_id);
CREATE INDEX ON gen.ep (title_id, seq);

CREATE TABLE gen.span AS
SELECT a.account_id, a.n, a.region_code, r.timezone,
       a.created_at::date AS first_day,
       least(coalesce(a.cancel_day, date '2026-11-01'), date '2026-11-01') AS end_day
FROM gen.account a JOIN region r USING (region_code);

-- (profile, title) pairs, one row per title a profile starts.
CREATE TABLE gen.watch AS
SELECT DISTINCT ON (p.profile_id, x.title_id)
       p.profile_id, p.is_kids, sp.account_id, sp.n, sp.region_code, sp.timezone, sp.end_day,
       x.title_id, x.start_day, x.k
FROM gen.profile p
JOIN gen.span sp USING (n)
CROSS JOIN gen.popular pop,
     LATERAL (SELECT ((sp.end_day - sp.first_day) / 30.0
                      * (0.3 + 1.2 * gen.r('appetite:' || p.profile_id)))::int AS ntitles) AS a,
     LATERAL (
        SELECT p.profile_id || ':' || j AS k,
               sp.first_day + floor(gen.r('start:' || p.profile_id || ':' || j)
                                    * (sp.end_day - sp.first_day))::int AS start_day,
               CASE WHEN p.is_kids
                    THEN pop.kids_titles[1 + floor(power(gen.r('pick:' || p.profile_id || ':' || j), 1.8)
                                                   * cardinality(pop.kids_titles))::int]
                    ELSE pop.all_titles[1 + floor(power(gen.r('pick:' || p.profile_id || ':' || j), 1.8)
                                                  * cardinality(pop.all_titles))::int]
               END AS title_id
        FROM generate_series(1, least(a.ntitles, 40)) AS j
     ) AS x
WHERE sp.end_day > sp.first_day
  AND EXISTS (SELECT FROM license_window l
              WHERE l.title_id = x.title_id AND l.region_code = sp.region_code
                AND l.valid_at @> x.start_day)
ORDER BY p.profile_id, x.title_id, x.start_day, x.k COLLATE "C";

-- One row per planned sitting: (day, seconds of content watched).
CREATE TABLE gen.sitting AS
-- Movies
SELECT w.*, NULL::integer AS episode_id, 1 AS part, w.start_day AS day,
       0 AS from_s,
       CASE WHEN m < 0.7 THEN rt
            WHEN m < 0.85 THEN (rt * (0.4 + 0.3 * gen.r('split:' || w.k)))::int
            ELSE (rt * (0.1 + 0.3 * gen.r('quit:' || w.k)))::int END AS to_s,
       0 AS slot, NULL::date AS released_on
FROM gen.watch w
JOIN title t USING (title_id),
     LATERAL (SELECT t.runtime_min * 60 AS rt, gen.r('mode:' || w.k) AS m) AS x
WHERE t.kind = 'movie'
UNION ALL
-- ...the second half of a movie split over two sittings
SELECT w.*, NULL, 2, w.start_day + gen.ri('gap:' || w.k, 0, 3)::int,
       (rt * (0.4 + 0.3 * gen.r('split:' || w.k)))::int, rt, 1, NULL
FROM gen.watch w
JOIN title t USING (title_id),
     LATERAL (SELECT t.runtime_min * 60 AS rt, gen.r('mode:' || w.k) AS m) AS x
WHERE t.kind = 'movie' AND m >= 0.7 AND m < 0.85
UNION ALL
-- Series: episodes in order, `pace` a day, every `gap` days.
SELECT w.*, e.episode_id, e.seq::int,
       w.start_day + ((e.seq - 1) / pace)::int * gap,
       0,
       CASE WHEN e.seq = upto AND gen.r('stop:' || w.k) < 0.3
            THEN (e.runtime_min * 60 * (0.2 + 0.6 * gen.r('stopat:' || w.k)))::int
            ELSE e.runtime_min * 60 END,
       ((e.seq - 1) % pace)::int, e.released_on
FROM gen.watch w
JOIN title t USING (title_id)
CROSS JOIN LATERAL (SELECT gen.pick('pace:' || w.k, ARRAY[1, 1, 2, 2, 3, 4, 6]) AS pace,
                           gen.pick('gapd:' || w.k, ARRAY[1, 1, 1, 2, 3, 7]) AS gap) AS pg
CROSS JOIN LATERAL (SELECT CASE WHEN gen.r('all:' || w.k) < 0.35 THEN 1000
                                ELSE gen.ri('upto:' || w.k, 1, 12)::int END AS upto) AS u
JOIN gen.ep e ON e.title_id = w.title_id AND e.seq <= u.upto
WHERE t.kind = 'series';

-- Drop sittings after the account ended or before the episode existed.
DELETE FROM gen.sitting WHERE day >= end_day OR released_on > day;

CREATE TABLE gen.session AS
SELECT s.profile_id, s.title_id, s.episode_id, s.k, s.part, s.from_s, s.to_s,
       st.started_at,
       date_trunc('second', st.started_at + make_interval(
           secs => (s.to_s - s.from_s) * (1.02 + 0.1 * gen.r('pause:' || s.k || ':' || s.part)))) AS ended_at,
       d.device_id, d.kind AS device_kind, s.account_id, s.day
FROM gen.sitting s,
     LATERAL (SELECT gen.ri('evening:' || s.k || ':' || s.day, 0, 330)::int AS minutes) AS ev,
     -- Local evening start (kids in the afternoon); later episodes of the
     -- same day follow on from earlier ones.
     LATERAL (SELECT (s.day + CASE WHEN s.is_kids THEN time '15:00' ELSE time '18:00' END
                      + make_interval(mins => ev.minutes)
                      + make_interval(mins => s.slot * 50))
                     AT TIME ZONE s.timezone AS started_at) AS st,
     LATERAL (SELECT gd.device_id, gd.kind FROM gen.device gd
              WHERE gd.n = s.n
                AND gd.k = 1 + floor(gen.r('device:' || s.k || ':' || s.day) * gd.ndev)::int) AS d;

DELETE FROM gen.session WHERE started_at >= gen.as_of();

INSERT INTO viewing_session (profile_id, device_id, title_id, episode_id, started_at,
                             ended_at, position_from_s, position_to_s, quality)
SELECT s.profile_id, s.device_id, s.title_id, s.episode_id, s.started_at,
       least(s.ended_at, gen.as_of() - interval '1 second'), s.from_s, s.to_s,
       CASE WHEN sub.plan_id = 3 AND s.device_kind IN ('tv', 'console') THEN 'UHD'
            WHEN gen.r('sd:' || s.k || ':' || s.part) < 0.06 THEN 'SD'
            ELSE 'HD' END::video_quality
FROM gen.session s
LEFT JOIN subscription sub ON sub.account_id = s.account_id AND sub.valid_at @> s.day
ORDER BY s.started_at, s.profile_id, s.title_id, s.episode_id NULLS FIRST, s.part;

-- watch_progress from each profile's latest session per title, with the
-- same MERGE logic as record_session().
MERGE INTO watch_progress w
USING (
    SELECT DISTINCT ON (v.profile_id, v.title_id)
           v.profile_id, v.title_id, v.episode_id, v.position_to_s, v.ended_at,
           v.position_to_s >= 0.95 * playable_runtime_s(v.title_id, v.episode_id)
               AND v.episode_id IS NOT DISTINCT FROM
                   (SELECT e.episode_id FROM gen.ep e
                    WHERE e.title_id = v.title_id AND e.seq = e.total) AS finished
    FROM viewing_session v
    ORDER BY v.profile_id, v.title_id, v.started_at DESC
) s
ON w.profile_id = s.profile_id AND w.title_id = s.title_id
WHEN MATCHED THEN
    UPDATE SET episode_id = s.episode_id, position_s = s.position_to_s,
               finished = s.finished, updated_at = s.ended_at
WHEN NOT MATCHED THEN
    INSERT (profile_id, title_id, episode_id, position_s, finished, updated_at)
    VALUES (s.profile_id, s.title_id, s.episode_id, s.position_to_s, s.finished, s.ended_at);

-- Ratings: about a third of the titles a profile watched, better titles
-- rated higher.
INSERT INTO rating (profile_id, title_id, thumbs, rated_at)
SELECT w.profile_id, w.title_id,
       CASE WHEN score > 0.72 THEN 2 WHEN score > 0.38 THEN 1 ELSE -1 END,
       w.updated_at + make_interval(secs => gen.ri('rated:' || w.profile_id || ':' || w.title_id, 5, 600))
FROM watch_progress w
JOIN gen.title g USING (title_id),
     LATERAL (SELECT 0.4 * g.quality + 0.6 * gen.r('taste:' || w.profile_id || ':' || w.title_id)
                     + CASE WHEN w.finished THEN 0.1 ELSE -0.1 END AS score) AS s
WHERE gen.r('rate?' || w.profile_id || ':' || w.title_id) < 0.35
  AND w.updated_at < gen.as_of() - interval '10 minutes'
ORDER BY 4, 1, 2;

DROP SCHEMA gen CASCADE;
ANALYZE;
