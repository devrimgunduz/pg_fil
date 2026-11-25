--
-- pagila-ng: stays
--
-- A short-term vacation rental marketplace: hosts list homes, guests book
-- nights, pay, message the host and leave reviews. All amounts are in USD.
--
-- PostgreSQL features shown here:
--   * exclusion constraints on date ranges: a listing can never be double
--     booked, enforced by the database rather than application code
--   * WITHOUT OVERLAPS temporal primary keys (PostgreSQL 18) for seasonal
--     pricing
--   * PostGIS geography points and radius searches
--   * JSONB amenities with a GIN index, queried with SQL/JSON (JSON_TABLE,
--     JSON_EXISTS)
--   * full-text search plus pg_trgm fuzzy matching over listings and reviews
--   * stored generated columns (nights, totals, tsvectors)
--
-- Requires PostgreSQL 18+ and PostGIS. Load with:
--   createdb stays
--   psql -d stays -f schema.sql
--   psql -d stays -f generate-data.sql
--

SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS postgis;
-- btree_gist supplies GiST equality operators for plain columns such as
-- listing_id, which exclusion constraints and WITHOUT OVERLAPS keys combine
-- with the range column.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TYPE property_type AS ENUM
    ('apartment', 'house', 'cabin', 'villa', 'loft', 'tiny_home', 'boat');
CREATE TYPE booking_status AS ENUM ('confirmed', 'completed', 'cancelled');
CREATE TYPE payment_method AS ENUM ('card', 'wallet', 'bank_transfer');
CREATE TYPE payment_status AS ENUM ('captured', 'refunded');
CREATE TYPE message_sender AS ENUM ('guest', 'host');

CREATE TABLE city (
    city_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    country_code char(2) NOT NULL,
    timezone text NOT NULL,
    location geography(Point, 4326) NOT NULL,
    UNIQUE (name, country_code)
);

CREATE TABLE host (
    host_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    email text NOT NULL UNIQUE,
    languages text[] NOT NULL DEFAULT '{en}',
    is_superhost boolean NOT NULL DEFAULT false,
    joined_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE guest (
    guest_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    email text NOT NULL UNIQUE,
    country_code char(2) NOT NULL,
    joined_at timestamptz NOT NULL DEFAULT now()
);

-- amenities is a JSONB document, because amenities vary a lot between
-- property types and change often:
--   {"wifi": {"mbps": 300}, "pool": {"heated": true}, "pets": false, ...}
CREATE TABLE listing (
    listing_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    host_id integer NOT NULL REFERENCES host,
    city_id integer NOT NULL REFERENCES city,
    title text NOT NULL,
    description text NOT NULL,
    property_type property_type NOT NULL,
    max_guests smallint NOT NULL CHECK (max_guests > 0),
    bedrooms smallint NOT NULL CHECK (bedrooms >= 0),
    beds smallint NOT NULL CHECK (beds > 0),
    bathrooms numeric(3,1) NOT NULL CHECK (bathrooms >= 0),
    base_nightly_rate numeric(8,2) NOT NULL CHECK (base_nightly_rate > 0),
    cleaning_fee numeric(7,2) NOT NULL DEFAULT 0,
    min_nights smallint NOT NULL DEFAULT 1,
    location geography(Point, 4326) NOT NULL,
    amenities jsonb NOT NULL DEFAULT '{}',
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    search tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', title), 'A') ||
        setweight(to_tsvector('english', description), 'B')
    ) STORED
);

CREATE INDEX listing_host_id_idx ON listing (host_id);
CREATE INDEX listing_city_id_idx ON listing (city_id);
CREATE INDEX listing_location_idx ON listing USING gist (location);
CREATE INDEX listing_amenities_idx ON listing USING gin (amenities jsonb_path_ops);
CREATE INDEX listing_search_idx ON listing USING gin (search);
CREATE INDEX listing_title_trgm_idx ON listing USING gin (title gin_trgm_ops);

CREATE TABLE listing_photo (
    photo_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id integer NOT NULL REFERENCES listing ON DELETE CASCADE,
    position smallint NOT NULL,
    url text NOT NULL,
    caption text,
    UNIQUE (listing_id, position)
);

