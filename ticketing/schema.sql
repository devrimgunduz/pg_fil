--
-- pg_fil: ticketing
--
-- Event ticketing for concerts, sports, theatre and comedy: venues with a
-- nested seating plan, events with price tiers, a per-event seat inventory
-- that buyers hold and then buy, tickets that can be transferred or resold,
-- and gate scans on the night.
--
-- PostgreSQL features shown here:
--   * concurrency: holding seats with SELECT ... FOR UPDATE SKIP LOCKED, so
--     many buyers can grab seats at once without blocking each other, and
--     advisory locks to run one hold sweeper per event
--   * a partial unique index as the last line of defence against selling
--     a seat twice, and an exclusion constraint so a venue can't host two
--     events at once
--   * recursive CTEs over the venue hierarchy (level > stand > section)
--   * row-level security: a customer sees only the tickets they hold
--   * LISTEN/NOTIFY: a trigger announces every sale
--   * a constraint trigger capping resale prices
--
-- Requires PostgreSQL 18+. Load with:
--   createdb ticketing
--   psql -d ticketing -f schema.sql
--   psql -d ticketing -f generate-data.sql
--

SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TYPE event_kind AS ENUM ('concert', 'sports', 'theatre', 'comedy');
CREATE TYPE event_status AS ENUM ('scheduled', 'on_sale', 'sold_out', 'completed', 'cancelled');
CREATE TYPE seat_status AS ENUM ('available', 'held', 'sold');
CREATE TYPE order_status AS ENUM ('paid', 'refunded');
CREATE TYPE ticket_status AS ENUM ('valid', 'refunded');
CREATE TYPE scan_result AS ENUM ('admitted', 'duplicate', 'invalid');
CREATE TYPE resale_status AS ENUM ('listed', 'sold', 'withdrawn');

CREATE TABLE venue (
    venue_id smallint PRIMARY KEY,
    name text NOT NULL UNIQUE,
    city text NOT NULL,
    country_code char(2) NOT NULL,
    timezone text NOT NULL,
    currency char(3) NOT NULL
);

-- section: a venue's seating plan as a tree. Top-level rows are levels
-- (Stalls, Upper Tier), their children stands or areas, and the leaves are
-- the sections that seats belong to. parent_id IS NULL marks a level.
CREATE TABLE section (
    section_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id smallint NOT NULL REFERENCES venue,
    parent_id integer REFERENCES section,
    name text NOT NULL,
    -- 1 = best view in the house; drives price tiers
    view_rank smallint,
    UNIQUE NULLS NOT DISTINCT (venue_id, parent_id, name)
);

CREATE INDEX section_parent_id_idx ON section (parent_id);

CREATE TABLE seat (
    seat_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    section_id integer NOT NULL REFERENCES section,
    row_label text NOT NULL,
    seat_no smallint NOT NULL,
    is_accessible boolean NOT NULL DEFAULT false,
    UNIQUE (section_id, row_label, seat_no)
);

CREATE TABLE artist (
    artist_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE,
    kind event_kind NOT NULL,
    genre text
);

-- event.during runs from doors opening to the venue closing; the exclusion
-- constraint keeps a venue from hosting two (non-cancelled) events at once.
CREATE TABLE event (
    event_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id smallint NOT NULL REFERENCES venue,
    artist_id integer REFERENCES artist,
    kind event_kind NOT NULL,
    name text NOT NULL,
    starts_at timestamptz NOT NULL,
    during tstzrange NOT NULL,
    on_sale_at timestamptz NOT NULL,
    status event_status NOT NULL DEFAULT 'scheduled',
    CHECK (during @> starts_at),
    CHECK (on_sale_at < starts_at),
    EXCLUDE USING gist (venue_id WITH =, during WITH &&) WHERE (status <> 'cancelled')
);

CREATE INDEX event_starts_at_idx ON event (starts_at);

