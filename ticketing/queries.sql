--
-- pg_fil: ticketing -- example queries
--
-- Every query here runs against the generated data. Statements that change
-- data run inside transactions that roll back, so the file can be run any
-- number of times:
--   psql -d ticketing -f queries.sql
--
-- The concurrency features (SKIP LOCKED, advisory locks, LISTEN/NOTIFY)
-- need two sessions to show; see the README for a walkthrough.
--

\echo '== 1. Recursive CTE: the seating plan of Riverside Arena, with seats per node'
-- Walk down from each level, then roll seat counts back up the tree.
WITH RECURSIVE tree AS (
    SELECT section_id, parent_id, name, 1 AS depth, ARRAY[section_id] AS path
    FROM section
    WHERE parent_id IS NULL AND venue_id = 3
    UNION ALL
    SELECT c.section_id, c.parent_id, c.name, t.depth + 1, t.path || c.section_id
    FROM section c JOIN tree t ON c.parent_id = t.section_id
)
SELECT repeat('    ', t.depth - 1) || t.name AS section,
       (SELECT count(*) FROM tree d JOIN seat s ON s.section_id = d.section_id
        WHERE t.section_id = ANY (d.path)) AS seats
FROM tree t
WHERE t.depth <= 2 OR t.name IN ('101', '102', '103', '104')
ORDER BY t.path;

\echo '== 2. Holding and buying seats'
-- hold_seats() takes the best available seats in a tier with
-- FOR UPDATE SKIP LOCKED; buy_held_seats() turns the hold into an order and
-- tickets. The ticket insert fires the notify_ticket_sold trigger.
BEGIN;
SELECT e.event_id, e.name, pt.name AS tier, pt.price
FROM event e JOIN price_tier pt USING (event_id)
WHERE e.event_id = (SELECT event_id FROM event_sales
                    WHERE status = 'on_sale' AND available > 100
                    ORDER BY starts_at, event_id LIMIT 1)
  AND pt.name = 'A' \gset

SELECT es.seat_id, sp.path, s.row_label, s.seat_no, es.status, es.hold_expires_at
FROM hold_seats(:event_id, (SELECT tier_id FROM price_tier WHERE event_id = :event_id AND name = 'A'),
                4, 42, 10, timestamptz '2026-11-01 00:05+00') AS es
JOIN seat s USING (seat_id)
JOIN section_path sp ON sp.section_id = s.section_id;

SELECT buy_held_seats(:event_id, 42, timestamptz '2026-11-01 00:08+00') AS order_id \gset

SELECT o.order_id, o.total, t.ticket_id, t.seat_id, t.face_value,
       uuid_extract_timestamp(t.barcode) IS NOT NULL AS barcode_is_uuidv7
FROM orders o JOIN ticket t USING (order_id)
WHERE o.order_id = :order_id;
ROLLBACK;

\echo '== 3. Expired holds go back on sale'
BEGIN;
SELECT count(*) AS expired_holds FROM event_seat
WHERE status = 'held' AND hold_expires_at < timestamptz '2026-11-01 00:00+00';

SELECT e.event_id, release_expired_holds(e.event_id, timestamptz '2026-11-01 00:00+00') AS released
FROM event e
WHERE EXISTS (SELECT FROM event_seat es WHERE es.event_id = e.event_id AND es.status = 'held')
ORDER BY e.event_id;
ROLLBACK;

\echo '== 4. A partial unique index stops a seat being sold twice'
DO $$
BEGIN
    INSERT INTO ticket (order_id, event_id, seat_id, holder_id, face_value, barcode)
    SELECT order_id, event_id, seat_id, holder_id, face_value, uuidv7()
    FROM ticket WHERE status = 'valid' ORDER BY ticket_id LIMIT 1;
    RAISE EXCEPTION 'second ticket for the same seat was accepted!';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 5. Exclusion constraint: a venue cannot host two events at once'
DO $$
BEGIN
    INSERT INTO event (venue_id, kind, name, starts_at, during, on_sale_at)
    SELECT venue_id, 'comedy', 'Double booked', starts_at + interval '1 hour',
           tstzrange(starts_at, starts_at + interval '4 hours'), on_sale_at
    FROM event WHERE status = 'on_sale' ORDER BY event_id LIMIT 1;
    RAISE EXCEPTION 'overlapping event was accepted!';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 6. Constraint trigger: resale is capped at 110% of face value'
DO $$
BEGIN
    INSERT INTO resale_listing (ticket_id, seller_id, price, listed_at)
    SELECT ticket_id, holder_id, face_value * 1.5, timestamptz '2026-11-01 00:00+00'
    FROM ticket t
    WHERE status = 'valid'
      AND NOT EXISTS (SELECT FROM resale_listing r WHERE r.ticket_id = t.ticket_id AND r.status = 'listed')
    ORDER BY ticket_id DESC LIMIT 1;
    RAISE EXCEPTION 'overpriced resale was accepted!';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'rejected as expected: %', SQLERRM;
END
$$;

\echo '== 7. Row-level security: a customer only sees their own tickets'
BEGIN;
SET LOCAL ROLE fil_customer;
SET LOCAL app.customer_id = '42';
SELECT t.ticket_id, e.name, e.starts_at, t.face_value
FROM ticket t JOIN event e USING (event_id)
ORDER BY e.starts_at, t.ticket_id;
SELECT count(*) AS tickets_visible_to_customer_42 FROM ticket;
ROLLBACK;
SELECT count(*) AS tickets_visible_to_owner FROM ticket;

