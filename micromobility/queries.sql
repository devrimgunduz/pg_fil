--
-- pg_fil: micromobility -- example queries
--
-- Every query here runs against the generated data. Statements that change
-- data run inside transactions that roll back, so the file can be run any
-- number of times:
--   psql -d micromobility -f queries.sql
--

\echo '== 1. LATERAL + KNN: the five nearest parked e-scooters with 30%+ battery, Amsterdam Dam Square'
-- The latest status of every vehicle comes from a LATERAL subquery on the
-- (vehicle_id, reported_at DESC) index; <-> on geography orders by true
-- distance in metres (on geometry it would compare degrees).
SELECT v.serial, s.battery_pct, s.reported_at,
       round(ST_DistanceSphere(s.location, here)) AS metres
FROM vehicle v
CROSS JOIN (SELECT ST_SetSRID(ST_MakePoint(4.8932, 52.3731), 4326) AS here) h
CROSS JOIN LATERAL (
    SELECT vs.location, vs.battery_pct, vs.reported_at, vs.is_locked
    FROM vehicle_status vs
    WHERE vs.vehicle_id = v.vehicle_id
    ORDER BY vs.reported_at DESC
    LIMIT 1
) s
WHERE v.city_id = 1 AND v.kind = 'scooter' AND s.is_locked AND s.battery_pct >= 30
ORDER BY s.location::geography <-> here::geography
LIMIT 5;

\echo '== 2. ST_Within: parking violations per no-parking zone'
SELECT c.name AS city, p.zone, count(*) AS violations,
       count(DISTINCT p.rider_id) AS riders
FROM parking_violation p
JOIN zone z USING (zone_id)
JOIN city c USING (city_id)
GROUP BY c.name, p.zone
ORDER BY violations DESC
LIMIT 8;

\echo '== 3. ST_Intersects: rides through no-ride zones, and how far inside'
SELECT c.name AS city, z.name AS zone, count(*) AS trips,
       round(avg(ST_Length(ST_Intersection(t.route, z.area)::geography))) AS avg_metres_inside
FROM zone z
JOIN city c USING (city_id)
JOIN trip t ON ST_Intersects(t.route, z.area)
WHERE z.kind = 'no_ride'
GROUP BY c.name, z.zone_id
ORDER BY trips DESC;

\echo '== 4. Slow zones: average speed of rides that crossed one'
SELECT c.name AS city, z.name AS zone, z.speed_limit_kmh,
       count(*) AS trips,
       round(avg(t.distance_m / extract(epoch FROM t.ended_at - t.started_at) * 3.6)::numeric, 1) AS avg_kmh,
       count(*) FILTER (WHERE t.distance_m / extract(epoch FROM t.ended_at - t.started_at) * 3.6 > z.speed_limit_kmh) AS above_limit
FROM zone z
JOIN city c USING (city_id)
JOIN trip t ON ST_Intersects(t.route, z.area)
JOIN vehicle v ON v.vehicle_id = t.vehicle_id AND v.kind = 'scooter'
WHERE z.kind = 'slow'
GROUP BY c.name, z.zone_id
ORDER BY c.name, z.name;

