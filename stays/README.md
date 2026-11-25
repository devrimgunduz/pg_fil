# stays

A short-term vacation rental marketplace. Hosts list apartments, houses,
cabins and boats in 24 cities; guests book stays, pay, message the host and
leave reviews. The data runs from January 2024 to March 2027 and is "as of"
2026-11-01: stays that ended before then are `completed`, later ones are
`confirmed` future bookings, and about 7% of bookings are `cancelled`.

This database is about **ranges and constraints**: the database itself makes
double bookings impossible.

## Tables

| Table | What it holds |
|---|---|
| `city` | 24 cities with a PostGIS centre point and time zone |
| `host`, `guest` | people on both sides of the marketplace |
| `listing` | a home: type, size, base nightly rate, location, JSONB `amenities`, full-text `search` column |
| `listing_photo` | photo URLs per listing |
| `season_rate` | seasonal nightly rates, a temporal (`WITHOUT OVERLAPS`) primary key |
| `availability_block` | nights the host took off the market |
| `booking` | a stay as a `daterange` (check-in inclusive, check-out exclusive), with generated `nights` and `total` |
| `payment`, `payout` | money in from guests (and refunds), money out to hosts |
| `review` | ratings and text, with a generated `tsvector` |
| `message` | guest/host messages before a stay |

Functions and views: `nightly_rate(listing, date)`, `quote_stay(listing, daterange)`,
`available_listings(point, radius, daterange, guests)`, `listing_rating`,
`monthly_occupancy`.

At the default scale there are 1,500 listings, 12,000 guests and about
58,000 bookings.

## Install

Requires PostgreSQL 18+ and PostGIS (`postgresql-19-postgis-3` on apt,
`postgis37_19` on dnf; btree_gist and pg_trgm ship with PostgreSQL).

```
createdb stays
psql -d stays -f schema.sql
psql -d stays -f generate-data.sql            # about 15 seconds
psql -d stays -v scale=3 -f generate-data.sql # or: 3x the data
psql -d stays -f queries.sql                  # all the examples below
```

The generator is deterministic, so the same scale always gives the same rows,
and the results below match what you get.

## Exclusion constraints: no double bookings

```sql
EXCLUDE USING gist (listing_id WITH =, stay WITH &&) WHERE (status <> 'cancelled')
```

No two non-cancelled bookings of the same listing may have overlapping
(`&&`) stays. Because stays are `[check-in, check-out)` ranges, back-to-back
stays such as `[2026-12-03,2026-12-06)` and `[2026-12-06,2026-12-09)` are
fine. The `WHERE` clause leaves cancelled bookings out, so their nights can
be booked again. Overlapping a block in `availability_block` is rejected by
a trigger, since one constraint can't span two tables.

```
stays=# INSERT INTO booking (listing_id, guest_id, stay, guests, accommodation)
        SELECT listing_id, 1, stay, 1, 100 FROM booking WHERE booking_id = 57000;
ERROR:  conflicting key value violates exclusion constraint "booking_listing_id_stay_excl"
```

## Temporal primary keys (PostgreSQL 18)

```sql
PRIMARY KEY (listing_id, valid_at WITHOUT OVERLAPS)
```

`season_rate` can't hold two rates for the same listing on the same night.
`nightly_rate()` picks the season covering a night or falls back to the base
rate, and `quote_stay()` adds the nights up:

```sql
SELECT quote_stay(1, daterange('2026-12-17', '2026-12-23'));  -- 3 regular + 3 holiday nights
```

## Multiranges

`range_agg()` merges ranges into a multirange, and multirange subtraction
answers "which nights are still free?":

```sql
SELECT datemultirange(daterange('2026-12-01', '2027-01-01'))
       - (SELECT range_agg(stay) FROM booking WHERE listing_id = 1 AND status <> 'cancelled')
       - (SELECT range_agg(during) FROM availability_block WHERE listing_id = 1);
--  {[2026-12-01,2026-12-20),[2026-12-27,2027-01-01)}
```

The `monthly_occupancy` view uses range intersection (`stay * month`) to split
stays that cross a month boundary.

## PostGIS

Listings have a `geography(Point)` with a GiST index. `available_listings()`
combines `ST_DWithin` with `NOT EXISTS` checks for bookings and blocks, and
`<->` orders the results nearest first:

```sql
SELECT a.listing_id, a.title, round(ST_Distance(a.location, c.location)) AS metres
FROM city c, available_listings(c.location, 5000, daterange('2027-02-05', '2027-02-10'), 2) a
WHERE c.name = 'Lisbon'
ORDER BY a.location <-> c.location;
```

## JSONB and SQL/JSON

Amenities differ a lot between a boat and a villa, so they are a JSONB
document with a `jsonb_path_ops` GIN index:

```json
{"wifi": {"mbps": 300}, "pool": {"heated": true}, "parking": {"spaces": 2, "ev_charger": true}, "self_check_in": "keypad"}
```

```sql
-- containment, using the GIN index
SELECT * FROM listing WHERE amenities @> '{"pool": {"heated": true}}';

-- SQL/JSON path predicates
SELECT count(*) FROM listing
WHERE amenities @? '$.wifi ? (@.mbps >= 500)'
  AND JSON_EXISTS(amenities, '$.workspace ? (@ == true)');

-- JSON_TABLE turns each amenity into a row
SELECT a.amenity, count(*)
FROM listing l,
     JSON_TABLE(l.amenities, '$.keyvalue()'
         COLUMNS (amenity text PATH '$.key', val jsonb PATH '$.value')) a
WHERE a.val <> 'false'
GROUP BY a.amenity ORDER BY 2 DESC;
```

## Full-text search and pg_trgm

`listing.search` and `review.search` are stored generated `tsvector`
columns with GIN indexes. Listing titles are weighted above descriptions.

```sql
SELECT listing_id, title, ts_rank(search, q)
FROM listing, websearch_to_tsquery('english', 'terrace sunset -noisy') q
WHERE search @@ q ORDER BY 3 DESC LIMIT 5;

SELECT ts_headline('english', body, q, 'StartSel=[, StopSel=]')
FROM review, websearch_to_tsquery('english', 'wifi') q
WHERE search @@ q LIMIT 5;
```

A trigram index on titles finds matches despite typos:

```sql
SELECT title, similarity(title, 'cosy apartmnt lisbon')
FROM listing WHERE title % 'cosy apartmnt lisbon' ORDER BY 2 DESC;
```

## Generated columns

`booking.nights` (`upper(stay) - lower(stay)`) and `booking.total`
(`accommodation + cleaning_fee + service_fee`) are stored generated columns,
so they can never disagree with the stay or the fees.