CREATE TABLE price_tier (
    tier_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id integer NOT NULL REFERENCES event,
    name text NOT NULL,
    price numeric(8,2) NOT NULL CHECK (price >= 0),
    UNIQUE (event_id, name)
);

CREATE TABLE customer (
    customer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    email text NOT NULL UNIQUE,
    country_code char(2) NOT NULL,
    created_at timestamptz NOT NULL
);

-- event_seat: the inventory, one row per seat per event. Buyers hold seats
-- for a few minutes while they pay (status 'held', hold_expires_at), then
-- the seat is 'sold'. Holding seats locks these rows with
-- FOR UPDATE SKIP LOCKED; see hold_seats() below.
CREATE TABLE event_seat (
    event_id integer NOT NULL REFERENCES event,
    seat_id integer NOT NULL REFERENCES seat,
    tier_id integer NOT NULL REFERENCES price_tier,
    status seat_status NOT NULL DEFAULT 'available',
    held_by integer REFERENCES customer,
    hold_expires_at timestamptz,
    PRIMARY KEY (event_id, seat_id),
    CHECK ((status = 'held') = (held_by IS NOT NULL AND hold_expires_at IS NOT NULL))
);

CREATE INDEX event_seat_available_idx ON event_seat (event_id, tier_id) WHERE status = 'available';
CREATE INDEX event_seat_held_idx ON event_seat (event_id, hold_expires_at) WHERE status = 'held';

CREATE TABLE orders (
    order_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES customer,
    event_id integer NOT NULL REFERENCES event,
    created_at timestamptz NOT NULL,
    status order_status NOT NULL DEFAULT 'paid',
    total numeric(10,2) NOT NULL
);

CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX orders_event_id_idx ON orders (event_id);

-- ticket.holder_id is whoever holds the ticket now: the buyer, or the
-- person it was last transferred or resold to.
--
-- ticket_one_per_seat is the last line of defence against selling a seat
-- twice: whatever the application does, two valid tickets for the same
-- seat at the same event can't exist. Refunded tickets don't count, so a
-- refunded seat can be sold again.
CREATE TABLE ticket (
    ticket_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id integer NOT NULL REFERENCES orders,
    event_id integer NOT NULL REFERENCES event,
    seat_id integer NOT NULL REFERENCES seat,
    holder_id integer NOT NULL REFERENCES customer,
    face_value numeric(8,2) NOT NULL,
    barcode uuid NOT NULL UNIQUE,
    status ticket_status NOT NULL DEFAULT 'valid'
);

CREATE UNIQUE INDEX ticket_one_per_seat ON ticket (event_id, seat_id) WHERE status = 'valid';
CREATE INDEX ticket_order_id_idx ON ticket (order_id);
CREATE INDEX ticket_holder_id_idx ON ticket (holder_id);

CREATE TABLE transfer (
    transfer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id integer NOT NULL REFERENCES ticket,
    from_customer integer NOT NULL REFERENCES customer,
    to_customer integer NOT NULL REFERENCES customer,
    transferred_at timestamptz NOT NULL,
    CHECK (from_customer <> to_customer)
);

CREATE INDEX transfer_ticket_id_idx ON transfer (ticket_id);

CREATE TABLE resale_listing (
    listing_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id integer NOT NULL REFERENCES ticket,
    seller_id integer NOT NULL REFERENCES customer,
    price numeric(8,2) NOT NULL,
    listed_at timestamptz NOT NULL,
    status resale_status NOT NULL DEFAULT 'listed',
    buyer_id integer REFERENCES customer,
    closed_at timestamptz,
    CHECK ((status = 'sold') = (buyer_id IS NOT NULL))
);

CREATE INDEX resale_listing_ticket_id_idx ON resale_listing (ticket_id);
CREATE UNIQUE INDEX resale_one_open_listing ON resale_listing (ticket_id) WHERE status = 'listed';

