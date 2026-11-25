--
-- pagila-ng: ev-charging
--
-- A European electric vehicle charging network: operators run sites with
-- AC and DC chargers; drivers of roaming partners (e-mobility providers)
-- start charging sessions with RFID tokens; chargers stream meter values
-- and OCPP messages; every session is priced into a charge detail record
-- (CDR) using a time-of-use tariff. All amounts are in EUR.
--
-- PostgreSQL features shown here:
--   * time-series data: meter_value is partitioned by month and indexed
--     with BRIN, which stays tiny for append-only, time-ordered data
--   * date_bin() for load curves at any bucket size
--   * exclusion constraints over two ranges at once (tariff periods x hours
--     of day), and over an expression (a connector can't have overlapping
--     sessions)
--   * range_agg() and multirange arithmetic for connector uptime
--   * JSONB OCPP messages queried with SQL/JSON path, JSON_VALUE and
--     JSON_TABLE
--   * PostGIS for "nearest fast charger" searches
--
-- Requires PostgreSQL 18+ and PostGIS. Load with:
--   createdb ev-charging
--   psql -d ev-charging -f schema.sql
--   psql -d ev-charging -f generate-data.sql
--

SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TYPE power_type AS ENUM ('AC', 'DC');
CREATE TYPE connector_standard AS ENUM ('Type2', 'CCS2', 'CHAdeMO');
CREATE TYPE stop_reason AS ENUM ('EVDisconnected', 'Local', 'Remote', 'PowerLoss', 'EmergencyStop');

CREATE TABLE operator (
    operator_id smallint PRIMARY KEY,
    name text NOT NULL UNIQUE,
    -- OCPI-style party id, e.g. DE*VWY
    party_id text NOT NULL UNIQUE
);