-- season_rate: the nightly rate in effect for a listing over a period.
-- WITHOUT OVERLAPS makes the primary key a temporal one: two rows for the
-- same listing can't cover the same night. Nights outside every season use
-- listing.base_nightly_rate.
CREATE TABLE season_rate (
    listing_id integer NOT NULL REFERENCES listing ON DELETE CASCADE,
    valid_at daterange NOT NULL,
    nightly_rate numeric(8,2) NOT NULL CHECK (nightly_rate > 0),
    label text NOT NULL,
    PRIMARY KEY (listing_id, valid_at WITHOUT OVERLAPS)
);

-- availability_block: nights the host has taken off the market (owner
-- stays, maintenance). Blocks can't overlap each other either.
CREATE TABLE availability_block (
    block_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id integer NOT NULL REFERENCES listing ON DELETE CASCADE,
    during daterange NOT NULL CHECK (NOT isempty(during)),
    reason text NOT NULL,
    EXCLUDE USING gist (listing_id WITH =, during WITH &&)
);

-- booking.stay runs from the check-in date (inclusive) to the check-out date
-- (exclusive), so back-to-back stays [3,6) and [6,9) don't overlap.
--
-- The exclusion constraint is the heart of this database: no two
-- non-cancelled bookings of the same listing may have overlapping stays.
-- Cancelled bookings are left out by the WHERE clause, so their nights can
-- be booked again.
CREATE TABLE booking (
    booking_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id integer NOT NULL REFERENCES listing,
    guest_id integer NOT NULL REFERENCES guest,
    stay daterange NOT NULL CHECK (NOT isempty(stay) AND NOT upper_inf(stay)),
    guests smallint NOT NULL CHECK (guests > 0),
    status booking_status NOT NULL DEFAULT 'confirmed',
    accommodation numeric(10,2) NOT NULL,
    cleaning_fee numeric(7,2) NOT NULL DEFAULT 0,
    service_fee numeric(8,2) NOT NULL DEFAULT 0,
    booked_at timestamptz NOT NULL DEFAULT now(),
    cancelled_at timestamptz,
    nights integer GENERATED ALWAYS AS (upper(stay) - lower(stay)) STORED,
    total numeric(10,2) GENERATED ALWAYS AS (accommodation + cleaning_fee + service_fee) STORED,
    CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
    EXCLUDE USING gist (listing_id WITH =, stay WITH &&) WHERE (status <> 'cancelled')
);

CREATE INDEX booking_guest_id_idx ON booking (guest_id);
CREATE INDEX booking_stay_idx ON booking USING gist (stay);

-- Bookings and blocks live in different tables, so a single exclusion
-- constraint can't cover both; this trigger rejects a booking whose nights
-- overlap one of the listing's availability blocks.
CREATE FUNCTION booking_check_not_blocked() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'cancelled' AND EXISTS (
        SELECT FROM availability_block b
        WHERE b.listing_id = NEW.listing_id AND b.during && NEW.stay
    ) THEN
        RAISE EXCEPTION 'listing % is blocked during %', NEW.listing_id, NEW.stay
            USING ERRCODE = 'exclusion_violation';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER booking_check_not_blocked
    BEFORE INSERT OR UPDATE OF listing_id, stay, status ON booking
    FOR EACH ROW EXECUTE FUNCTION booking_check_not_blocked();

CREATE TABLE payment (
    payment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id integer NOT NULL REFERENCES booking,
    amount numeric(10,2) NOT NULL,
    method payment_method NOT NULL,
    status payment_status NOT NULL DEFAULT 'captured',
    paid_at timestamptz NOT NULL
);

CREATE INDEX payment_booking_id_idx ON payment (booking_id);

CREATE TABLE payout (
    payout_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    host_id integer NOT NULL REFERENCES host,
    booking_id integer NOT NULL UNIQUE REFERENCES booking,
    amount numeric(10,2) NOT NULL,
    paid_at timestamptz NOT NULL
);