-- Resale is capped at 110% of face value. The cap compares against another
-- table, which a CHECK constraint can't do, so a constraint trigger does.
CREATE FUNCTION resale_price_cap() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_face numeric;
BEGIN
    SELECT face_value INTO v_face FROM ticket WHERE ticket_id = NEW.ticket_id;
    IF NEW.price > round(v_face * 1.10, 2) THEN
        RAISE EXCEPTION 'resale price % is above the cap of % (110%% of face value %)',
            NEW.price, round(v_face * 1.10, 2), v_face
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER resale_price_cap
    AFTER INSERT OR UPDATE OF price ON resale_listing
    FOR EACH ROW EXECUTE FUNCTION resale_price_cap();

CREATE TABLE scan (
    scan_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id integer REFERENCES ticket,
    barcode uuid NOT NULL,
    gate text NOT NULL,
    scanned_at timestamptz NOT NULL,
    result scan_result NOT NULL
);

CREATE INDEX scan_ticket_id_idx ON scan (ticket_id);

--
-- Selling seats
--

-- hold_seats: hold up to p_count available seats in a tier for a customer,
-- best rows first. FOR UPDATE SKIP LOCKED makes concurrent buyers skip
-- rows another transaction is holding instead of waiting for it, so a
-- thousand buyers in the same tier each get different seats, at once.
-- Expired holds count as available.
CREATE FUNCTION hold_seats(p_event_id integer, p_tier_id integer, p_count integer,
                           p_customer_id integer, p_minutes integer DEFAULT 10,
                           p_now timestamptz DEFAULT now())
RETURNS SETOF event_seat
LANGUAGE sql
BEGIN ATOMIC
    WITH pick AS (
        SELECT es.event_id, es.seat_id
        FROM event_seat es
        JOIN seat s USING (seat_id)
        WHERE es.event_id = p_event_id
          AND es.tier_id = p_tier_id
          AND (es.status = 'available' OR (es.status = 'held' AND es.hold_expires_at < p_now))
        ORDER BY s.section_id, s.row_label, s.seat_no
        LIMIT p_count
        FOR UPDATE OF es SKIP LOCKED
    )
    UPDATE event_seat es
    SET status = 'held', held_by = p_customer_id,
        hold_expires_at = p_now + make_interval(mins => p_minutes)
    FROM pick
    WHERE es.event_id = pick.event_id AND es.seat_id = pick.seat_id
    RETURNING es.*;
END;

-- buy_held_seats: turn a customer's held seats for an event into an order
-- and tickets. Only holds that haven't expired are bought. They are locked
-- first, so a concurrent hold_seats() can't take one over (once expired)
-- between the statements below, and the order, the tickets and the seats
-- marked sold all cover exactly the same seats.
CREATE FUNCTION buy_held_seats(p_event_id integer, p_customer_id integer,
                               p_now timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id integer;
    v_seats integer[];
BEGIN
    SELECT array_agg(seat_id ORDER BY seat_id) INTO v_seats
    FROM (SELECT seat_id FROM event_seat
          WHERE event_id = p_event_id AND held_by = p_customer_id
            AND status = 'held' AND hold_expires_at >= p_now
          FOR UPDATE) s;

    IF v_seats IS NULL THEN
        RAISE EXCEPTION 'customer % holds no seats for event %', p_customer_id, p_event_id;
    END IF;

    INSERT INTO orders (customer_id, event_id, created_at, total)
    SELECT p_customer_id, p_event_id, p_now, sum(pt.price)
    FROM event_seat es JOIN price_tier pt USING (tier_id)
    WHERE es.event_id = p_event_id AND es.seat_id = ANY (v_seats)
    RETURNING order_id INTO v_order_id;

    INSERT INTO ticket (order_id, event_id, seat_id, holder_id, face_value, barcode)
    SELECT v_order_id, es.event_id, es.seat_id, p_customer_id, pt.price, uuidv7()
    FROM event_seat es JOIN price_tier pt USING (tier_id)
    WHERE es.event_id = p_event_id AND es.seat_id = ANY (v_seats)
    ORDER BY es.seat_id;

    UPDATE event_seat
    SET status = 'sold', held_by = NULL, hold_expires_at = NULL
    WHERE event_id = p_event_id AND seat_id = ANY (v_seats);

    RETURN v_order_id;
END
$$;

-- release_expired_holds: put expired holds back on sale. Many app servers
-- may call this; a transaction-level advisory lock keyed on the event lets
-- one of them do the work and the rest return at once (-1) instead of
-- queueing on the same rows.
CREATE FUNCTION release_expired_holds(p_event_id integer, p_now timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_released integer;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('release_expired_holds'), p_event_id) THEN
        RETURN -1;
    END IF;

    UPDATE event_seat
    SET status = 'available', held_by = NULL, hold_expires_at = NULL
    WHERE event_id = p_event_id AND status = 'held' AND hold_expires_at < p_now;
    GET DIAGNOSTICS v_released = ROW_COUNT;
    RETURN v_released;
END
$$;

-- Every new ticket is announced on the ticket_sold channel. Listeners
-- (LISTEN ticket_sold) receive it when the transaction commits, and not at
-- all if it rolls back. Payloads are JSON.
CREATE FUNCTION notify_ticket_sold() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ticket_sold', json_build_object(
        'event_id', NEW.event_id, 'seat_id', NEW.seat_id,
        'ticket_id', NEW.ticket_id, 'price', NEW.face_value)::text);
    RETURN NULL;
