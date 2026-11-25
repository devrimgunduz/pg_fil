--
-- pg_fil: ev-charging -- sample data generator
--
-- Run after schema.sql, into an empty database:
--   psql -d ev-charging -f generate-data.sql
--   psql -d ev-charging -v scale=3 -f generate-data.sql     -- 3x the network
--
-- The output is deterministic: every "random" choice is a hash of a key
-- string (see gen.r below), never random() or the clock, so the same scale
-- always gives the same rows on any server, in any time zone.
--
-- The data covers 2025-07-01 to 2026-10-31 and is "as of" 2026-11-01
-- 00:00 UTC; sessions still plugged in at that moment have no end yet.
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
    IF EXISTS (SELECT FROM site) THEN
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
INSERT INTO operator (operator_id, name, party_id) VALUES
    (1, 'VoltWay', 'DE*VWY'),
    (2, 'Northcharge', 'NL*NCH'),
    (3, 'Ampere Roads', 'FR*AMR'),
    (4, 'GreenPlug', 'ES*GPL');

INSERT INTO roaming_partner (partner_id, name, party_id, markup_per_kwh) VALUES
    (1, 'VoltWay App', 'DE*VWA', 0),
    (2, 'Northcharge App', 'NL*NCA', 0),
    (3, 'ChargeAnywhere', 'DE*CAW', 0.05),
    (4, 'RoamPass', 'BE*RPS', 0.08),
    (5, 'FleetCharge', 'NL*FLC', 0.03);

INSERT INTO vehicle_model (model_id, make, model, battery_kwh, max_ac_kw, max_dc_kw, dc_standard) VALUES
    (1, 'Tesla', 'Model 3 Long Range', 75, 11, 250, 'CCS2'),
    (2, 'Tesla', 'Model Y', 75, 11, 250, 'CCS2'),
    (3, 'Volkswagen', 'ID.4 Pro', 77, 11, 135, 'CCS2'),
    (4, 'Hyundai', 'Ioniq 5', 77.4, 11, 230, 'CCS2'),
    (5, 'Kia', 'EV6', 77.4, 11, 233, 'CCS2'),
    (6, 'Renault', 'Megane E-Tech', 60, 22, 130, 'CCS2'),
    (7, 'Nissan', 'Leaf e+', 59, 6.6, 50, 'CHAdeMO'),
    (8, 'BMW', 'i4 eDrive40', 81, 11, 205, 'CCS2'),
    (9, 'Polestar', '2 Long Range', 78, 11, 205, 'CCS2'),
    (10, 'Fiat', '500e', 42, 11, 85, 'CCS2'),
    (11, 'MG', 'MG4 Long Range', 64, 11, 135, 'CCS2'),
    (12, 'BYD', 'Atto 3', 60.5, 11, 88, 'CCS2'),
    (13, 'Skoda', 'Enyaq 85', 77, 11, 135, 'CCS2'),
    (14, 'Mercedes-Benz', 'EQA 250', 66.5, 11, 100, 'CCS2'),
    (15, 'Peugeot', 'e-208', 50, 11, 100, 'CCS2');

-- Time-of-use tariffs for 2025 and 2026: AC has one flat price and no
-- blocking fee (cars charge overnight), DC is cheapest overnight and
-- dearest in the evening peak, with a blocking fee for cars left plugged in
-- more than 10 minutes after charging stopped. Prices rose in 2026.
INSERT INTO tariff (operator_id, power_type, valid_at, hours, label, energy_per_kwh,
                    idle_per_min, idle_after, session_fee)
SELECT o.operator_id, b.power_type, y.valid_at, b.hours, b.label,
       round(b.price * o.factor * y.factor, 2),
       b.idle_per_min, b.idle_after,
       CASE WHEN o.operator_id = 4 THEN 0.50 ELSE 0 END
FROM (VALUES (1, 1.00), (2, 0.95), (3, 1.05), (4, 0.90)) AS o(operator_id, factor)
CROSS JOIN (VALUES (daterange('2025-01-01', '2026-01-01'), 1.00),
                   (daterange('2026-01-01', NULL), 1.08)) AS y(valid_at, factor)
