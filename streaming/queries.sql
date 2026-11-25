--
-- pagila-ng: streaming -- example queries
--
-- Every query here runs against the generated data. Statements that change
-- data run inside transactions that roll back, so the file can be run any
-- number of times:
--   psql -d streaming -f queries.sql
--

\echo '== 1. Temporal foreign key: a subscription needs a price for its whole period'
-- plan_price rows start on 2023-01-01, so a subscription from 2022 has no
-- price to reference for part of its period.
DO $$
BEGIN
    INSERT INTO subscription (account_id, plan_id, region_code, valid_at)
    SELECT account_id, 2, region_code, daterange('2022-06-01', '2023-06-01')
    FROM account ORDER BY account_id LIMIT 1;
    RAISE EXCEPTION 'subscription without a price was accepted!';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 2. WITHOUT OVERLAPS: an account has one plan at a time'
DO $$
BEGIN
    INSERT INTO subscription (account_id, plan_id, region_code, valid_at)
    SELECT account_id, 3, region_code, daterange('2026-10-01', NULL)
    FROM subscription WHERE upper_inf(valid_at) ORDER BY subscription_id LIMIT 1;
    RAISE EXCEPTION 'overlapping subscription was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 3. Price history of each plan in the US'
SELECT p.name, pp.valid_at, pp.monthly_price
FROM plan_price pp JOIN plan p USING (plan_id)
WHERE pp.region_code = 'US'
ORDER BY p.plan_id, lower(pp.valid_at);

\echo '== 4. An account that changed plans, split by the price periods it spans'
-- The subscription_price view joins two temporal tables on overlapping
-- periods (&&) and intersects them (*).
SELECT sp.subscription_id, p.name AS plan, sp.valid_at, sp.monthly_price, sp.currency
FROM subscription_price sp JOIN plan p USING (plan_id)
WHERE sp.account_id = (SELECT account_id FROM subscription
                       GROUP BY account_id HAVING count(*) > 1
                       ORDER BY account_id LIMIT 1)
ORDER BY lower(sp.valid_at);

\echo '== 5. Invoiced revenue per region, last three months, in local currency'
SELECT a.region_code, i.currency,
       sum(i.amount) FILTER (WHERE lower(i.period) >= '2026-08-01' AND lower(i.period) < '2026-09-01') AS aug_2026,
       sum(i.amount) FILTER (WHERE lower(i.period) >= '2026-09-01' AND lower(i.period) < '2026-10-01') AS sep_2026,
       sum(i.amount) FILTER (WHERE lower(i.period) >= '2026-10-01' AND lower(i.period) < '2026-11-01') AS oct_2026
FROM invoice i
JOIN subscription s USING (subscription_id)
JOIN account a USING (account_id)
GROUP BY a.region_code, i.currency
ORDER BY a.region_code;

\echo '== 6. Active subscriptions and cancellations per quarter'
SELECT d::date AS quarter,
       count(*) FILTER (WHERE s.valid_at @> d::date) AS active_on_first_day,
       count(*) FILTER (WHERE upper(s.valid_at) >= d::date
                          AND upper(s.valid_at) < (d + interval '3 months')::date
                          AND NOT EXISTS (SELECT FROM subscription n
                                          WHERE n.account_id = s.account_id
                                            AND lower(n.valid_at) = upper(s.valid_at))) AS cancelled
FROM generate_series(timestamp '2024-04-01', timestamp '2026-10-01', interval '3 months') AS d
CROSS JOIN subscription s
GROUP BY d
ORDER BY d;

\echo '== 7. UUIDv7: account ids carry their creation time'
SELECT account_id, uuid_extract_version(account_id) AS version,
       uuid_extract_timestamp(account_id) AS id_time, created_at
FROM account
ORDER BY account_id
LIMIT 3;

-- Sorting by the id sorts by creation time, so a "newest accounts" query
-- can walk the primary key index backwards.
EXPLAIN (COSTS OFF)
SELECT account_id, email FROM account ORDER BY account_id DESC LIMIT 10;