CREATE INDEX payout_host_id_idx ON payout (host_id);

CREATE TABLE review (
    review_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id integer NOT NULL UNIQUE REFERENCES booking,
    rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    cleanliness smallint NOT NULL CHECK (cleanliness BETWEEN 1 AND 5),
    location_rating smallint NOT NULL CHECK (location_rating BETWEEN 1 AND 5),
    value_rating smallint NOT NULL CHECK (value_rating BETWEEN 1 AND 5),
    body text NOT NULL,
    created_at timestamptz NOT NULL,
    search tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED
);

CREATE INDEX review_search_idx ON review USING gin (search);

CREATE TABLE message (
    message_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id integer NOT NULL REFERENCES booking,
    sender message_sender NOT NULL,
    body text NOT NULL,
    sent_at timestamptz NOT NULL
);

CREATE INDEX message_booking_id_idx ON message (booking_id);

--
-- Functions and views
--

-- nightly_rate: the rate for one night of a listing, taking seasons into
-- account.
CREATE FUNCTION nightly_rate(p_listing_id integer, p_night date)
RETURNS numeric
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT coalesce(
        (SELECT s.nightly_rate FROM season_rate s
         WHERE s.listing_id = p_listing_id AND s.valid_at @> p_night),
        (SELECT l.base_nightly_rate FROM listing l
         WHERE l.listing_id = p_listing_id));
END;

-- quote_stay: the accommodation price of a stay, night by night.
CREATE FUNCTION quote_stay(p_listing_id integer, p_stay daterange)
RETURNS numeric
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT sum(nightly_rate(p_listing_id, night::date))
    FROM generate_series(lower(p_stay), upper(p_stay) - 1, interval '1 day') AS night;
END;

-- available_listings: active listings within p_radius_m metres of a point
-- that sleep p_guests and are free (no booking, no block) for p_stay.
CREATE FUNCTION available_listings(p_near geography, p_radius_m float8,
                                   p_stay daterange, p_guests integer)
RETURNS SETOF listing
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT l.*
    FROM listing l
    WHERE l.is_active
      AND l.max_guests >= p_guests
      AND (upper(p_stay) - lower(p_stay)) >= l.min_nights
      AND ST_DWithin(l.location, p_near, p_radius_m)
      AND NOT EXISTS (SELECT FROM booking b
                      WHERE b.listing_id = l.listing_id
                        AND b.status <> 'cancelled'
                        AND b.stay && p_stay)
      AND NOT EXISTS (SELECT FROM availability_block a
                      WHERE a.listing_id = l.listing_id
                        AND a.during && p_stay);
END;

-- listing_rating: review averages per listing.
CREATE VIEW listing_rating AS
SELECT b.listing_id,
       count(*) AS reviews,
       round(avg(r.rating), 2) AS rating,
       round(avg(r.cleanliness), 2) AS cleanliness,
       round(avg(r.location_rating), 2) AS location_rating,
       round(avg(r.value_rating), 2) AS value_rating
FROM review r
JOIN booking b USING (booking_id)
GROUP BY b.listing_id;

-- monthly_occupancy: booked nights per listing and calendar month, split
-- with range intersection (*) so a stay across a month boundary counts
-- toward both months.
CREATE VIEW monthly_occupancy AS
SELECT b.listing_id,
       lower(m.month)::date AS month,
       sum(upper(b.stay * m.month) - lower(b.stay * m.month)) AS booked_nights,
       upper(m.month) - lower(m.month) AS nights_in_month,
       round(100.0 * sum(upper(b.stay * m.month) - lower(b.stay * m.month))
             / (upper(m.month) - lower(m.month)), 1) AS occupancy_pct
FROM booking b
CROSS JOIN LATERAL (
    SELECT daterange(d::date, (d + interval '1 month')::date) AS month
    FROM generate_series(date_trunc('month', lower(b.stay)),
                         date_trunc('month', upper(b.stay) - 1),
                         interval '1 month') AS d
) m
WHERE b.status <> 'cancelled'
GROUP BY b.listing_id, m.month;