CROSS JOIN (VALUES
    ('AC'::power_type, int4range(0, 24), 'AC standard', 0.39, 0, interval '0'),
    ('DC', int4range(0, 7), 'DC off-peak', 0.49, 0.40, interval '10 minutes'),
    ('DC', int4range(7, 17), 'DC standard', 0.59, 0.40, interval '10 minutes'),
    ('DC', int4range(17, 21), 'DC peak', 0.69, 0.40, interval '10 minutes'),
    ('DC', int4range(21, 24), 'DC standard', 0.59, 0.40, interval '10 minutes')
) AS b(power_type, hours, label, price, idle_per_min, idle_after)
ORDER BY 1, 2, lower(y.valid_at), lower(b.hours);

--
-- Sites, chargers and connectors
--
CREATE TABLE gen.city AS
SELECT * FROM (VALUES
    ('Berlin', 'DE', 'Europe/Berlin', 13.4050, 52.5200, 1),
    ('Munich', 'DE', 'Europe/Berlin', 11.5820, 48.1351, 1),
    ('Hamburg', 'DE', 'Europe/Berlin', 9.9937, 53.5511, 1),
    ('Cologne', 'DE', 'Europe/Berlin', 6.9603, 50.9375, 1),
    ('Frankfurt', 'DE', 'Europe/Berlin', 8.6821, 50.1109, 1),
    ('Amsterdam', 'NL', 'Europe/Amsterdam', 4.9041, 52.3676, 2),
    ('Rotterdam', 'NL', 'Europe/Amsterdam', 4.4777, 51.9244, 2),
    ('Utrecht', 'NL', 'Europe/Amsterdam', 5.1214, 52.0907, 2),
    ('Brussels', 'BE', 'Europe/Brussels', 4.3517, 50.8503, 2),
    ('Antwerp', 'BE', 'Europe/Brussels', 4.4025, 51.2194, 2),
    ('Paris', 'FR', 'Europe/Paris', 2.3522, 48.8566, 3),
    ('Lyon', 'FR', 'Europe/Paris', 4.8357, 45.7640, 3),
    ('Marseille', 'FR', 'Europe/Paris', 5.3698, 43.2965, 3),
    ('Vienna', 'AT', 'Europe/Vienna', 16.3738, 48.2082, 1),
    ('Madrid', 'ES', 'Europe/Madrid', -3.7038, 40.4168, 4),
    ('Barcelona', 'ES', 'Europe/Madrid', 2.1734, 41.3851, 4),
    ('Valencia', 'ES', 'Europe/Madrid', -0.3763, 39.4699, 4),
    ('Lisbon', 'PT', 'Europe/Lisbon', -9.1393, 38.7223, 4),
    ('Milan', 'IT', 'Europe/Rome', 9.1900, 45.4642, 3),
    ('Rome', 'IT', 'Europe/Rome', 12.4964, 41.9028, 3)
) AS c(name, cc, tz, lon, lat, home_operator);

CREATE TABLE gen.site AS
SELECT i AS site_id, c.*,
       gen.r('hub:' || i) < 0.45 AS is_hub,
       0.3 + 0.7 * gen.r('pop:' || i) AS popularity
FROM generate_series(1, 100 * :scale) AS i
JOIN LATERAL (SELECT * FROM gen.city ORDER BY name COLLATE "C"
              OFFSET gen.ri('city:' || i, 0, 19) LIMIT 1) AS c ON true;

