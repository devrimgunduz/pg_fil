# ev-charging

> The schema, data generator and queries of this database were vibe coded:
> written with an AI coding assistant, then checked by running them.

A European electric vehicle charging network. Four operators run 100 sites
in 20 cities: fast DC hubs along ring roads and motorways, and AC chargers
in garages and car parks. Drivers from five roaming partners (e-mobility
providers) charge with RFID tokens. Chargers report meter values and send
OCPP messages, and every session becomes a priced charge detail record
(CDR). The data runs from July 2025 to October 2026 and is "as of"
2026-11-01 00:00 UTC, when a few cars are still plugged in. All amounts are
in EUR.

This database is about **time series**: a large append-only table,
partitioned and BRIN-indexed, plus ranges and multiranges for tariffs and
uptime.

## Tables

| Table | What it holds |
|---|---|
| `operator`, `roaming_partner` | who runs the chargers, and whose customers use them |
| `site` | a charging location with a PostGIS point, time zone and facilities |
| `charger`, `connector` | AC (Type2) and DC (CCS2, CHAdeMO) hardware |
| `tariff` | time-of-use prices by date period **and** hour band |
| `driver`, `vehicle`, `vehicle_model`, `rfid_token` | who charges, with what |
| `charging_session` | plug-in to unplug, energy, state of charge |
| `meter_value` | energy, power, SoC, voltage and current samples, about 650,000 rows, partitioned by month, BRIN index |
| `ocpp_message` | raw OCPP 1.6 JSON: StartTransaction, StopTransaction, StatusNotification |
| `connector_outage` | when connectors were out of order |
| `cdr` | priced sessions, billed to the roaming partner |

Functions and views: `tariff_at(operator, power_type, timestamptz, timezone)`,
`rate_session(session_id)`, `connector_uptime`, `site_daily`.

## Install

Requires PostgreSQL 18+ and PostGIS (`postgresql-19-postgis-3` on apt,
`postgis37_19` on dnf). pg_partman is optional.

```
createdb ev-charging
psql -d ev-charging -f schema.sql
psql -d ev-charging -f generate-data.sql             # about 35 seconds
psql -d ev-charging -v scale=3 -f generate-data.sql  # or: 3x the network
psql -d ev-charging -f pg_partman-setup.sql          # optional
psql -d ev-charging -f queries.sql                   # all the examples below
```

The generator is deterministic, so the same scale always gives the same rows.

## Time series: partitions and BRIN

`meter_value` is partitioned by month (`meter_value_p20250701` and so on).
Rows arrive in time order, so a **BRIN** index on `measured_at`, which stores
only the min and max of each block range, is enough to find a time window.
It is about 70 times smaller than the B-tree on `(session_id, measured_at)`:

```
ev-charging=# EXPLAIN (COSTS OFF) SELECT sum(power_w) FROM meter_value
              WHERE measured_at >= '2026-10-15 12:00+00' AND measured_at < '2026-10-15 13:00+00';
 Aggregate
   ->  Bitmap Heap Scan on meter_value_p20261001 meter_value
         ->  Bitmap Index Scan on meter_value_p20261001_measured_at_idx

                      index                       |  size
--------------------------------------------------+---------
 meter_value_p20261001_measured_at_idx            | 24 kB
 meter_value_p20261001_session_id_measured_at_idx | 1784 kB
```

`schema.sql` creates monthly partitions through 2027-12, a year past the
generated data, plus a default partition (`meter_value_default`) for
anything later. `pg_partman-setup.sql` hands partitions from 2028-01
onward to pg_partman.

`date_bin()` buckets timestamps into intervals of any size, here a site's
load curve in 30-minute buckets:

```sql
SELECT date_bin('30 minutes', measured_at, timestamptz '2025-01-01 00:00+00') AS bucket,
       round(sum(power_w) / 1000.0 / count(DISTINCT measured_at)) AS avg_kw
FROM meter_value JOIN connector USING (connector_id) JOIN charger USING (charger_id)
WHERE site_id = 91 AND measured_at >= '2026-06-12' AND measured_at < '2026-06-13'
GROUP BY 1 ORDER BY 1;
```

