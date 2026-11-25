--
-- pg_fil: ev-charging -- example queries
--
-- Every query here runs against the generated data. Statements that change
-- data run inside transactions that roll back, so the file can be run any
-- number of times:
--   psql -d ev-charging -f queries.sql
--

\echo '== 1. Exclusion constraint on an expression: one car per connector'
-- EXCLUDE USING gist (connector_id WITH =, tstzrange(started_at, ended_at) WITH &&)
DO $$
BEGIN
    INSERT INTO charging_session (connector_id, token_uid, started_at, ended_at)
    SELECT connector_id, token_uid, started_at + interval '10 minutes', ended_at + interval '1 hour'
    FROM charging_session WHERE ended_at IS NOT NULL ORDER BY session_id LIMIT 1;
    RAISE EXCEPTION 'overlapping session was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 2. Exclusion constraint over two ranges: one price per day and hour'
-- An evening "super peak" from 18:00 to 22:00 in 2026 overlaps the
-- existing 17-21 peak and 21-24 standard bands, so it is rejected; the same
-- band for dates with no tariff yet would be fine.
DO $$
BEGIN
    INSERT INTO tariff (operator_id, power_type, valid_at, hours, label, energy_per_kwh)
    VALUES (1, 'DC', daterange('2026-12-01', '2027-01-01'), int4range(18, 22), 'super peak', 0.79);
    RAISE EXCEPTION 'overlapping tariff was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 3. The 2026 DC price grid of every operator'
SELECT o.name,
       max(t.energy_per_kwh) FILTER (WHERE t.hours @> 3)  AS "00-07",
       max(t.energy_per_kwh) FILTER (WHERE t.hours @> 12) AS "07-17",
       max(t.energy_per_kwh) FILTER (WHERE t.hours @> 18) AS "17-21",
       max(t.energy_per_kwh) FILTER (WHERE t.hours @> 22) AS "21-24",
       max(t.session_fee) AS session_fee
FROM tariff t JOIN operator o USING (operator_id)
WHERE t.power_type = 'DC' AND t.valid_at @> date '2026-06-01'
GROUP BY o.operator_id, o.name
ORDER BY o.operator_id;

-- tariff_at() resolves the band from the site's local time: 15:30 UTC is
-- 17:30 in Berlin (peak) but 16:30 in Lisbon (standard).
SELECT tz, (tariff_at(1::smallint, 'DC', timestamptz '2026-06-01 15:30+00', tz)).label
FROM unnest(ARRAY['Europe/Lisbon', 'Europe/Berlin']) AS tz;

\echo '== 4. PostGIS: nearest free 150+ kW chargers to Amsterdam Centraal right now'
-- Distance ordering on the GiST-indexed geography, skipping connectors that
-- are in use or broken at the "as of" moment.
SELECT st.name, ch.ocpp_id, ch.max_kw, count(*) AS free_connectors,
       round((ST_Distance(st.location, here) / 1000)::numeric, 1) AS km
FROM site st
JOIN charger ch USING (site_id)
JOIN connector c USING (charger_id),
     (SELECT ST_SetSRID(ST_MakePoint(4.9003, 52.3791), 4326)::geography) AS h(here)
WHERE ch.power_type = 'DC' AND ch.max_kw >= 150
  AND NOT EXISTS (SELECT FROM charging_session s WHERE s.connector_id = c.connector_id
                  AND tstzrange(s.started_at, s.ended_at) @> timestamptz '2026-11-01 00:00+00')
  AND NOT EXISTS (SELECT FROM connector_outage o WHERE o.connector_id = c.connector_id
                  AND o.during @> timestamptz '2026-11-01 00:00+00')
  AND ST_DWithin(st.location, here, 25000)
GROUP BY st.site_id, ch.charger_id, here
ORDER BY km, ch.ocpp_id
LIMIT 5;

\echo '== 5. date_bin(): the load curve of the busiest site on its busiest day, 30-minute buckets'
WITH busiest AS (
    SELECT site_id, day FROM site_daily ORDER BY energy_kwh DESC NULLS LAST LIMIT 1
)
SELECT date_bin('30 minutes', m.measured_at, timestamptz '2025-01-01 00:00+00') AS bucket,
       count(DISTINCT m.session_id) AS sessions,
       round(sum(m.power_w) / 1000.0 / count(DISTINCT m.measured_at)) AS avg_kw
