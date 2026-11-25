# micromobility

Shared bikes, e-bikes and e-scooters in Amsterdam, Barcelona and Berlin.
Riders unlock a vehicle, ride and park it. Vehicles report their position
and battery; operations staff swap batteries, fix vehicles and move them
overnight to where they'll be needed. Each city draws zones on the map:
the service area, no-parking and no-ride zones, slow zones and parking
hubs. The data covers July to October 2026 and is "as of" 2026-11-01.

This database is about **geography**: almost every question is "where?"
as much as "how many?".

## Tables

| Table | What it holds |
|---|---|
| `city` | 3 cities with a centre point and time zone |
| `zone` | polygons: service area, no-parking, no-ride, slow (with speed limit), parking hubs |
| `station` | docking stations for classic bikes |
| `vehicle` | 900 bikes, e-bikes and e-scooters |
| `pricing_rule` | unlock fee and price per minute per city and vehicle kind, temporal key |
| `rider`, `pass` | riders and their day or monthly passes, which can't overlap |
| `trip` | about 200,000 rides with a `LineString` route and a generated `distance_m` |
| `vehicle_status` | telemetry: position, battery, locked; about 490,000 rows, partitioned by month |
| `maintenance_task` | battery swaps, inspections and repairs |
| `rebalance_job` | overnight vehicle moves |

Functions and views: `price_trip(...)`, `parking_violation`, and the
materialized view `daily_city_stats`.

## Install

Requires PostgreSQL 18+ and PostGIS (`postgresql-19-postgis-3` on apt,
`postgis37_19` on dnf). pg_partman is optional.

```
createdb micromobility
psql -d micromobility -f schema.sql
psql -d micromobility -f generate-data.sql             # about 20 seconds
psql -d micromobility -v scale=3 -f generate-data.sql  # or: 3x the fleet
psql -d micromobility -f pg_partman-setup.sql          # optional
psql -d micromobility -f queries.sql                   # all the examples below
```

The generator is deterministic, so the same scale always gives the same rows.

## PostGIS

Geometries are `geometry(..., 4326)` (longitude/latitude). Distances in
metres come from casting to `geography`.

The trip length is a stored generated column:

```sql
distance_m integer GENERATED ALWAYS AS (round(ST_Length(route::geography))::integer) STORED
```

**Nearest scooter.** A `LATERAL` subquery finds each vehicle's latest status,
and `<->` on geography orders by true distance:

```sql
SELECT v.serial, s.battery_pct, round(ST_DistanceSphere(s.location, here)) AS metres
FROM vehicle v
CROSS JOIN (SELECT ST_SetSRID(ST_MakePoint(4.8932, 52.3731), 4326) AS here) h
CROSS JOIN LATERAL (SELECT location, battery_pct, is_locked FROM vehicle_status vs
                    WHERE vs.vehicle_id = v.vehicle_id
                    ORDER BY reported_at DESC LIMIT 1) s
WHERE v.kind = 'scooter' AND s.is_locked AND s.battery_pct >= 30
ORDER BY s.location::geography <-> here::geography
LIMIT 5;
```

**Parking violations.** The trips that ended inside a no-parking zone. The
`parking_violation` view uses an index on the expression `ST_EndPoint(route)`:

```sql
SELECT t.trip_id, z.name
FROM trip t JOIN zone z ON z.kind = 'no_parking' AND ST_Within(ST_EndPoint(t.route), z.area);
```

**Riding through no-ride zones**, and how far:

```sql
SELECT z.name, count(*), avg(ST_Length(ST_Intersection(t.route, z.area)::geography))
FROM zone z JOIN trip t ON ST_Intersects(t.route, z.area)
WHERE z.kind = 'no_ride' GROUP BY z.zone_id;
```

**Demand heatmap.** `ST_HexagonGrid()` builds 500 m hexagons in a metric
projection (EPSG:3035), then trip starts are counted per hexagon:

```sql
SELECT h.i, h.j, count(*)
FROM ST_HexagonGrid(500, (SELECT ST_Transform(area, 3035) FROM zone
                          WHERE city_id = 1 AND kind = 'service_area')) h
JOIN trip t ON ST_Intersects(ST_Transform(ST_StartPoint(t.route), 3035), h.geom)
GROUP BY h.i, h.j ORDER BY 3 DESC LIMIT 10;
```

## Temporal pricing and passes

```sql
PRIMARY KEY (city_id, kind, valid_at WITHOUT OVERLAPS)   -- pricing_rule
EXCLUDE USING gist (rider_id WITH =, valid_at WITH &&)   -- pass
```

`price_trip()` looks up the rule in force on the (local) day a ride
started. Prices for e-bikes and scooters went up on 2026-09-01:

```sql
SELECT price_trip(3::smallint, 'scooter', '2026-08-15 10:00+02', '2026-08-15 10:12+02', false),  -- 4.48
       price_trip(3::smallint, 'scooter', '2026-09-15 10:00+02', '2026-09-15 10:12+02', false);  -- 4.84
```

## Partitioned telemetry

`vehicle_status` is partitioned by month, with a BRIN index on
`reported_at`. `schema.sql` creates monthly partitions through 2027-12, a
year past the generated data, plus a default partition
(`vehicle_status_default`) for anything later. `pg_partman-setup.sql`
hands partitions from 2028-01 onward to pg_partman.

## Materialized view

`daily_city_stats` holds the dashboard's daily numbers per city and vehicle
kind. It has a unique index, so it can be refreshed without blocking anyone
reading it:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_city_stats;
```

## Reports

`queries.sql` also has:
- `GROUP BY CUBE` over city, vehicle kind and weekday/weekend, using
  `GROUPING()` to label the subtotals
- net flows per docking station
- rebalancing effort per city and month
- riders by age group with `width_bucket()`
- idle time between rides with `lead()`
