--
-- pg_fil: micromobility
--
-- Shared bikes, e-bikes and e-scooters in three cities: riders unlock a
-- vehicle, ride, and park it; vehicles report their position and battery;
-- operations staff swap batteries, repair vehicles and move them overnight
-- to where they will be needed. Cities draw zones on the map where riding
-- or parking is not allowed, or speed is limited.
--
-- PostgreSQL features shown here:
--   * PostGIS: points, routes (LineString) and zone polygons; ST_Within for
--     parking violations, ST_Intersects for rides through no-ride zones,
--     KNN (<->) for "nearest scooter", ST_Length for distances,
--     ST_HexagonGrid for demand heatmaps
--   * partitioned telemetry (vehicle_status) with BRIN indexes
--   * a temporal primary key (WITHOUT OVERLAPS) for prices, and an
--     exclusion constraint so a rider's passes never overlap
--   * LATERAL joins for "latest status of every vehicle"
--   * a materialized view refreshed CONCURRENTLY for dashboards
--   * GROUPING SETS / CUBE reports
--
-- Requires PostgreSQL 18+ and PostGIS. Load with:
--   createdb micromobility
--   psql -d micromobility -f schema.sql
--   psql -d micromobility -f generate-data.sql
--

SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TYPE vehicle_kind AS ENUM ('bike', 'ebike', 'scooter');
CREATE TYPE zone_kind AS ENUM ('service_area', 'no_parking', 'no_ride', 'slow', 'parking_hub');
CREATE TYPE pass_kind AS ENUM ('day', 'monthly');
CREATE TYPE task_kind AS ENUM ('battery_swap', 'repair', 'inspection');

-- Geometries are stored as geometry(..., 4326), longitude/latitude.
-- Distances in metres come from casting to geography, e.g.
-- ST_Length(route::geography).

CREATE TABLE city (
    city_id smallint PRIMARY KEY,
    name text NOT NULL UNIQUE,
    country_code char(2) NOT NULL,
    timezone text NOT NULL,
    currency char(3) NOT NULL,
    centre geometry(Point, 4326) NOT NULL
);

CREATE TABLE zone (
    zone_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id smallint NOT NULL REFERENCES city,
    kind zone_kind NOT NULL,
    name text NOT NULL,
    area geometry(Polygon, 4326) NOT NULL,
    speed_limit_kmh smallint CHECK ((kind = 'slow') = (speed_limit_kmh IS NOT NULL))
);

CREATE INDEX zone_area_idx ON zone USING gist (area);

CREATE TABLE station (
    station_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id smallint NOT NULL REFERENCES city,
    name text NOT NULL,
    location geometry(Point, 4326) NOT NULL,
    docks smallint NOT NULL
);

CREATE INDEX station_location_idx ON station USING gist (location);

CREATE TABLE vehicle (
    vehicle_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id smallint NOT NULL REFERENCES city,
    kind vehicle_kind NOT NULL,
    serial text NOT NULL UNIQUE,
    model text NOT NULL,
    commissioned_on date NOT NULL
);

-- pricing_rule: what a ride costs in a city on a kind of vehicle, over
-- time. The temporal primary key means there is at most one price for any
-- day; it doesn't rule out days with no price.
CREATE TABLE pricing_rule (
    city_id smallint NOT NULL REFERENCES city,
    kind vehicle_kind NOT NULL,
    valid_at daterange NOT NULL,
    unlock_fee numeric(5,2) NOT NULL,
    per_minute numeric(5,2) NOT NULL,
    PRIMARY KEY (city_id, kind, valid_at WITHOUT OVERLAPS)
);

CREATE TABLE rider (
    rider_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id smallint NOT NULL REFERENCES city,
    full_name text NOT NULL,
    email text NOT NULL UNIQUE,
    birth_year smallint NOT NULL,
    joined_at timestamptz NOT NULL
);

-- pass: a day or monthly pass. With a pass, unlocking is free and so are
-- the first 30 minutes of every ride. A rider can't hold two passes at the
-- same time.
CREATE TABLE pass (
    pass_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rider_id integer NOT NULL REFERENCES rider,
    kind pass_kind NOT NULL,
    valid_at tstzrange NOT NULL,
    price numeric(6,2) NOT NULL,
    EXCLUDE USING gist (rider_id WITH =, valid_at WITH &&)
);

CREATE TABLE trip (
    trip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rider_id integer NOT NULL REFERENCES rider,
    vehicle_id integer NOT NULL REFERENCES vehicle,
    pass_id integer REFERENCES pass,
    started_at timestamptz NOT NULL,
    ended_at timestamptz NOT NULL,
    start_station_id integer REFERENCES station,
    end_station_id integer REFERENCES station,
    route geometry(LineString, 4326) NOT NULL,
    distance_m integer GENERATED ALWAYS AS (round(ST_Length(route::geography))::integer) STORED,
    fare numeric(7,2) NOT NULL,
    CHECK (ended_at > started_at)
);