## Exclusion constraints

A connector serves one car at a time. The constraint is on an
**expression**, the range from plug-in to unplug, and an open-ended range
(`ended_at IS NULL`) blocks the connector until the session ends:

```sql
EXCLUDE USING gist (connector_id WITH =, tstzrange(started_at, ended_at) WITH &&)
```

Tariffs vary by date **and** by hour of day. The constraint compares two
ranges at once, so two rows may share dates or hours but never both:

```sql
EXCLUDE USING gist (operator_id WITH =, power_type WITH =, valid_at WITH &&, hours WITH &&)
```

```sql
-- 15:30 UTC is 17:30 in Berlin (peak) but 16:30 in Lisbon (standard)
SELECT (tariff_at(1::smallint, 'DC', timestamptz '2026-06-01 15:30+00', 'Europe/Berlin')).label;
```

## Multiranges

`range_agg()` merges overlapping ranges into a multirange, and `*`
intersects. The `connector_uptime` view clips outages to each month, and
`queries.sql` counts the hours a charger had at least one car plugged in.
Both connectors busy at once count only once:

```sql
SELECT range_agg(tstzrange(started_at, ended_at))
       * tstzmultirange(tstzrange('2026-10-01', '2026-11-01'))
FROM charging_session JOIN connector USING (connector_id)
WHERE charger_id = 1;
```

## SQL/JSON over OCPP messages

Chargers talk OCPP. Its messages are stored as they arrived, in a JSONB
column with a GIN index:

```json
{"transactionId": 42, "idTag": "3F0A9C11B2D4E7", "meterStop": 53008, "reason": "EVDisconnected",
 "transactionData": [{"timestamp": "2025-06-30T22:37:00Z", "sampledValue": [
     {"measurand": "Energy.Active.Import.Register", "value": "53008", "unit": "Wh"},
     {"measurand": "SoC", "value": "77", "unit": "Percent", "location": "EV"}]}]}
```

```sql
-- scalar extraction
SELECT JSON_VALUE(payload, '$.reason'), count(*) FROM ocpp_message
WHERE action = 'StopTransaction' GROUP BY 1;

-- a path filter with a type conversion
SELECT count(*) FROM ocpp_message
WHERE payload @? '$.transactionData[*].sampledValue[*] ? (@.measurand == "SoC" && @.value.double() > 95)';

-- JSON_TABLE with a NESTED PATH: one row per sampled value
SELECT m.message_id, v.*
FROM ocpp_message m,
     JSON_TABLE(m.payload, '$.transactionData[*]'
         COLUMNS (sampled_at timestamptz PATH '$.timestamp',
                  NESTED PATH '$.sampledValue[*]'
                      COLUMNS (measurand text PATH '$.measurand', value numeric PATH '$.value')))
     AS v
WHERE m.action = 'StopTransaction' LIMIT 4;
```

## PostGIS

The nearest free fast chargers to Amsterdam Centraal, leaving out
connectors that are in use or broken at the end of the data:

```sql
SELECT st.name, ch.ocpp_id, ch.max_kw, round((ST_Distance(st.location, here) / 1000)::numeric, 1) AS km
FROM site st JOIN charger ch USING (site_id) JOIN connector c USING (charger_id),
     (SELECT ST_SetSRID(ST_MakePoint(4.9003, 52.3791), 4326)::geography) AS h(here)
WHERE ch.max_kw >= 150 AND ST_DWithin(st.location, here, 25000)
  AND NOT EXISTS (SELECT FROM charging_session s WHERE s.connector_id = c.connector_id
                  AND tstzrange(s.started_at, s.ended_at) @> timestamptz '2026-11-01 00:00+00')
GROUP BY st.site_id, ch.charger_id, here
ORDER BY km LIMIT 5;
```

## Analytics

`queries.sql` also has:
- revenue per roaming partner with `FILTER`
- blocking fees per operator with a window share (`sum(...) OVER ()`)
- median and 90th percentile charging speed per car model with `percentile_cont`
- the most common fault code per vendor with `mode()`
