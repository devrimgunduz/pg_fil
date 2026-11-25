--
-- pg_fil: stays -- example queries
--
-- Every query here runs against the generated data. Statements that change
-- data run inside transactions that roll back, so the file can be run any
-- number of times:
--   psql -d stays -f queries.sql
--

\echo '== 1. Exclusion constraint: a listing cannot be double booked'
-- Try to book listing 1 over the nights of one of its existing stays. The
-- EXCLUDE USING gist (listing_id WITH =, stay WITH &&) constraint rejects it.
DO $$
DECLARE
    taken daterange;
BEGIN
    SELECT stay INTO taken FROM booking
    WHERE listing_id = 1 AND status = 'confirmed'
    ORDER BY lower(stay) LIMIT 1;

    INSERT INTO booking (listing_id, guest_id, stay, guests, accommodation)
    VALUES (1, 1, daterange(lower(taken) + 1, upper(taken) + 2), 1, 100);

    RAISE EXCEPTION 'double booking was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 2. Cancelled bookings free their nights again'
-- The constraint has WHERE (status <> 'cancelled'), so once a booking is
-- cancelled, someone else can book the same nights.
BEGIN;
WITH b AS (
    SELECT booking_id, listing_id, stay FROM booking
    WHERE status = 'confirmed' ORDER BY booking_id LIMIT 1
), cancel AS (
    UPDATE booking SET status = 'cancelled', cancelled_at = timestamptz '2026-11-01 10:00+00'
    FROM b WHERE booking.booking_id = b.booking_id
    RETURNING b.listing_id, b.stay
)
INSERT INTO booking (listing_id, guest_id, stay, guests, accommodation, booked_at)
SELECT listing_id, 42, stay, 1, quote_stay(listing_id, stay), timestamptz '2026-11-01 10:05+00'
FROM cancel
RETURNING booking_id, listing_id, stay, nights, total;
ROLLBACK;

\echo '== 3. Bookings and availability blocks cannot overlap (triggers)'
DO $$
DECLARE
    blk availability_block;
BEGIN
    SELECT * INTO blk FROM availability_block ORDER BY block_id LIMIT 1;
    INSERT INTO booking (listing_id, guest_id, stay, guests, accommodation)
    VALUES (blk.listing_id, 1, blk.during, 1, 100);
    RAISE EXCEPTION 'booking over a block was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

DO $$
DECLARE
    bk booking;
BEGIN
    SELECT * INTO bk FROM booking WHERE status = 'confirmed' ORDER BY booking_id LIMIT 1;
    INSERT INTO availability_block (listing_id, during, reason)
    VALUES (bk.listing_id, bk.stay, 'owner stay');
    RAISE EXCEPTION 'block over a booking was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 4. WITHOUT OVERLAPS: seasonal rates cannot overlap'
-- listing 1 already has a summer 2026 rate (2026-06-15 to 2026-09-01).
DO $$
BEGIN
    INSERT INTO season_rate (listing_id, valid_at, nightly_rate, label)
    VALUES (1, daterange('2026-08-01', '2026-08-15'), 999, 'festival');
    RAISE EXCEPTION 'overlapping season was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 5. Seasonal pricing: quote a stay across the start of the holidays'
SELECT night::date,
       nightly_rate(1, night::date) AS rate
FROM generate_series(date '2026-12-17', date '2026-12-22', interval '1 day') AS night;

SELECT quote_stay(1, daterange('2026-12-17', '2026-12-23')) AS accommodation;

\echo '== 6. PostGIS: free listings within 5 km of central Lisbon'
-- available_listings() combines a radius search (ST_DWithin on the GiST
-- index) with NOT EXISTS checks against bookings and blocks.
SELECT a.listing_id, a.title, a.max_guests, a.base_nightly_rate,
       round(ST_Distance(a.location, c.location)) AS metres_from_centre,
       quote_stay(a.listing_id, daterange('2027-02-05', '2027-02-10')) AS price
FROM city c,
     available_listings(c.location, 5000, daterange('2027-02-05', '2027-02-10'), 2) AS a
WHERE c.name = 'Lisbon'
ORDER BY a.location <-> c.location
LIMIT 10;

\echo '== 7. JSONB containment: heated pool and an EV charger'
-- @> uses the jsonb_path_ops GIN index on amenities.
SELECT l.listing_id, l.title, c.name AS city, l.amenities -> 'parking' AS parking
FROM listing l JOIN city c USING (city_id)
WHERE l.amenities @> '{"pool": {"heated": true}, "parking": {"ev_charger": true}}'
ORDER BY l.listing_id
LIMIT 10;