END
$$;

CREATE TRIGGER notify_ticket_sold
    AFTER INSERT ON ticket
    FOR EACH ROW EXECUTE FUNCTION notify_ticket_sold();

--
-- Row-level security
--

-- The customer-facing app connects as fil_customer and sets
-- app.customer_id for each request; the policies then only show that
-- customer's tickets and orders. Table owners and superusers bypass RLS.
--
-- Once SET LOCAL has defined app.customer_id on a connection, it reads as
-- '' (not NULL) after that transaction ends, so the policies map '' to
-- NULL: a pooled connection with no customer set sees no rows instead of
-- failing on ''::integer.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'fil_customer') THEN
        CREATE ROLE fil_customer NOLOGIN;
    END IF;
END
$$;

GRANT SELECT ON venue, section, seat, artist, event, price_tier, event_seat,
                 ticket, orders, transfer TO fil_customer;

ALTER TABLE ticket ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY ticket_holder ON ticket FOR SELECT TO fil_customer
    USING (holder_id = nullif(current_setting('app.customer_id', true), '')::integer);

CREATE POLICY order_buyer ON orders FOR SELECT TO fil_customer
    USING (customer_id = nullif(current_setting('app.customer_id', true), '')::integer);

--
-- Views
--

-- section_path: every section with its full path and depth, built with a
-- recursive CTE from the levels down.
CREATE VIEW section_path AS
WITH RECURSIVE tree AS (
    SELECT section_id, venue_id, parent_id, name, view_rank,
           name AS path, 1 AS depth
    FROM section
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.section_id, c.venue_id, c.parent_id, c.name, c.view_rank,
           t.path || ' > ' || c.name, t.depth + 1
    FROM section c
    JOIN tree t ON c.parent_id = t.section_id
)
SELECT * FROM tree;

-- event_sales: sold, held and available seats and revenue per event.
CREATE VIEW event_sales AS
SELECT e.event_id, e.name, e.starts_at, e.status,
       count(*) AS capacity,
       count(*) FILTER (WHERE es.status = 'sold') AS sold,
       count(*) FILTER (WHERE es.status = 'held') AS held,
       count(*) FILTER (WHERE es.status = 'available') AS available,
       round(100.0 * count(*) FILTER (WHERE es.status = 'sold') / count(*), 1) AS pct_sold,
       sum(pt.price) FILTER (WHERE es.status = 'sold') AS revenue
FROM event e
JOIN event_seat es USING (event_id)
JOIN price_tier pt USING (tier_id)
GROUP BY e.event_id;