\echo '== 8. MERGE: record playback and keep watch_progress up to date'
-- record_session() inserts the session, then MERGEs it into
-- watch_progress; merge_action() tells us whether that was an INSERT
-- (a title the profile had not started) or an UPDATE.
BEGIN;
WITH movie AS (
    SELECT title_id, runtime_min * 60 AS runtime_s FROM title
    WHERE kind = 'movie' ORDER BY title_id LIMIT 1
), viewer AS (
    SELECT p.profile_id, d.device_id
    FROM profile p JOIN device d USING (account_id), movie m
    WHERE NOT p.is_kids
      AND NOT EXISTS (SELECT FROM watch_progress w
                      WHERE w.profile_id = p.profile_id AND w.title_id = m.title_id)
    ORDER BY p.profile_id, d.device_id
    LIMIT 1
)
SELECT record_session(v.profile_id, v.device_id, m.title_id, NULL,
                      timestamptz '2026-11-01 20:00+00', timestamptz '2026-11-01 20:40+00',
                      0, 2400, 'HD') AS first_evening,
       record_session(v.profile_id, v.device_id, m.title_id, NULL,
                      timestamptz '2026-11-02 20:00+00', timestamptz '2026-11-02 21:30+00',
                      2400, m.runtime_s, 'HD') AS second_evening
FROM viewer v, movie m;

SELECT w.profile_id, t.name, w.position_s, t.runtime_min * 60 AS runtime_s, w.finished
FROM watch_progress w JOIN title t USING (title_id)
WHERE w.updated_at > '2026-11-01';
ROLLBACK;

\echo '== 9. Continue watching, with the next episode for each series'
-- For an episode watched to the end, LATERAL finds the following one.
SELECT t.name, t.kind,
       coalesce(s.season_no || 'x' || e.episode_no, '-') AS last_watched,
       round(100.0 * w.position_s / playable_runtime_s(w.title_id, w.episode_id)) AS pct,
       nxt.next_episode,
       w.updated_at
FROM watch_progress w
JOIN title t USING (title_id)
LEFT JOIN episode e USING (episode_id)
LEFT JOIN season s ON s.season_id = e.season_id
LEFT JOIN LATERAL (
    SELECT s2.season_no || 'x' || e2.episode_no || ' ' || e2.name AS next_episode
    FROM episode e2 JOIN season s2 ON s2.season_id = e2.season_id
    WHERE s2.title_id = w.title_id
      AND w.position_s >= 0.95 * e.runtime_min * 60
      AND (s2.season_no, e2.episode_no) > (s.season_no, e.episode_no)
    ORDER BY s2.season_no, e2.episode_no
    LIMIT 1
) nxt ON true
WHERE w.profile_id = (SELECT profile_id FROM watch_progress WHERE NOT finished
                      GROUP BY profile_id ORDER BY count(*) DESC, profile_id LIMIT 1)
  AND NOT w.finished
ORDER BY w.updated_at DESC
LIMIT 10;

\echo '== 10. Binge streaks: consecutive days with 3+ episodes of the same series'
-- Gaps and islands: subtracting a row_number() from the day number gives
-- the same value for every day in an unbroken run.
WITH binge_days AS (
    SELECT profile_id, title_id, started_at::date AS day
    FROM viewing_session
    WHERE episode_id IS NOT NULL
    GROUP BY profile_id, title_id, started_at::date
    HAVING count(*) >= 3
), islands AS (
    SELECT *, day - row_number() OVER (PARTITION BY profile_id, title_id ORDER BY day)::int AS grp
    FROM binge_days
)
SELECT i.profile_id, t.name, min(day) AS from_day, max(day) AS to_day, count(*) AS days
FROM islands i JOIN title t USING (title_id)
GROUP BY i.profile_id, t.name, grp
ORDER BY days DESC, from_day
LIMIT 10;

\echo '== 11. Partition pruning: only the October 2026 partition is scanned'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM viewing_session
WHERE started_at >= '2026-10-01 00:00+00' AND started_at < '2026-11-01 00:00+00';

SELECT tableoid::regclass AS partition, count(*)
FROM viewing_session
WHERE started_at >= '2026-07-01 00:00+00'
GROUP BY 1 ORDER BY 1;