INSERT INTO site (operator_id, name, city, country_code, timezone, location, opened_on, facilities)
SELECT CASE WHEN gen.r('op:' || s.site_id) < 0.75 THEN s.home_operator
            ELSE gen.ri('op2:' || s.site_id, 1, 4) END,
       s.name || ' ' ||
       CASE WHEN s.is_hub THEN gen.pick('hubname:' || s.site_id, ARRAY['Motorway Services',
                'Ring Road Hub', 'Airport P3', 'Retail Park', 'Logistics Park', 'Highway Exit'])
            ELSE gen.pick('destname:' || s.site_id, ARRAY['City Centre Garage', 'Central Station',
                'Supermarket', 'Harbour', 'Business Park', 'Hotel Garage', 'University', 'Old Town'])
       END || ' ' || s.site_id,
       s.name, s.cc, s.tz,
       ST_Project(ST_SetSRID(ST_MakePoint(s.lon, s.lat), 4326)::geography,
                  CASE WHEN s.is_hub THEN 4000 + 21000 * gen.r('dist:' || s.site_id)
                       ELSE 6000 * sqrt(gen.r('dist:' || s.site_id)) END,
                  2 * pi() * gen.r('az:' || s.site_id)),
       date '2023-01-01' + gen.ri('opened:' || s.site_id, 0, 900)::int,
       ARRAY(SELECT f FROM unnest(ARRAY['toilets', 'cafe', 'shop', 'wifi', 'playground', 'covered']) AS f
             WHERE gen.r('fac:' || s.site_id || f) < CASE WHEN s.is_hub THEN 0.6 ELSE 0.25 END)
FROM gen.site s
ORDER BY s.site_id;

CREATE TABLE gen.charger AS
SELECT row_number() OVER (ORDER BY s.site_id, k) AS charger_id, s.site_id, k, s.is_hub,
       CASE WHEN k <= ndc THEN 'DC' ELSE 'AC' END::power_type AS power_type
FROM gen.site s,
     LATERAL (SELECT CASE WHEN s.is_hub THEN gen.ri('ndc:' || s.site_id, 2, 4)
                          ELSE gen.ri('ndc:' || s.site_id, 0, 1) END::int AS ndc,
                     CASE WHEN s.is_hub THEN gen.ri('nac:' || s.site_id, 0, 2)
                          ELSE gen.ri('nac:' || s.site_id, 2, 4) END::int AS nac) AS n,
     generate_series(1, ndc + nac) AS k;

INSERT INTO charger (site_id, ocpp_id, vendor, model, power_type, max_kw, firmware, installed_on)
SELECT g.site_id,
       o.party_id || '-' || lpad(g.site_id::text, 4, '0') || '-' || g.k,
       v.vendor,
       v.vendor || ' ' || gen.pick('model:' || g.charger_id, v.models),
       g.power_type,
       CASE WHEN g.power_type = 'DC' THEN gen.pick('dckw:' || g.charger_id, ARRAY[50, 150, 150, 300, 350])
            ELSE gen.pick('ackw:' || g.charger_id, ARRAY[11, 22, 22]) END,
       gen.ri('fw:' || g.charger_id, 1, 4) || '.' || gen.ri('fw2:' || g.charger_id, 0, 12) || '.' || gen.ri('fw3:' || g.charger_id, 0, 9),
       s.opened_on
FROM gen.charger g
JOIN site s USING (site_id)
JOIN operator o USING (operator_id),
     LATERAL (SELECT * FROM (VALUES
        ('DC'::power_type, 'Alpitronic', ARRAY['HYC300', 'HYC400']),
        ('DC', 'Kempower', ARRAY['S-Series', 'T-Series']),
        ('DC', 'ABB', ARRAY['Terra 184', 'Terra 360']),
        ('DC', 'Ekoenergetyka', ARRAY['Axon Side 360']),
        ('AC', 'Alfen', ARRAY['Eve Double Pro']),
        ('AC', 'Wallbox', ARRAY['Commander 2', 'Copper SB']),
        ('AC', 'Mennekes', ARRAY['AMTRON Charge Control']),
        ('AC', 'Compleo', ARRAY['Cito 500'])
     ) AS v(power_type, vendor, models)
     WHERE v.power_type = g.power_type
     ORDER BY gen.r('vendor:' || g.charger_id || v.vendor) LIMIT 1) AS v
ORDER BY g.charger_id;

INSERT INTO connector (charger_id, connector_no, standard, max_kw)
SELECT c.charger_id, n,
       CASE WHEN c.power_type = 'AC' THEN 'Type2'
            WHEN n = 2 AND c.max_kw = 50 THEN 'CHAdeMO'
            ELSE 'CCS2' END::connector_standard,
       c.max_kw
FROM charger c, generate_series(1, 2) AS n
ORDER BY c.charger_id, n;