FROM meter_value m
JOIN connector c USING (connector_id)
JOIN charger ch USING (charger_id)
JOIN site st USING (site_id)
JOIN busiest b ON b.site_id = st.site_id
WHERE m.measured_at >= (b.day::timestamp AT TIME ZONE st.timezone)
  AND m.measured_at < ((b.day + 1)::timestamp AT TIME ZONE st.timezone)
GROUP BY 1
ORDER BY 1;

\echo '== 6. Partitions and BRIN: a narrow time range touches one partition and a tiny index'
EXPLAIN (COSTS OFF)
SELECT sum(power_w) FROM meter_value
WHERE measured_at >= '2026-10-15 12:00+00' AND measured_at < '2026-10-15 13:00+00';

SELECT i.relname AS index, pg_size_pretty(pg_relation_size(i.oid)) AS size
FROM pg_class i
WHERE i.relname IN ('meter_value_p20261001_measured_at_idx',
                    'meter_value_p20261001_session_id_measured_at_idx')
ORDER BY 1;

\echo '== 7. Average network load by local hour of day, DC vs AC'
SELECT extract(hour FROM m.measured_at AT TIME ZONE st.timezone) AS local_hour,
       round(avg(m.power_w) FILTER (WHERE ch.power_type = 'DC') / 1000.0, 1) AS dc_avg_kw,
       round(avg(m.power_w) FILTER (WHERE ch.power_type = 'AC') / 1000.0, 1) AS ac_avg_kw,
       count(*) AS samples
FROM meter_value m
JOIN connector c USING (connector_id)
JOIN charger ch USING (charger_id)
JOIN site st USING (site_id)
WHERE m.measured_at >= '2026-10-01 00:00+00'
GROUP BY 1
ORDER BY 1;

\echo '== 8. Multiranges: connector uptime in October 2026, worst first'
SELECT u.connector_id, ch.ocpp_id, ch.vendor, u.downtime, u.uptime_pct
FROM connector_uptime u
JOIN connector c USING (connector_id)
JOIN charger ch USING (charger_id)
WHERE u.month = '2026-10-01'
ORDER BY u.uptime_pct, u.connector_id
LIMIT 5;

SELECT month, round(avg(uptime_pct), 2) AS network_uptime_pct
FROM connector_uptime
GROUP BY month ORDER BY month;

\echo '== 9. range_agg(): how many hours a day each fast charger had a car plugged in'
-- Both connectors of a charger can be busy at once; merging the session
-- ranges into a multirange counts that time only once.
SELECT ch.ocpp_id, ch.max_kw,
       round(extract(epoch FROM sum(upper(r) - lower(r))) / 3600 / 31, 1) AS busy_hours_per_day
FROM charger ch
JOIN LATERAL (
    SELECT range_agg(tstzrange(s.started_at, s.ended_at))
           * tstzmultirange(tstzrange('2026-10-01 00:00+00', '2026-11-01 00:00+00')) AS busy
    FROM charging_session s JOIN connector c USING (connector_id)
    WHERE c.charger_id = ch.charger_id
      AND s.started_at >= '2026-09-30' AND s.started_at < '2026-11-01'
) b ON true
CROSS JOIN LATERAL unnest(b.busy) AS r
WHERE ch.power_type = 'DC'
GROUP BY ch.charger_id
ORDER BY busy_hours_per_day DESC
LIMIT 5;

\echo '== 10. SQL/JSON: OCPP messages'
-- Why sessions stopped, straight from the raw StopTransaction messages
SELECT JSON_VALUE(payload, '$.reason') AS reason, count(*)
FROM ocpp_message
WHERE action = 'StopTransaction'
GROUP BY 1 ORDER BY 2 DESC;

-- Sessions that left with the battery above 95%, with a path filter
SELECT count(*) AS full_battery_stops
FROM ocpp_message
WHERE action = 'StopTransaction'
  AND payload @? '$.transactionData[*].sampledValue[*] ? (@.measurand == "SoC" && @.value.double() > 95)';