\echo '== 5. ST_HexagonGrid: where weekday morning rides start in Amsterdam (500 m hexagons)'
-- The grid is built in a metric projection (ETRS89 / LAEA Europe, EPSG:3035)
-- so the hexagon size is in metres.
WITH starts AS (
    SELECT ST_Transform(ST_StartPoint(t.route), 3035) AS pt
    FROM trip t JOIN vehicle v USING (vehicle_id)
    WHERE v.city_id = 1
      AND extract(isodow FROM t.started_at AT TIME ZONE 'Europe/Amsterdam') < 6
      AND extract(hour FROM t.started_at AT TIME ZONE 'Europe/Amsterdam') IN (7, 8, 9)
)
SELECT h.i, h.j, count(*) AS rides,
       round(ST_X(ST_Transform(ST_Centroid(h.geom), 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(ST_Centroid(h.geom), 4326))::numeric, 4) AS lat
FROM ST_HexagonGrid(500, (SELECT ST_Transform(area, 3035) FROM zone
                          WHERE city_id = 1 AND kind = 'service_area')) AS h
JOIN starts s ON ST_Intersects(s.pt, h.geom)
GROUP BY h.i, h.j, h.geom
ORDER BY rides DESC
LIMIT 10;

\echo '== 6. Temporal pricing: the same ride before and after the September price change'
SELECT c.name AS city, r.kind, r.valid_at, r.unlock_fee, r.per_minute
FROM pricing_rule r JOIN city c USING (city_id)
WHERE c.name = 'Berlin'
ORDER BY r.kind, lower(r.valid_at);

SELECT price_trip(3::smallint, 'scooter', '2026-08-15 10:00+02', '2026-08-15 10:12+02', false) AS august_12_min,
       price_trip(3::smallint, 'scooter', '2026-09-15 10:00+02', '2026-09-15 10:12+02', false) AS september_12_min,
       price_trip(3::smallint, 'scooter', '2026-09-15 10:00+02', '2026-09-15 10:40+02', true) AS september_40_min_with_pass;

DO $$
BEGIN
    INSERT INTO pricing_rule (city_id, kind, valid_at, unlock_fee, per_minute)
    VALUES (3, 'scooter', daterange('2026-10-01', '2026-11-01'), 0, 0.15);
    RAISE EXCEPTION 'overlapping price was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 7. Exclusion constraint: a rider cannot hold two passes at once'
DO $$
BEGIN
    INSERT INTO pass (rider_id, kind, valid_at, price)
    SELECT rider_id, 'day', tstzrange(lower(valid_at) + interval '3 days', lower(valid_at) + interval '4 days'), 7.99
    FROM pass WHERE kind = 'monthly' ORDER BY pass_id LIMIT 1;
    RAISE EXCEPTION 'overlapping pass was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 8. Partitioned telemetry: pruning and BRIN'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM vehicle_status
WHERE reported_at >= '2026-10-20 06:00+00' AND reported_at < '2026-10-20 09:00+00';

\echo '== 9. Materialized view: the dashboard, refreshed without blocking readers'
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_city_stats;

SELECT c.name AS city, d.kind,
       sum(d.trips) AS trips, round(avg(d.trips)) AS trips_per_day,
       sum(d.km) AS km, sum(d.revenue) AS revenue
FROM daily_city_stats d JOIN city c USING (city_id)
WHERE d.day >= '2026-10-01'
GROUP BY c.name, d.kind
ORDER BY c.name, d.kind;

\echo '== 10. CUBE: trips by city, vehicle kind and weekday/weekend, with every subtotal'
SELECT coalesce(c.name, '(all cities)') AS city,
       coalesce(v.kind::text, '(all kinds)') AS kind,
       coalesce(CASE WHEN extract(isodow FROM t.started_at AT TIME ZONE c.timezone) > 5
                     THEN 'weekend' ELSE 'weekday' END, '(all days)') AS day_type,
       count(*) AS trips, round(avg(t.distance_m)) AS avg_m
FROM trip t
JOIN vehicle v USING (vehicle_id)
JOIN city c ON c.city_id = v.city_id
GROUP BY CUBE (c.name, v.kind, CASE WHEN extract(isodow FROM t.started_at AT TIME ZONE c.timezone) > 5
                                    THEN 'weekend' ELSE 'weekday' END)
HAVING GROUPING(c.name) + GROUPING(v.kind) >= 1
ORDER BY GROUPING(c.name), city, GROUPING(v.kind), kind, day_type;

\echo '== 11. Fleet health right now: battery and open repairs per city'
SELECT c.name AS city, v.kind,
       count(*) AS vehicles,
       count(*) FILTER (WHERE s.battery_pct < 35) AS low_battery,
       count(*) FILTER (WHERE EXISTS (SELECT FROM maintenance_task m
                                      WHERE m.vehicle_id = v.vehicle_id AND m.closed_at IS NULL)) AS in_repair
FROM vehicle v
JOIN city c USING (city_id)
LEFT JOIN LATERAL (
    SELECT vs.battery_pct FROM vehicle_status vs
    WHERE vs.vehicle_id = v.vehicle_id
    ORDER BY vs.reported_at DESC LIMIT 1
) s ON true
GROUP BY c.name, v.kind
ORDER BY c.name, v.kind;

\echo '== 12. Station flows: where classic bikes pile up and where they run out (October)'
SELECT s.name, s.docks,
       count(*) FILTER (WHERE t.end_station_id = s.station_id) AS arrivals,
       count(*) FILTER (WHERE t.start_station_id = s.station_id) AS departures,
       count(*) FILTER (WHERE t.end_station_id = s.station_id)
         - count(*) FILTER (WHERE t.start_station_id = s.station_id) AS net
FROM station s
JOIN trip t ON s.station_id IN (t.start_station_id, t.end_station_id)
WHERE s.city_id = 2 AND t.started_at >= '2026-10-01'
GROUP BY s.station_id
ORDER BY abs(count(*) FILTER (WHERE t.end_station_id = s.station_id)
             - count(*) FILTER (WHERE t.start_station_id = s.station_id)) DESC
LIMIT 6;

\echo '== 13. Rebalancing effort per city and month'
SELECT c.name AS city, date_trunc('month', r.done_at AT TIME ZONE c.timezone)::date AS month,
       count(*) AS jobs,
       round(sum(ST_DistanceSphere(r.picked_up, r.dropped_off)) / 1000) AS km_moved
FROM rebalance_job r
JOIN vehicle v USING (vehicle_id)
JOIN city c USING (city_id)
GROUP BY c.name, 2
ORDER BY c.name, month;

\echo '== 14. Riders by age group: trips and spend (width_bucket)'
SELECT CASE b WHEN 1 THEN '18-24' WHEN 2 THEN '25-34' WHEN 3 THEN '35-44' WHEN 4 THEN '45-54' ELSE '55+' END AS age,
       count(DISTINCT r.rider_id) AS riders, count(*) AS trips,
       round(count(*)::numeric / count(DISTINCT r.rider_id), 1) AS trips_per_rider,
       round(avg(t.fare), 2) AS avg_fare
FROM trip t
JOIN rider r USING (rider_id)
CROSS JOIN LATERAL (SELECT width_bucket(2026 - r.birth_year, ARRAY[0, 25, 35, 45, 55]) AS b) AS w
GROUP BY b
ORDER BY b;

\echo '== 15. Utilisation: average idle time between rides per vehicle kind (lead())'
SELECT v.kind,
       justify_hours(avg(next_start - t.ended_at)) AS avg_idle,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY next_start - t.ended_at) AS median_idle
FROM (
    SELECT t.*, lead(t.started_at) OVER (PARTITION BY t.vehicle_id ORDER BY t.started_at) AS next_start
    FROM trip t
) t
JOIN vehicle v USING (vehicle_id)
WHERE next_start IS NOT NULL
GROUP BY v.kind
ORDER BY v.kind;