--
-- Drivers, vehicles and tokens
--
INSERT INTO driver (full_name, email, country_code, partner_id)
SELECT name, gen.email(name, i, 'drivers.example.com'),
       gen.pick('dcc:' || i, ARRAY['DE','DE','DE','NL','NL','BE','FR','FR','AT','ES','ES','PT','IT','IT']),
       gen.pick('partner:' || i, ARRAY[1, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5])
FROM generate_series(1, 10000 * :scale) AS i,
     LATERAL gen.person('driver:' || i) AS name
ORDER BY i;

INSERT INTO vehicle (driver_id, model_id, plate)
SELECT d.driver_id,
       gen.pick('vm:' || d.driver_id || ':' || n, ARRAY[1,1,2,2,2,3,3,4,5,6,7,8,9,10,11,11,12,13,13,14,15]),
       d.country_code || '-' || upper(substr(md5('plate:' || d.driver_id || ':' || n), 1, 2))
           || '-' || lpad(gen.ri('platen:' || d.driver_id || ':' || n, 1, 9999)::text, 4, '0')
FROM driver d,
     generate_series(1, CASE WHEN gen.r('2cars:' || d.driver_id) < 0.05 THEN 2 ELSE 1 END) AS n
ORDER BY d.driver_id, n;

INSERT INTO rfid_token (token_uid, driver_id, issued_on, is_valid)
SELECT upper(substr(md5('token:' || d.driver_id), 1, 14)), d.driver_id,
       date '2024-01-01' + gen.ri('issued:' || d.driver_id, 0, 540)::int,
       gen.r('revoked:' || d.driver_id) >= 0.01
FROM driver d
ORDER BY d.driver_id;

--
-- Outages: up to four per connector, each in its own quarter of the
-- 16 months, so they never overlap.
--
INSERT INTO connector_outage (connector_id, during, error_code)
SELECT c.connector_id, tstzrange(st, st + dur),
       gen.pick('err:' || k, ARRAY['GroundFailure', 'HighTemperature', 'PowerMeterFailure',
                                   'ConnectorLockFailure', 'EVCommunicationError', 'InternalError',
                                   'OverCurrentFailure', 'InternalError'])
FROM connector c,
     generate_series(0, 3) AS q,
     LATERAL (SELECT c.connector_id || ':' || q AS k) AS kk,
     LATERAL (SELECT timestamptz '2025-07-01 00:00+00'
                     + make_interval(days => 122 * q + gen.ri('outday:' || k, 0, 100)::int,
                                     mins => gen.ri('outmin:' || k, 0, 1439)::int) AS st,
                     -- mostly short, sometimes days while waiting for a technician
                     make_interval(mins => (20 + 4000 * power(gen.r('outlen:' || k), 3))::int) AS dur) AS o
WHERE gen.r('outage?' || k) < 0.45
ORDER BY 2, 1;

--
-- Charging sessions. Each connector's local day is cut into slots (six
-- 4-hour slots on DC, two 12-hour slots on AC) holding at most one
-- session, which keeps sessions on a connector from overlapping. Demand
-- depends on the site's popularity, the time of day and grows over time.
--
CREATE TABLE gen.vehicle_pool AS
SELECT array_agg(v.vehicle_id ORDER BY v.vehicle_id) AS any_vehicle,
       array_agg(v.vehicle_id ORDER BY v.vehicle_id) FILTER (WHERE m.dc_standard = 'CCS2') AS ccs2,
       array_agg(v.vehicle_id ORDER BY v.vehicle_id) FILTER (WHERE m.dc_standard = 'CHAdeMO') AS chademo
FROM vehicle v JOIN vehicle_model m USING (model_id);

CREATE TABLE gen.slot AS
SELECT c.connector_id, c.standard, c.max_kw, ch.power_type, ch.charger_id, s.timezone, gs.popularity,
       d::date AS day, slot,
       c.connector_id || ':' || d::date || ':' || slot AS k,
       ((d::date + make_interval(hours => CASE WHEN ch.power_type = 'DC' THEN 4 * slot ELSE 6 + 12 * slot END))
         AT TIME ZONE s.timezone) AS slot_start