\echo '== 8. Best available: blocks of 4+ adjacent free seats in one row'
-- Gaps and islands: within a row, seat_no minus row_number() is constant
-- across a run of consecutive available seats.
WITH ev AS (
    SELECT event_id FROM event_sales WHERE status = 'on_sale' AND available > 0
    ORDER BY pct_sold DESC, event_id LIMIT 1
), free AS (
    SELECT s.section_id, s.row_label, s.seat_no,
           s.seat_no - row_number() OVER (PARTITION BY s.section_id, s.row_label ORDER BY s.seat_no) AS island
    FROM event_seat es JOIN seat s USING (seat_id) JOIN ev USING (event_id)
    WHERE es.status = 'available'
)
SELECT sp.path, f.row_label, min(f.seat_no) AS from_seat, max(f.seat_no) AS to_seat, count(*) AS seats
FROM free f JOIN section_path sp USING (section_id)
GROUP BY sp.path, f.section_id, f.row_label, f.island
HAVING count(*) >= 4
ORDER BY min(sp.view_rank), seats DESC, sp.path, f.row_label
LIMIT 8;

\echo '== 9. Sales curve: share of tickets sold by weeks before the show'
-- A running total with a window function, per kind of event.
SELECT e.kind,
       ceil(extract(epoch FROM e.starts_at - o.created_at) / 604800) AS weeks_before,
       count(*) AS tickets,
       round(100.0 * sum(count(*)) OVER (PARTITION BY e.kind ORDER BY ceil(extract(epoch FROM e.starts_at - o.created_at) / 604800) DESC)
             / sum(count(*)) OVER (PARTITION BY e.kind), 1) AS cumulative_pct
FROM ticket t
JOIN orders o USING (order_id)
JOIN event e ON e.event_id = t.event_id
WHERE e.status = 'completed'
GROUP BY e.kind, 2
HAVING ceil(extract(epoch FROM e.starts_at - o.created_at) / 604800) <= 8
ORDER BY e.kind, weeks_before DESC;

\echo '== 10. Sell-through and revenue by venue (completed events)'
SELECT v.name AS venue, v.currency, count(*) AS events,
       round(avg(s.pct_sold), 1) AS avg_pct_sold,
       count(*) FILTER (WHERE s.pct_sold = 100) AS sold_out,
       sum(s.revenue) AS revenue
FROM event_sales s
JOIN event e USING (event_id)
JOIN venue v USING (venue_id)
WHERE s.status = 'completed'
GROUP BY v.venue_id
ORDER BY v.venue_id;

\echo '== 11. Gate scans in 15-minute buckets for the biggest football match'
WITH m AS (
    SELECT e.event_id FROM event e JOIN event_sales s USING (event_id)
    WHERE e.name LIKE 'Northfield FC%' AND e.status = 'completed'
    ORDER BY s.sold DESC, e.event_id LIMIT 1
)
SELECT date_bin('15 minutes', sc.scanned_at, timestamptz '2025-01-01 00:00+00') AS bucket,
       count(*) FILTER (WHERE sc.result = 'admitted') AS admitted,
       count(*) FILTER (WHERE sc.result = 'duplicate') AS duplicates
FROM scan sc
JOIN ticket t USING (ticket_id)
JOIN m USING (event_id)
GROUP BY 1
ORDER BY 1;

\echo '== 12. No-shows by kind of event'
SELECT e.kind,
       count(*) AS tickets,
       round(100.0 * count(*) FILTER (WHERE NOT EXISTS (
           SELECT FROM scan s WHERE s.ticket_id = t.ticket_id AND s.result = 'admitted')) / count(*), 1) AS no_show_pct
FROM ticket t JOIN event e USING (event_id)
WHERE e.status = 'completed' AND t.status = 'valid'
GROUP BY e.kind
ORDER BY e.kind;

\echo '== 13. The resale market'
SELECT e.kind, r.status, count(*) AS listings,
       round(avg(100 * r.price / t.face_value), 1) AS avg_pct_of_face
FROM resale_listing r
JOIN ticket t USING (ticket_id)
JOIN event e ON e.event_id = t.event_id
GROUP BY e.kind, r.status
ORDER BY e.kind, r.status;

\echo '== 14. Most loyal customers: events attended, and their favourite venue'
SELECT c.full_name, count(DISTINCT t.event_id) AS events,
       mode() WITHIN GROUP (ORDER BY v.name) AS favourite_venue,
       string_agg(DISTINCT e.kind::text, ', ') AS kinds
FROM ticket t
JOIN customer c ON c.customer_id = t.holder_id
JOIN event e ON e.event_id = t.event_id
JOIN venue v ON v.venue_id = e.venue_id
WHERE e.status = 'completed' AND t.status = 'valid'
GROUP BY c.customer_id
ORDER BY events DESC, c.full_name
LIMIT 10;

\echo '== 15. Refunds for cancelled events'
SELECT e.name, e.starts_at, count(t.ticket_id) AS refunded_tickets, sum(t.face_value) AS refunded
FROM event e
JOIN ticket t USING (event_id)
WHERE e.status = 'cancelled'
GROUP BY e.event_id
ORDER BY e.starts_at;