-- roaming_partner: e-mobility service providers whose customers charge on
-- the network (the operators' own apps are partners too).
CREATE TABLE roaming_partner (
    partner_id smallint PRIMARY KEY,
    name text NOT NULL UNIQUE,
    party_id text NOT NULL UNIQUE,
    -- what the partner pays on top of the tariff, per kWh
    markup_per_kwh numeric(6,4) NOT NULL DEFAULT 0
);

CREATE TABLE site (
    site_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operator_id smallint NOT NULL REFERENCES operator,
    name text NOT NULL,
    city text NOT NULL,
    country_code char(2) NOT NULL,
    timezone text NOT NULL,
    location geography(Point, 4326) NOT NULL,
    opened_on date NOT NULL,
    facilities text[] NOT NULL DEFAULT '{}'
);

CREATE INDEX site_location_idx ON site USING gist (location);
CREATE INDEX site_operator_id_idx ON site (operator_id);

CREATE TABLE charger (
    charger_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id integer NOT NULL REFERENCES site,
    ocpp_id text NOT NULL UNIQUE,
    vendor text NOT NULL,
    model text NOT NULL,
    power_type power_type NOT NULL,
    max_kw numeric(5,1) NOT NULL,
    firmware text NOT NULL,
    installed_on date NOT NULL
);

CREATE INDEX charger_site_id_idx ON charger (site_id);

CREATE TABLE connector (
    connector_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    charger_id integer NOT NULL REFERENCES charger,
    connector_no smallint NOT NULL,
    standard connector_standard NOT NULL,
    max_kw numeric(5,1) NOT NULL,
    UNIQUE (charger_id, connector_no)
);

-- tariff: time-of-use pricing. Each row prices one operator's AC or DC
-- charging during a date period (valid_at) and a band of local hours of
-- the day (hours, e.g. [17,21) for the evening peak).
--
-- The exclusion constraint compares two ranges at once: two rows for the
-- same operator and power type may share dates or share hours, but not
-- both, so every (day, hour) has at most one price.
CREATE TABLE tariff (
    tariff_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operator_id smallint NOT NULL REFERENCES operator,
    power_type power_type NOT NULL,
    valid_at daterange NOT NULL,
    hours int4range NOT NULL CHECK (hours <@ int4range(0, 24)),
    label text NOT NULL,
    energy_per_kwh numeric(6,4) NOT NULL,
    -- blocking fee: per minute the car stays plugged in after charging
    -- has stopped, beyond a grace period of idle_after
    idle_per_min numeric(6,4) NOT NULL DEFAULT 0,
    idle_after interval NOT NULL DEFAULT '10 minutes',
    session_fee numeric(6,2) NOT NULL DEFAULT 0,
    EXCLUDE USING gist (operator_id WITH =, power_type WITH =, valid_at WITH &&, hours WITH &&)
);

CREATE TABLE driver (
    driver_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    email text NOT NULL UNIQUE,
    country_code char(2) NOT NULL,
    partner_id smallint NOT NULL REFERENCES roaming_partner
);

CREATE TABLE vehicle_model (
    model_id smallint PRIMARY KEY,
    make text NOT NULL,
    model text NOT NULL,
    battery_kwh numeric(5,1) NOT NULL,
    max_ac_kw numeric(4,1) NOT NULL,
    max_dc_kw numeric(5,1) NOT NULL,
    dc_standard connector_standard NOT NULL,
    UNIQUE (make, model)
);

CREATE TABLE vehicle (
    vehicle_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    driver_id integer NOT NULL REFERENCES driver,
    model_id smallint NOT NULL REFERENCES vehicle_model,
    plate text NOT NULL
);

CREATE INDEX vehicle_driver_id_idx ON vehicle (driver_id);

CREATE TABLE rfid_token (
    token_uid text PRIMARY KEY,
    driver_id integer NOT NULL REFERENCES driver,
    issued_on date NOT NULL,
    is_valid boolean NOT NULL DEFAULT true
);

CREATE INDEX rfid_token_driver_id_idx ON rfid_token (driver_id);

-- charging_session: plugged in at started_at, unplugged at ended_at (NULL
-- while still charging). A connector can only serve one car at a time;
-- the exclusion constraint enforces it on an expression, the range from
-- plug-in to unplug.
CREATE TABLE charging_session (
    session_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    connector_id integer NOT NULL REFERENCES connector,
    token_uid text NOT NULL REFERENCES rfid_token,
    vehicle_id integer REFERENCES vehicle,
    started_at timestamptz NOT NULL,
    charging_ended_at timestamptz,
    ended_at timestamptz,
    energy_kwh numeric(7,3),
    soc_start smallint CHECK (soc_start BETWEEN 0 AND 100),
    soc_end smallint CHECK (soc_end BETWEEN 0 AND 100),
    stop_reason stop_reason,
    CHECK (ended_at > started_at),
    CHECK (charging_ended_at BETWEEN started_at AND ended_at),
    EXCLUDE USING gist (connector_id WITH =, tstzrange(started_at, ended_at) WITH &&)
);

CREATE INDEX charging_session_token_idx ON charging_session (token_uid);
CREATE INDEX charging_session_started_at_idx ON charging_session (started_at);

-- meter_value: what the charger reports during a session (every 5 minutes
-- on DC, every hour on AC). By far the largest table: partitioned by month
-- and indexed with BRIN. Rows arrive in time order, so each block range
-- covers a narrow slice of time and the BRIN index stays a few pages big,
-- where a B-tree would be several megabytes.
CREATE TABLE meter_value (
    session_id bigint NOT NULL,
    connector_id integer NOT NULL,
    measured_at timestamptz NOT NULL,
    energy_wh integer NOT NULL,
    power_w integer NOT NULL,
    soc smallint,
    voltage_v numeric(5,1),
    current_a numeric(6,1)
) PARTITION BY RANGE (measured_at);

CREATE INDEX meter_value_measured_at_brin ON meter_value USING brin (measured_at);
CREATE INDEX meter_value_session_idx ON meter_value (session_id, measured_at);

-- Monthly partitions for the generated data (2025-06 to 2026-12; local
-- midnight on 2025-07-01 is still June in UTC), named
-- the way pg_partman names them; pg_partman-setup.sql can take over from
-- 2027-01.
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2025-06-01', date '2026-12-01', interval '1 month')::date
    LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF meter_value FOR VALUES FROM (%L) TO (%L)',
            'meter_value_p' || to_char(m, 'YYYYMMDD'),
            m::timestamp AT TIME ZONE 'UTC',
            (m + interval '1 month')::timestamp AT TIME ZONE 'UTC');
    END LOOP;
END
$$;

-- ocpp_message: raw OCPP 1.6 JSON messages as the chargers sent them
-- (StartTransaction, StopTransaction, StatusNotification), kept for
-- auditing and debugging.
CREATE TABLE ocpp_message (
    message_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    charger_id integer NOT NULL REFERENCES charger,
    received_at timestamptz NOT NULL,
    action text NOT NULL,
    payload jsonb NOT NULL
);

CREATE INDEX ocpp_message_received_at_brin ON ocpp_message USING brin (received_at);
CREATE INDEX ocpp_message_charger_idx ON ocpp_message (charger_id, received_at);
CREATE INDEX ocpp_message_payload_idx ON ocpp_message USING gin (payload jsonb_path_ops);