FROM connector c
JOIN charger ch USING (charger_id)
JOIN site s USING (site_id)
JOIN gen.site gs USING (site_id)
CROSS JOIN generate_series(timestamp '2025-07-01', timestamp '2026-10-31', interval '1 day') AS d
CROSS JOIN LATERAL generate_series(0, CASE WHEN ch.power_type = 'DC' THEN 5 ELSE 1 END) AS slot
WHERE gen.r('slot:' || c.connector_id || ':' || d::date || ':' || slot)
      < CASE WHEN ch.power_type = 'DC'
             THEN 0.22 * (ARRAY[0.15, 0.6, 1.0, 1.0, 0.8, 0.35])[slot + 1]
             ELSE 0.25 * (ARRAY[0.7, 0.9])[slot + 1] END
        * gs.popularity
        * (0.6 + 0.4 * (d::date - date '2025-07-01') / 488.0)
        -- a bit busier on Fridays and Saturdays
        * CASE WHEN extract(isodow FROM d) IN (5, 6) THEN 1.2 ELSE 1 END;

CREATE TABLE gen.session AS
SELECT x.*,
       x.slot_start + make_interval(mins => x.offset_min) AS started_at,
       x.slot_start + make_interval(mins => x.offset_min + x.charge_min) AS charging_ended_at,
       x.slot_start + make_interval(mins => x.offset_min + greatest(x.charge_min + x.idle_min, 2)) AS ended_at,
       round((x.avg_kw * x.charge_min / 60.0)::numeric, 3) AS energy_kwh,
       least(100, x.soc_start + round(100 * x.avg_kw * x.charge_min / 60.0 / x.battery_kwh))::int AS soc_end
FROM (
    SELECT s.*, v.vehicle_id, v.driver_id, m.model_id, m.battery_kwh,
           -- start anywhere in the slot that leaves room for the session
           gen.ri('off:' || s.k, 0, CASE WHEN s.power_type = 'DC' THEN 239 ELSE 719 END
                                    - d.charge_min - d.idle_min)::int AS offset_min,
           d.charge_min, d.idle_min,
           soc.soc_start,
           kw.avg_kw,
           CASE WHEN s.power_type = 'DC'
                THEN gen.pick('stop:' || s.k, ARRAY['Local', 'Local', 'Local', 'EVDisconnected', 'EVDisconnected', 'Remote'])
                ELSE 'EVDisconnected' END::stop_reason AS stop_reason
    FROM gen.slot s
    CROSS JOIN gen.vehicle_pool p
    CROSS JOIN LATERAL (SELECT CASE s.standard
                                   WHEN 'CHAdeMO' THEN p.chademo
                                   WHEN 'CCS2' THEN p.ccs2
                                   ELSE p.any_vehicle END AS pool) AS pl
    JOIN vehicle v ON v.vehicle_id = pl.pool[1 + floor(power(gen.r('veh:' || s.k), 1.3) * cardinality(pl.pool))::int]
    JOIN vehicle_model m USING (model_id)
    CROSS JOIN LATERAL (
        SELECT CASE WHEN s.power_type = 'DC' THEN gen.ri('soc0:' || s.k, 8, 45)
                    ELSE gen.ri('soc0:' || s.k, 15, 70) END::int AS soc_start,
               CASE WHEN s.power_type = 'DC' THEN gen.ri('soc1:' || s.k, 70, 90)
                    ELSE gen.ri('soc1:' || s.k, 80, 100) END::int AS target) AS soc
    -- average power: below the car's and charger's maximum, and varying
    -- with battery temperature and the like
    CROSS JOIN LATERAL (
        SELECT CASE WHEN s.power_type = 'DC' THEN (0.5 + 0.3 * gen.r('kw:' || s.k)) * least(s.max_kw, m.max_dc_kw)
                    ELSE 0.95 * least(s.max_kw, m.max_ac_kw) END::float8 AS avg_kw) AS kw
    CROSS JOIN LATERAL (
        -- minutes on charge: until the target state of charge (DC, at
        -- most 110 minutes), or until the driver comes back (AC)
        SELECT CASE WHEN s.power_type = 'DC'
                    THEN least(110, greatest(4, ceil(60 * m.battery_kwh * (soc.target - soc.soc_start) / 100.0 / kw.avg_kw)))
                    ELSE least(ceil(60 * m.battery_kwh * (soc.target - soc.soc_start) / 100.0 / kw.avg_kw),
                               CASE WHEN s.slot = 0 THEN gen.ri('plug:' || s.k, 90, 520)
                                    ELSE gen.ri('plug:' || s.k, 360, 530) END)
               END::int AS charge_min,
               -- minutes still plugged in after charging stopped (AC cars
               -- stay until the driver comes back, which is in charge_min)
               CASE WHEN s.power_type = 'DC'
                    THEN CASE WHEN gen.r('hog:' || s.k) < 0.06 THEN gen.ri('idle:' || s.k, 15, 60)
                              ELSE gen.ri('idle:' || s.k, 0, 8) END
                    ELSE 0 END::int AS idle_min) AS d
) x;