CREATE INDEX trip_vehicle_idx ON trip (vehicle_id, started_at);
CREATE INDEX trip_rider_idx ON trip (rider_id, started_at);
CREATE INDEX trip_started_at_idx ON trip (started_at);
-- Indexes on expressions: the start and end points of the route.
CREATE INDEX trip_start_point_idx ON trip USING gist (ST_StartPoint(route));
CREATE INDEX trip_end_point_idx ON trip USING gist (ST_EndPoint(route));

-- vehicle_status: telemetry. Vehicles report when a trip ends and every few
-- hours while parked. Partitioned by month, with BRIN on the time column
-- and GiST on the position.
CREATE TABLE vehicle_status (
    vehicle_id integer NOT NULL,
    reported_at timestamptz NOT NULL,
    location geometry(Point, 4326) NOT NULL,
    battery_pct smallint CHECK (battery_pct BETWEEN 0 AND 100),
    is_locked boolean NOT NULL DEFAULT true
) PARTITION BY RANGE (reported_at);

CREATE INDEX vehicle_status_reported_at_brin ON vehicle_status USING brin (reported_at);
CREATE INDEX vehicle_status_vehicle_idx ON vehicle_status (vehicle_id, reported_at DESC);

-- Monthly partitions from 2026-06 (local midnight on 2026-07-01 is still
-- June in UTC) to 2027-12, a year past the generated data, named the way
-- pg_partman names them; pg_partman-setup.sql can take over from 2028-01.
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2026-06-01', date '2027-12-01', interval '1 month')::date
    LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF vehicle_status FOR VALUES FROM (%L) TO (%L)',
            'vehicle_status_p' || to_char(m, 'YYYYMMDD'),
            m::timestamp AT TIME ZONE 'UTC',
            (m + interval '1 month')::timestamp AT TIME ZONE 'UTC');
    END LOOP;
END
$$;

-- Rows past the last monthly partition land here instead of failing.
-- Keep it empty: attaching a new month fails if the default partition
-- already holds rows for that month.
CREATE TABLE vehicle_status_default PARTITION OF vehicle_status DEFAULT;

CREATE TABLE maintenance_task (
    task_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id integer NOT NULL REFERENCES vehicle,
    kind task_kind NOT NULL,
    opened_at timestamptz NOT NULL,
    closed_at timestamptz,
    notes text,
    CHECK (closed_at >= opened_at)
);

CREATE INDEX maintenance_task_vehicle_idx ON maintenance_task (vehicle_id, opened_at);

-- rebalance_job: overnight moves of vehicles from where the last rider left
-- them to where the next riders will want them.
CREATE TABLE rebalance_job (
    job_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id integer NOT NULL REFERENCES vehicle,
    picked_up geometry(Point, 4326) NOT NULL,
    dropped_off geometry(Point, 4326) NOT NULL,
    done_at timestamptz NOT NULL
);

CREATE INDEX rebalance_job_vehicle_idx ON rebalance_job (vehicle_id, done_at);

--
-- Functions and views
--

-- price_trip: the fare for a ride, from the rule in force on the day it
-- started. A pass waives the unlock fee and the first 30 minutes.
CREATE FUNCTION price_trip(p_city_id smallint, p_kind vehicle_kind,
                           p_started_at timestamptz, p_ended_at timestamptz,
                           p_has_pass boolean)
RETURNS numeric
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT CASE WHEN p_has_pass THEN 0 ELSE r.unlock_fee END
           + r.per_minute * greatest(0, ceil(extract(epoch FROM p_ended_at - p_started_at) / 60)
                                        - CASE WHEN p_has_pass THEN 30 ELSE 0 END)
    FROM pricing_rule r
    JOIN city c USING (city_id)
    WHERE r.city_id = p_city_id AND r.kind = p_kind
      AND r.valid_at @> (p_started_at AT TIME ZONE c.timezone)::date;
END;

-- parking_violation: trips that ended inside a no-parking zone.
CREATE VIEW parking_violation AS
SELECT t.trip_id, t.rider_id, t.vehicle_id, t.ended_at, z.zone_id, z.name AS zone
FROM trip t
JOIN zone z ON z.kind = 'no_parking' AND ST_Within(ST_EndPoint(t.route), z.area);

-- daily_city_stats: the dashboard's numbers. A materialized view, since
-- the dashboard reads them far more often than they change; the unique
-- index lets REFRESH MATERIALIZED VIEW CONCURRENTLY update it without
-- blocking readers.
CREATE MATERIALIZED VIEW daily_city_stats AS
SELECT v.city_id, (t.started_at AT TIME ZONE c.timezone)::date AS day, v.kind,
       count(*) AS trips,
       count(DISTINCT t.rider_id) AS riders,
       round(sum(t.distance_m) / 1000.0, 1) AS km,
       round(avg(extract(epoch FROM t.ended_at - t.started_at) / 60), 1) AS avg_minutes,
       sum(t.fare) AS revenue
FROM trip t
JOIN vehicle v USING (vehicle_id)
JOIN city c ON c.city_id = v.city_id
GROUP BY v.city_id, 2, v.kind
WITH NO DATA;

CREATE UNIQUE INDEX daily_city_stats_key ON daily_city_stats (city_id, day, kind);