\echo '== 12. Most watched titles per region in October 2026 (hours)'
SELECT region_code, rnk, name, hours
FROM (
    SELECT a.region_code, t.name,
           round(sum(extract(epoch FROM v.ended_at - v.started_at)) / 3600) AS hours,
           rank() OVER (PARTITION BY a.region_code
                        ORDER BY sum(extract(epoch FROM v.ended_at - v.started_at)) DESC) AS rnk
    FROM viewing_session v
    JOIN profile p USING (profile_id)
    JOIN account a USING (account_id)
    JOIN title t USING (title_id)
    WHERE v.started_at >= '2026-10-01 00:00+00' AND v.started_at < '2026-11-01 00:00+00'
    GROUP BY a.region_code, t.name
) x
WHERE rnk <= 3
ORDER BY region_code, rnk;

\echo '== 13. Hours watched by genre and kind, with subtotals (ROLLUP)'
SELECT coalesce(g.name, 'all genres') AS genre, coalesce(t.kind::text, 'all') AS kind,
       round(sum(extract(epoch FROM v.ended_at - v.started_at)) / 3600) AS hours
FROM viewing_session v
JOIN title t USING (title_id)
JOIN title_genre tg USING (title_id)
JOIN genre g USING (genre_id)
WHERE v.started_at >= '2026-01-01 00:00+00'
GROUP BY ROLLUP (g.name, t.kind)
ORDER BY g.name NULLS LAST, t.kind NULLS LAST;

\echo '== 14. Catalog search: full text, then fuzzy by title'
SELECT title_id, name, kind, ts_rank(search, q) AS rank
FROM title, websearch_to_tsquery('english', 'detective lighthouse') AS q
WHERE search @@ q
ORDER BY rank DESC, title_id
LIMIT 5;

SELECT title_id, name, round(similarity(name, 'the silnt harbour')::numeric, 2) AS sim
FROM title
WHERE name % 'the silnt harbour'
ORDER BY sim DESC, title_id
LIMIT 5;

\echo '== 15. pgvector: more like this, among titles available in Germany today'
SELECT t2.title_id, t2.name, t2.kind,
       round((e1.embedding <=> e2.embedding)::numeric, 3) AS distance,
       (SELECT string_agg(g.name, ', ' ORDER BY g.genre_id)
        FROM title_genre tg JOIN genre g USING (genre_id)
        WHERE tg.title_id = t2.title_id) AS genres
FROM title_embedding e1
JOIN title_embedding e2 ON e2.title_id <> e1.title_id
JOIN available_titles('DE', date '2026-10-31') t2 ON t2.title_id = e2.title_id
WHERE e1.title_id = 1
ORDER BY e1.embedding <=> e2.embedding
LIMIT 5;

\echo '== 16. Licensing: titles leaving a region in the next 60 days'
SELECT l.region_code, t.name, upper(l.valid_at) AS leaves_on
FROM license_window l JOIN title t USING (title_id)
WHERE upper(l.valid_at) BETWEEN date '2026-11-01' AND date '2026-12-31'
ORDER BY leaves_on, l.region_code
LIMIT 10;

SELECT r.region_code, (SELECT count(*) FROM available_titles(r.region_code, date '2026-10-31')) AS titles
FROM region r ORDER BY titles DESC;

\echo '== 17. JSONB devices: HDR capabilities and platforms'
SELECT info ->> 'os' AS os, count(*) AS devices,
       count(*) FILTER (WHERE info @> '{"screen": {"hdr": ["dolby_vision"]}}') AS dolby_vision,
       count(*) FILTER (WHERE info @> '{"codecs": ["av1"]}') AS av1
FROM device
WHERE kind = 'tv'
GROUP BY 1
ORDER BY devices DESC;

-- UHD sessions on TVs that can't do HDR
SELECT count(*) AS uhd_sessions_without_hdr
FROM viewing_session v JOIN device d USING (device_id)
WHERE v.quality = 'UHD'
  AND jsonb_path_exists(d.info, '$.screen ? (@.resolution == "2160p" && @.hdr.size() == 0)');

\echo '== 18. Best loved titles (at least 50 ratings)'
SELECT t.name, t.kind, count(*) AS ratings,
       round(100.0 * count(*) FILTER (WHERE r.thumbs > 0) / count(*)) AS pct_positive,
       count(*) FILTER (WHERE r.thumbs = 2) AS loved
FROM rating r JOIN title t USING (title_id)
GROUP BY t.title_id
HAVING count(*) >= 50
ORDER BY pct_positive DESC, loved DESC
LIMIT 10;