-- Slots are in local time, so on the night clocks spring forward a long
-- session can run into the next slot's; drop the later one.
DELETE FROM gen.session s
USING (SELECT connector_id, started_at,
              lag(ended_at) OVER (PARTITION BY connector_id ORDER BY started_at, k COLLATE "C") AS prev_end
       FROM gen.session) p
WHERE p.connector_id = s.connector_id AND p.started_at = s.started_at
  AND p.started_at < p.prev_end;

-- No sessions while the connector was broken, and none starting after the
-- data ends.
DELETE FROM gen.session s
USING connector_outage o
WHERE o.connector_id = s.connector_id
  AND o.during && tstzrange(s.started_at, s.ended_at);
DELETE FROM gen.session WHERE started_at >= gen.as_of() - interval '5 minutes';

INSERT INTO charging_session (connector_id, token_uid, vehicle_id, started_at, charging_ended_at,
                              ended_at, energy_kwh, soc_start, soc_end, stop_reason)
SELECT s.connector_id, t.token_uid, s.vehicle_id, s.started_at,
       -- Sessions still going on at the end of the data have no end yet.
       CASE WHEN s.charging_ended_at < gen.as_of() THEN s.charging_ended_at END,
       CASE WHEN s.ended_at < gen.as_of() THEN s.ended_at END,
       CASE WHEN s.ended_at < gen.as_of() THEN s.energy_kwh END,
       s.soc_start,
       CASE WHEN s.ended_at < gen.as_of() THEN s.soc_end END,
       CASE WHEN s.ended_at < gen.as_of() THEN s.stop_reason END
FROM gen.session s
JOIN rfid_token t USING (driver_id)
ORDER BY s.started_at, s.connector_id;

--
-- Meter values: every 5 minutes on DC and every hour on AC while charging.
-- Charging follows a curve: fast at first, tapering off on DC as the
-- battery fills, nearly flat on AC.
--
INSERT INTO meter_value (session_id, connector_id, measured_at, energy_wh, power_w, soc, voltage_v, current_a)
SELECT s.session_id, s.connector_id, t.at,
       round(1000 * e.energy_kwh * f.frac)::int,
       round(1000 * e.energy_kwh * f.rate / e.hours)::int,
       round(s.soc_start + (e.soc_end - s.soc_start) * f.frac)::smallint,
       CASE WHEN ch.power_type = 'AC' THEN 230.0
            ELSE round((CASE WHEN m.model_id IN (4, 5) THEN 760 ELSE 380 END + 40 * f.frac)::numeric, 1) END,
       round((1000 * e.energy_kwh * f.rate / e.hours
              / CASE WHEN ch.power_type = 'AC' THEN 3 * 230.0
                     ELSE (CASE WHEN m.model_id IN (4, 5) THEN 760 ELSE 380 END + 40 * f.frac) END)::numeric, 1)
FROM charging_session s
JOIN connector c USING (connector_id)
JOIN charger ch USING (charger_id)
JOIN vehicle v USING (vehicle_id)
JOIN vehicle_model m USING (model_id)
JOIN gen.session g ON g.connector_id = s.connector_id AND g.started_at = s.started_at
CROSS JOIN LATERAL (SELECT g.energy_kwh, g.soc_end,
                           extract(epoch FROM g.charging_ended_at - g.started_at) / 3600.0 AS hours,
                           CASE WHEN ch.power_type = 'DC' THEN 1.2 ELSE 0.2 END AS a) AS e