\echo '== 8. SQL/JSON path: fast wifi for remote workers'
SELECT count(*) AS listings_with_500mbps_and_desk
FROM listing
WHERE amenities @? '$.wifi ? (@.mbps >= 500)'
  AND JSON_EXISTS(amenities, '$.workspace ? (@ == true)');

\echo '== 9. JSON_TABLE: amenities as rows, and how common each one is'
SELECT a.amenity, count(*) AS listings,
       round(100.0 * count(*) / (SELECT count(*) FROM listing), 1) AS pct
FROM listing l,
     JSON_TABLE(l.amenities, '$.keyvalue()'
         COLUMNS (amenity text PATH '$.key', val jsonb PATH '$.value')) AS a
WHERE a.val <> 'false'
GROUP BY a.amenity
ORDER BY listings DESC;

\echo '== 10. Full-text search over listings, ranked'
SELECT listing_id, title, ts_rank(search, q) AS rank
FROM listing, websearch_to_tsquery('english', 'terrace sunset -noisy') AS q
WHERE search @@ q
ORDER BY rank DESC, listing_id
LIMIT 5;

\echo '== 11. Full-text search over reviews, with highlighted snippets'
SELECT r.review_id, r.rating,
       ts_headline('english', r.body, q, 'StartSel=[, StopSel=]') AS snippet
FROM review r, websearch_to_tsquery('english', 'wifi') AS q
WHERE r.search @@ q
ORDER BY r.created_at DESC
LIMIT 5;

\echo '== 12. pg_trgm: fuzzy title search that survives typos'
SELECT listing_id, title, round(similarity(title, 'cosy apartmnt lisbon')::numeric, 2) AS sim
FROM listing
WHERE title % 'cosy apartmnt lisbon'
ORDER BY sim DESC, listing_id
LIMIT 5;

\echo '== 13. Generated columns: nights and total are computed by the database'
SELECT booking_id, stay, nights, accommodation, cleaning_fee, service_fee, total
FROM booking
ORDER BY booking_id
LIMIT 5;

\echo '== 14. Multiranges: free gaps in a listing calendar'
-- range_agg() merges the booked stays into one datemultirange; subtracting
-- it (and the blocks) from the whole month leaves the free nights.
SELECT datemultirange(daterange('2026-12-01', '2027-01-01'))
       - coalesce((SELECT range_agg(stay) FROM booking
                   WHERE listing_id = 1 AND status <> 'cancelled'), '{}')
       - coalesce((SELECT range_agg(during) FROM availability_block
                   WHERE listing_id = 1), '{}') AS free_in_december;

\echo '== 15. Occupancy by city in summer 2025'
SELECT c.name AS city,
       count(DISTINCT o.listing_id) AS listings,
       round(avg(o.occupancy_pct), 1) AS avg_occupancy_pct
FROM monthly_occupancy o
JOIN listing l USING (listing_id)
JOIN city c USING (city_id)
WHERE o.month IN ('2025-06-01', '2025-07-01', '2025-08-01')
GROUP BY c.name
ORDER BY avg_occupancy_pct DESC;

\echo '== 16. Window functions: top earning hosts per city in 2025'
SELECT city, host_id, host, payouts
FROM (
    SELECT c.name AS city, h.host_id, h.full_name AS host, sum(p.amount) AS payouts,
           rank() OVER (PARTITION BY c.name ORDER BY sum(p.amount) DESC) AS rnk
    FROM payout p
    JOIN booking b USING (booking_id)
    JOIN listing l ON l.listing_id = b.listing_id
    JOIN city c ON c.city_id = l.city_id
    JOIN host h ON h.host_id = p.host_id
    WHERE p.paid_at >= '2025-01-01' AND p.paid_at < '2026-01-01'
    GROUP BY c.name, h.host_id
) t
WHERE rnk = 1
ORDER BY payouts DESC
LIMIT 10;

\echo '== 17. Ratings per listing, best rated with at least 20 reviews'
SELECT l.listing_id, l.title, r.reviews, r.rating, r.cleanliness, r.value_rating
FROM listing_rating r
JOIN listing l USING (listing_id)
WHERE r.reviews >= 20
ORDER BY r.rating DESC, r.reviews DESC
LIMIT 10;