-- connector_outage: periods a connector was out of order. Outages of the
-- same connector can't overlap.
CREATE TABLE connector_outage (
    outage_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    connector_id integer NOT NULL REFERENCES connector,
    during tstzrange NOT NULL,
    error_code text NOT NULL,
    EXCLUDE USING gist (connector_id WITH =, during WITH &&)
);

-- cdr: charge detail record, the priced result of a session, which the
-- operator bills to the driver's roaming partner.
CREATE TABLE cdr (
    cdr_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id bigint NOT NULL UNIQUE REFERENCES charging_session,
    partner_id smallint NOT NULL REFERENCES roaming_partner,
    tariff_id integer NOT NULL REFERENCES tariff,
    energy_kwh numeric(7,3) NOT NULL,
    energy_cost numeric(8,2) NOT NULL,
    idle_cost numeric(8,2) NOT NULL,
    session_fee numeric(6,2) NOT NULL,
    total numeric(8,2) GENERATED ALWAYS AS (energy_cost + idle_cost + session_fee) STORED,
    created_at timestamptz NOT NULL
);

CREATE INDEX cdr_partner_id_idx ON cdr (partner_id, created_at);

--
-- Functions and views
--

-- tariff_at: the tariff element in force for an operator and power type
-- at a moment, using the site's local hour.
CREATE FUNCTION tariff_at(p_operator_id smallint, p_power_type power_type,
                          p_at timestamptz, p_timezone text)
RETURNS tariff
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT t.* FROM tariff t
    WHERE t.operator_id = p_operator_id
      AND t.power_type = p_power_type
      AND t.valid_at @> (p_at AT TIME ZONE p_timezone)::date
      AND t.hours @> extract(hour FROM p_at AT TIME ZONE p_timezone)::int;
END;

-- rate_session: price a finished session with the tariff in force when it
-- started.
CREATE FUNCTION rate_session(p_session_id bigint,
                             OUT tariff_id integer, OUT energy_cost numeric,
                             OUT idle_cost numeric, OUT session_fee numeric)
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT (t).tariff_id,
           round(s.energy_kwh * (t).energy_per_kwh, 2),
           round(greatest(0, extract(epoch FROM (s.ended_at - s.charging_ended_at) - (t).idle_after) / 60)
                 * (t).idle_per_min, 2),
           (t).session_fee
    FROM charging_session s
    JOIN connector c USING (connector_id)
    JOIN charger ch USING (charger_id)
    JOIN site st USING (site_id)
    CROSS JOIN LATERAL (SELECT tariff_at(st.operator_id, ch.power_type, s.started_at, st.timezone) AS t) x
    WHERE s.session_id = p_session_id;
END;

-- connector_uptime: per connector and month, the share of time it was not
-- in an outage. range_agg() merges the outages into a tstzmultirange;
-- intersecting it with the month (*) clips outages that cross a month
-- boundary.
CREATE VIEW connector_uptime AS
SELECT c.connector_id, m.month,
       coalesce(
           (SELECT sum(upper(r) - lower(r))
            FROM unnest((SELECT range_agg(o.during) FROM connector_outage o
                         WHERE o.connector_id = c.connector_id)
                        * tstzmultirange(m.period)) AS r),
           interval '0') AS downtime,
       round(100 * (1 - coalesce(
           (SELECT extract(epoch FROM sum(upper(r) - lower(r)))
            FROM unnest((SELECT range_agg(o.during) FROM connector_outage o
                         WHERE o.connector_id = c.connector_id)
                        * tstzmultirange(m.period)) AS r), 0)
           / extract(epoch FROM upper(m.period) - lower(m.period)))::numeric, 2) AS uptime_pct
FROM connector c
CROSS JOIN LATERAL (
    SELECT d::date AS month,
           tstzrange(d AT TIME ZONE 'UTC', (d + interval '1 month') AT TIME ZONE 'UTC') AS period
    FROM generate_series(timestamp '2025-07-01', timestamp '2026-10-01', interval '1 month') AS d
) m;

-- site_daily: sessions, energy and revenue per site and day.
CREATE VIEW site_daily AS
SELECT st.site_id, (s.started_at AT TIME ZONE st.timezone)::date AS day,
       count(*) AS sessions,
       sum(s.energy_kwh) AS energy_kwh,
       sum(d.total) AS revenue
FROM charging_session s
JOIN connector c USING (connector_id)
JOIN charger ch USING (charger_id)
JOIN site st USING (site_id)
LEFT JOIN cdr d USING (session_id)
GROUP BY st.site_id, 2;