CROSS JOIN LATERAL generate_series(s.started_at + CASE WHEN ch.power_type = 'DC' THEN interval '5 minutes' ELSE interval '1 hour' END,
                                   least(g.charging_ended_at, gen.as_of() - interval '1 second'),
                                   CASE WHEN ch.power_type = 'DC' THEN interval '5 minutes' ELSE interval '1 hour' END) AS t(at)
CROSS JOIN LATERAL (SELECT extract(epoch FROM t.at - s.started_at) / 3600.0 / e.hours AS tau) AS tt
CROSS JOIN LATERAL (SELECT (1 - exp(-e.a * tt.tau)) / (1 - exp(-e.a)) AS frac,
                           e.a * exp(-e.a * tt.tau) / (1 - exp(-e.a)) AS rate) AS f
ORDER BY t.at, s.session_id;

--
-- OCPP messages
--
INSERT INTO ocpp_message (charger_id, received_at, action, payload)
SELECT charger_id, received_at, action, payload
FROM (
    SELECT c.charger_id, s.started_at + interval '2 seconds' AS received_at, 'StartTransaction' AS action,
           jsonb_build_object('connectorId', c.connector_no, 'idTag', s.token_uid, 'meterStart', 0,
                              'timestamp', to_char(s.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) AS payload
    FROM charging_session s JOIN connector c USING (connector_id)
    UNION ALL
    SELECT c.charger_id, s.ended_at + interval '2 seconds', 'StopTransaction',
           jsonb_build_object(
               'transactionId', s.session_id, 'idTag', s.token_uid,
               'meterStop', round(1000 * s.energy_kwh)::int,
               'timestamp', to_char(s.ended_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'reason', s.stop_reason,
               'transactionData', jsonb_build_array(jsonb_build_object(
                   'timestamp', to_char(s.charging_ended_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   'sampledValue', jsonb_build_array(
                       jsonb_build_object('measurand', 'Energy.Active.Import.Register',
                                          'value', round(1000 * s.energy_kwh)::text, 'unit', 'Wh'),
                       jsonb_build_object('measurand', 'SoC', 'value', s.soc_end::text,
                                          'unit', 'Percent', 'location', 'EV')))))
    FROM charging_session s JOIN connector c USING (connector_id)
    WHERE s.ended_at IS NOT NULL
    UNION ALL
    SELECT c.charger_id, lower(o.during), 'StatusNotification',
           jsonb_build_object('connectorId', c.connector_no, 'status', 'Faulted',
                              'errorCode', o.error_code,
                              'vendorErrorCode', 'E-' || gen.ri('vec:' || o.outage_id, 100, 999),
                              'timestamp', to_char(lower(o.during) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    FROM connector_outage o JOIN connector c USING (connector_id)
    UNION ALL
    SELECT c.charger_id, upper(o.during), 'StatusNotification',
           jsonb_build_object('connectorId', c.connector_no, 'status', 'Available',
                              'errorCode', 'NoError',
                              'timestamp', to_char(upper(o.during) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    FROM connector_outage o JOIN connector c USING (connector_id)
    WHERE upper(o.during) < gen.as_of()
) m
ORDER BY received_at, charger_id, action COLLATE "C", md5(payload::text) COLLATE "C";

--
-- Charge detail records for finished sessions, priced by rate_session().
--
INSERT INTO cdr (session_id, partner_id, tariff_id, energy_kwh, energy_cost, idle_cost, session_fee, created_at)
SELECT s.session_id, d.partner_id, r.tariff_id, s.energy_kwh, r.energy_cost, r.idle_cost, r.session_fee,
       s.ended_at + interval '5 minutes'
FROM charging_session s
JOIN rfid_token t USING (token_uid)
JOIN driver d USING (driver_id)
CROSS JOIN LATERAL rate_session(s.session_id) AS r
WHERE s.ended_at IS NOT NULL
ORDER BY s.ended_at, s.session_id;

DROP SCHEMA gen CASCADE;
ANALYZE;