-- JSON_TABLE flattens the nested sampled values into rows
SELECT m.message_id, v.*
FROM ocpp_message m,
     JSON_TABLE(m.payload, '$.transactionData[*]'
         COLUMNS (sampled_at timestamptz PATH '$.timestamp',
                  NESTED PATH '$.sampledValue[*]'
                      COLUMNS (measurand text PATH '$.measurand',
                               value numeric PATH '$.value',
                               unit text PATH '$.unit'))) AS v
WHERE m.action = 'StopTransaction'
ORDER BY m.message_id
LIMIT 4;

-- Faults per charger vendor, using the GIN index for the @> filter, with
-- the most common error code (mode(), an ordered-set aggregate)
SELECT ch.vendor, ch.power_type, count(*) AS faults,
       round(count(*)::numeric / count(DISTINCT ch.charger_id), 1) AS faults_per_charger,
       mode() WITHIN GROUP (ORDER BY m.payload ->> 'errorCode') AS most_common
FROM ocpp_message m JOIN charger ch USING (charger_id)
WHERE m.payload @> '{"status": "Faulted"}'
GROUP BY ch.vendor, ch.power_type
ORDER BY faults_per_charger DESC;

\echo '== 11. Revenue per roaming partner and month (last 3 months)'
SELECT rp.name AS partner,
       sum(c.total) FILTER (WHERE c.created_at >= '2026-08-01' AND c.created_at < '2026-09-01') AS aug_2026,
       sum(c.total) FILTER (WHERE c.created_at >= '2026-09-01' AND c.created_at < '2026-10-01') AS sep_2026,
       sum(c.total) FILTER (WHERE c.created_at >= '2026-10-01' AND c.created_at < '2026-11-01') AS oct_2026,
       -- what the partner charges its drivers on top
       round(sum(c.energy_kwh * rp.markup_per_kwh) FILTER (WHERE c.created_at >= '2026-10-01'), 2) AS oct_markup
FROM cdr c JOIN roaming_partner rp USING (partner_id)
GROUP BY rp.partner_id, rp.name
ORDER BY rp.partner_id;

\echo '== 12. Blocking fees: DC sessions left plugged in after charging'
SELECT o.name AS operator, count(*) AS sessions_with_idle_fee, sum(c.idle_cost) AS idle_fees,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_all_idle_fees
FROM cdr c
JOIN tariff t USING (tariff_id)
JOIN operator o USING (operator_id)
WHERE c.idle_cost > 0
GROUP BY o.name
ORDER BY idle_fees DESC;

\echo '== 13. Charging speed by car model on 150+ kW chargers (median and 90th percentile)'
SELECT vm.make || ' ' || vm.model AS car, vm.max_dc_kw,
       count(*) AS sessions,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY s.energy_kwh * 3600
             / extract(epoch FROM s.charging_ended_at - s.started_at))::numeric, 1) AS median_avg_kw,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY s.energy_kwh * 3600
             / extract(epoch FROM s.charging_ended_at - s.started_at))::numeric, 1) AS p90_avg_kw
FROM charging_session s
JOIN connector c USING (connector_id)
JOIN vehicle v USING (vehicle_id)
JOIN vehicle_model vm USING (model_id)
WHERE c.max_kw >= 150 AND s.charging_ended_at IS NOT NULL
GROUP BY vm.model_id
ORDER BY median_avg_kw DESC;

\echo '== 14. Who is charging right now (still plugged in at the end of the data)'
SELECT st.name AS site, c.standard, s.started_at, s.soc_start,
       (SELECT m.soc FROM meter_value m WHERE m.session_id = s.session_id
        ORDER BY m.measured_at DESC LIMIT 1) AS soc_now
FROM charging_session s
JOIN connector c USING (connector_id)
JOIN charger ch USING (charger_id)
JOIN site st USING (site_id)
WHERE s.ended_at IS NULL
ORDER BY s.started_at;

\echo '== 15. Busiest sites in October 2026'
SELECT st.name, st.country_code, sum(d.sessions) AS sessions,
       round(sum(d.energy_kwh)) AS kwh, sum(d.revenue) AS revenue
FROM site_daily d JOIN site st USING (site_id)
WHERE d.day >= '2026-10-01' AND d.day < '2026-11-01'
GROUP BY st.site_id
ORDER BY kwh DESC
LIMIT 5;
