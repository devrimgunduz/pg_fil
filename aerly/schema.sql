--
-- pg_fil: aerly
--
-- Shared trip planning and live flight tracking, from Aerly
-- (https://github.com/dpage/aerly), Dave Page's app for "who's already in
-- the air to the conference?". A trip gathers flights, trains, hotels,
-- taxis, meals, excursions and more onto one shared timeline; friends see
-- each other's trips and flights, the poller follows each flight and keeps
-- its positions, and travellers get alerts, reminders and calendar feeds.
--
-- This is Aerly's own schema as its migrations leave it (0001 to 0057,
-- upstream commit b703dad, October 2026), table for table and column for
-- column, so the Aerly app can be pointed at the generated data. The
-- tables are regrouped and commented here; pg_dump --schema-only of this
-- file and of a database migrated by Aerly are identical.
--
-- PostgreSQL features shown here (and in queries.sql):
--   * time zones done properly: every instant is a timestamptz, and the
--     IANA zone it happened in is kept beside it, with where that zone came
--     from (confirmed, inferred, unknown, or "floating" wall-clock time)
--   * a symmetric relationship stored once: friendships keep each pair as
--     (user_low, user_high), with CHECK constraints doing the bookkeeping
--   * partial and expression indexes: case-insensitive unique usernames and
--     email addresses, at most one primary email per user, unread-only
--     inbox indexes, dedupe keys that only apply when a value is present
--   * a self-referencing foreign key (plan_parts.supersedes_id) that
--     queries.sql walks with a recursive CTE
--   * a SQL function for per-plan privacy, used inside queries
--   * 1:1 "satellite" tables per plan type instead of a sparse wide table
--
-- Requires PostgreSQL 18+ (no extensions). Load with:
--   createdb aerly
--   psql -d aerly -f schema.sql
--   psql -d aerly -f generate-data.sql
--
-- Aerly is Copyright (c) 2026, Dave Page, under the PostgreSQL License.
--

SET client_min_messages = warning;

--
-- Users and how they sign in
--

-- users: one row per person. The first user to sign in becomes superuser.
-- home_tz is the IANA zone emails and push messages are written in ('' =
-- not known yet). session_version is bumped to sign a user out everywhere.
CREATE TABLE users (
    id bigserial PRIMARY KEY,
    name text NOT NULL DEFAULT '',
    avatar_url text NOT NULL DEFAULT '',
    is_superuser boolean NOT NULL DEFAULT false,
    is_active boolean NOT NULL DEFAULT true,
    last_login_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    username text NOT NULL,
    home_address text NOT NULL DEFAULT '',
    session_version integer NOT NULL DEFAULT 0,
    paper_size text NOT NULL DEFAULT 'a4'
        CONSTRAINT users_paper_size_check CHECK (paper_size IN ('a4', 'letter')),
    hide_explore boolean NOT NULL DEFAULT false,
    hide_maps boolean NOT NULL DEFAULT false,
    home_lat double precision,
    home_lon double precision,
    home_tz text NOT NULL DEFAULT ''
);

-- Usernames are unique whatever their case: an expression index.
CREATE UNIQUE INDEX users_username_lower_idx ON users (lower(username));

-- user_identities: linked OAuth accounts, one per (provider, external id).
CREATE TABLE user_identities (
    id bigserial PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    provider text NOT NULL,
    provider_user_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    CONSTRAINT user_identities_provider_provider_user_id_key UNIQUE (provider, provider_user_id)
);

CREATE INDEX user_identities_user_id_idx ON user_identities (user_id);

-- user_emails: a user's addresses. Forwarded booking emails are matched to
-- users through verified addresses.
CREATE TABLE user_emails (
    id bigserial PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    address text NOT NULL,
    verified boolean NOT NULL DEFAULT false,
    verify_token text,
    verify_sent_at timestamptz,
    verified_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    is_primary boolean NOT NULL DEFAULT false
);

-- An address belongs to one user, whatever its case; and a partial unique
-- index allows many addresses per user but only one primary.
CREATE UNIQUE INDEX user_emails_address_lower_idx ON user_emails (lower(address));
CREATE UNIQUE INDEX user_emails_one_primary ON user_emails (user_id) WHERE is_primary;
CREATE INDEX user_emails_user_idx ON user_emails (user_id);

--
-- Preferences
--

-- alert_prefs: how a user hears about flight changes (in-app, email), the
-- smallest delay worth an alert, and the opt-in check-in reminder (24 hours
-- before departure) and departure summary (4 hours before).
CREATE TABLE alert_prefs (
    user_id bigint PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    in_app boolean NOT NULL DEFAULT true,
    email boolean NOT NULL DEFAULT true,
    min_delay_min integer NOT NULL DEFAULT 15,
    checkin boolean NOT NULL DEFAULT false,
    departure_summary boolean NOT NULL DEFAULT true
);

-- push_kind_prefs: web push switched off (or on) per kind of message:
-- alert, share, reminder, checkin, departure. No row = on.
CREATE TABLE push_kind_prefs (
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind text NOT NULL,
    enabled boolean NOT NULL,
    PRIMARY KEY (user_id, kind)
);

-- webpush_subscriptions: one row per browser or phone that accepted push.
CREATE TABLE webpush_subscriptions (
    id bigserial PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    endpoint text NOT NULL CONSTRAINT webpush_subscriptions_endpoint_key UNIQUE,
    p256dh text NOT NULL,
    auth text NOT NULL,
    user_agent text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    last_success_at timestamptz,
    last_failure_at timestamptz,
    failure_count integer NOT NULL DEFAULT 0
);

CREATE INDEX webpush_subscriptions_user_idx ON webpush_subscriptions (user_id);

-- calendar_tokens: secret iCalendar feed URLs. scope is 'me' or 'friends'
-- (resource_id 0) or 'trip' / 'plan' (resource_id names it).
CREATE TABLE calendar_tokens (
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    scope text NOT NULL,
    token text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    resource_id bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, scope, resource_id)
);

CREATE UNIQUE INDEX calendar_tokens_token_idx ON calendar_tokens (token);

--
-- Friends
--

-- friendships: an undirected relationship stored once. The pair is always
-- written low id first, so (3, 7) and (7, 3) can't both exist, and the
-- CHECKs keep the requester one of the two. A pending request carries the
-- email address the invitation went to.
CREATE TABLE friendships (
    user_low bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    user_high bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status text NOT NULL
        CONSTRAINT friendships_status_check CHECK (status IN ('pending', 'accepted')),
    requested_by bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    requested_at timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    invited_email text,
    PRIMARY KEY (user_low, user_high),
    CONSTRAINT friendships_check CHECK (user_low < user_high),
    CONSTRAINT friendships_check1 CHECK (requested_by = user_low OR requested_by = user_high),
    CONSTRAINT friendships_pending_has_invited_email CHECK (status <> 'pending' OR invited_email IS NOT NULL)
);

CREATE INDEX friendships_user_high_idx ON friendships (user_high);
CREATE INDEX friendships_user_low_idx ON friendships (user_low);

-- pending_friend_invites: invitations to people with no account yet,
-- turned into friendships when they first sign in with that address.
CREATE TABLE pending_friend_invites (
    email_lower text NOT NULL,
    inviter_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    message text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (email_lower, inviter_id)
);

CREATE INDEX pending_friend_invites_email_idx ON pending_friend_invites (email_lower);

-- user_auto_shares: "always share my new trips with ..." defaults, as a
-- viewer, an editor or a passenger on every plan.
CREATE TABLE user_auto_shares (
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    share_with_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role text NOT NULL
        CONSTRAINT user_auto_shares_role_check CHECK (role IN ('viewer', 'editor', 'passenger')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, share_with_id),
    CONSTRAINT user_auto_shares_check CHECK (user_id <> share_with_id)
);

CREATE INDEX user_auto_shares_share_with_idx ON user_auto_shares (share_with_id);
CREATE INDEX user_auto_shares_user_idx ON user_auto_shares (user_id);

--
-- Trips
--

-- trips: a journey with a name, a destination and dates. starts_on and
-- ends_on are calendar dates at the destination, not instants.
-- share_all_friends_role, when set, gives every accepted friend of the
-- owner that role, computed at read time (so new friends are included and
-- unfriending revokes). tripit_id dedupes re-imports from TripIt.
CREATE TABLE trips (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    destination text NOT NULL DEFAULT '',
    starts_on date,
    ends_on date,
    created_by bigint REFERENCES users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    country_code text NOT NULL DEFAULT '',
    tripit_id text NOT NULL DEFAULT '',
    share_all_friends_role text
        CONSTRAINT trips_share_all_friends_role_check CHECK (share_all_friends_role IN ('viewer', 'editor')),
    place_reconciled boolean NOT NULL DEFAULT false,
    description text NOT NULL DEFAULT ''
);

CREATE INDEX trips_created_by_idx ON trips (created_by);
-- Only non-empty TripIt ids are unique: a partial unique index, which
-- INSERT ... ON CONFLICT can use to arbitrate concurrent imports.
CREATE UNIQUE INDEX trips_creator_tripit_id_uidx ON trips (created_by, tripit_id) WHERE tripit_id <> '';

-- trip_members: who else can see (viewer) or change (editor) a trip.
CREATE TABLE trip_members (
    trip_id bigint NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role text NOT NULL
        CONSTRAINT trip_members_role_check CHECK (role IN ('owner', 'editor', 'viewer')),
    added_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (trip_id, user_id)
);

CREATE INDEX trip_members_user_idx ON trip_members (user_id);

-- trip_passengers: people travelling on the whole trip, such as a partner
-- on a holiday. The app copies them onto every plan they may see, as
-- plan_passengers rows with via_trip = true.
CREATE TABLE trip_passengers (
    trip_id bigint NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    added_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (trip_id, user_id)
);

CREATE INDEX trip_passengers_user_idx ON trip_passengers (user_id);

-- trip_tags: free-text labels. label_norm is the lower-cased key;
-- text_pattern_ops lets the index serve prefix searches (LIKE 'conf%')
-- whatever the database collation.
CREATE TABLE trip_tags (
    trip_id bigint NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    label_norm text NOT NULL,
    label_display text NOT NULL,
    PRIMARY KEY (trip_id, label_norm)
);

CREATE INDEX trip_tags_label_idx ON trip_tags (label_norm text_pattern_ops);

-- trip_reminder_optin: remind me lead_hours before every plan on this trip.
CREATE TABLE trip_reminder_optin (
    trip_id bigint NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    lead_hours integer NOT NULL DEFAULT 24
        CONSTRAINT trip_reminder_optin_lead_hours_check CHECK (lead_hours > 0),
    PRIMARY KEY (trip_id, user_id)
);

-- trip_feeds: subscribed iCalendar feeds, such as a conference schedule,
-- polled with conditional GETs (etag, last_modified).
CREATE TABLE trip_feeds (
    id bigserial PRIMARY KEY,
    trip_id bigint NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    url text NOT NULL,
    name text NOT NULL DEFAULT '',
    etag text NOT NULL DEFAULT '',
    last_modified text NOT NULL DEFAULT '',
    last_fetched_at timestamptz,
    last_error text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    timezone text NOT NULL DEFAULT ''
);

CREATE INDEX trip_feeds_trip_idx ON trip_feeds (trip_id);

-- trip_feed_events: the feed's events (VEVENTs). All-day events have no
-- time of day; the rest are resolved to true instants when fetched.
CREATE TABLE trip_feed_events (
    id bigserial PRIMARY KEY,
    feed_id bigint NOT NULL REFERENCES trip_feeds (id) ON DELETE CASCADE,
    uid text NOT NULL DEFAULT '',
    summary text NOT NULL DEFAULT '',
    description text NOT NULL DEFAULT '',
    location text NOT NULL DEFAULT '',
    starts_at timestamptz NOT NULL,
    ends_at timestamptz,
    start_tz text NOT NULL DEFAULT '',
    all_day boolean NOT NULL DEFAULT false,
    start_tz_source text NOT NULL DEFAULT 'unknown'
        CONSTRAINT trip_feed_events_start_tz_source_check CHECK (start_tz_source IN ('confirmed', 'inferred', 'unknown'))
);

CREATE INDEX trip_feed_events_feed_idx ON trip_feed_events (feed_id);

--
-- Plans: the bookings on a trip
--

-- plans: one booking. type picks the satellite table its parts' details
-- live in. source says how it got here: typed in, pasted text or an
-- uploaded PDF read by an LLM, or a forwarded email.
CREATE TABLE plans (
    id bigserial PRIMARY KEY,
    trip_id bigint NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    type text NOT NULL
        CONSTRAINT plans_type_check CHECK (type IN ('flight', 'train', 'hotel', 'ground', 'dining', 'excursion',
                                                    'ice_cream', 'meeting', 'event', 'vehicle_hire')),
    title text NOT NULL DEFAULT '',
    confirmation_ref text NOT NULL DEFAULT '',
    notes text NOT NULL DEFAULT '',
    source text NOT NULL DEFAULT 'manual'
        CONSTRAINT plans_source_check CHECK (source IN ('manual', 'paste', 'upload', 'email')),
    created_by bigint REFERENCES users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    tripit_uid text NOT NULL DEFAULT '',
    ticket_number text NOT NULL DEFAULT '',
    cost_amount numeric(12,2),
    cost_currency text NOT NULL DEFAULT '',
    supplier_name text NOT NULL DEFAULT '',
    contact_email text NOT NULL DEFAULT '',
    contact_phone text NOT NULL DEFAULT '',
    website text NOT NULL DEFAULT '',
    share_all_friends boolean NOT NULL DEFAULT false
);

CREATE INDEX plans_trip_idx ON plans (trip_id);
CREATE UNIQUE INDEX plans_trip_tripit_uid_uidx ON plans (trip_id, tripit_uid) WHERE tripit_uid <> '';

-- plan_parts: the timed pieces of a plan: each leg of a flight booking,
-- each train, a hotel stay from check-in to check-out.
--
-- Every instant is a timestamptz, and start_tz / end_tz keep the IANA zone
-- it is local to, so "departs 07:05 in Lisbon, lands 10:50 in Warsaw" can
-- be shown in each place's own time. *_tz_source says where the zone came
-- from: 'confirmed' (the airport or the booking), 'inferred' (from the
-- coordinates), 'unknown', or 'floating': no zone, and the UTC digits are
-- the local wall-clock time ("dinner at 20:00, wherever we are").
--
-- A rescheduled part is not updated in place: the new part points at the
-- one it replaces with supersedes_id, and the old one is cancelled.
CREATE TABLE plan_parts (
    id bigserial PRIMARY KEY,
    plan_id bigint NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    seq integer NOT NULL DEFAULT 0,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz,
    start_tz text NOT NULL DEFAULT '',
    end_tz text NOT NULL DEFAULT '',
    start_label text NOT NULL DEFAULT '',
    start_lat double precision,
    start_lon double precision,
    end_label text NOT NULL DEFAULT '',
    end_lat double precision,
    end_lon double precision,
    status text NOT NULL DEFAULT 'planned'
        CONSTRAINT plan_parts_status_check CHECK (status IN ('planned', 'confirmed', 'cancelled')),
    supersedes_id bigint REFERENCES plan_parts (id) ON DELETE SET NULL,
    dismissed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    start_address text NOT NULL DEFAULT '',
    end_address text NOT NULL DEFAULT '',
    start_coords_pinned boolean NOT NULL DEFAULT false,
    end_coords_pinned boolean NOT NULL DEFAULT false,
    start_tz_source text NOT NULL DEFAULT 'unknown'
        CONSTRAINT plan_parts_start_tz_source_check CHECK (start_tz_source IN ('confirmed', 'inferred', 'unknown', 'floating')),
    end_tz_source text NOT NULL DEFAULT 'unknown'
        CONSTRAINT plan_parts_end_tz_source_check CHECK (end_tz_source IN ('confirmed', 'inferred', 'unknown', 'floating')),
    -- A zone is present exactly when its source says one is known.
    CONSTRAINT plan_parts_start_tz_source_matches CHECK ((start_tz = '') = (start_tz_source IN ('unknown', 'floating'))),
    CONSTRAINT plan_parts_end_tz_source_matches CHECK ((end_tz = '') = (end_tz_source IN ('unknown', 'floating')))
);

CREATE INDEX plan_parts_plan_idx ON plan_parts (plan_id);
CREATE INDEX plan_parts_starts_idx ON plan_parts (starts_at);

-- plan_passengers: who is travelling on a plan; they get its alerts.
-- via_trip marks rows copied from trip_passengers.
CREATE TABLE plan_passengers (
    plan_id bigint NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    added_at timestamptz NOT NULL DEFAULT now(),
    via_trip boolean NOT NULL DEFAULT false,
    PRIMARY KEY (plan_id, user_id)
);

CREATE INDEX plan_passengers_user_idx ON plan_passengers (user_id);

-- plan_visibility: per-plan privacy. No row = everyone on the trip sees
-- it; 'hidden_from' hides it from the listed members (a surprise dinner);
-- 'only_visible_to' shows it to the listed members only.
CREATE TABLE plan_visibility (
    plan_id bigint PRIMARY KEY REFERENCES plans (id) ON DELETE CASCADE,
    mode text NOT NULL
        CONSTRAINT plan_visibility_mode_check CHECK (mode IN ('hidden_from', 'only_visible_to'))
);

CREATE TABLE plan_visibility_members (
    plan_id bigint NOT NULL REFERENCES plan_visibility (plan_id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    PRIMARY KEY (plan_id, user_id)
);

-- plan_visible_to_member(plan, user): the privacy rule above, for a plain
-- trip member (the plan's creator and its passengers always see it).
CREATE FUNCTION plan_visible_to_member(p_plan bigint, p_user bigint) RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT NOT EXISTS (SELECT 1 FROM plan_visibility v WHERE v.plan_id = p_plan)
        OR EXISTS (
            SELECT 1 FROM plan_visibility v
            WHERE v.plan_id = p_plan AND v.mode = 'hidden_from'
              AND NOT EXISTS (
                SELECT 1 FROM plan_visibility_members m
                WHERE m.plan_id = p_plan AND m.user_id = p_user))
        OR EXISTS (
            SELECT 1 FROM plan_visibility v
            JOIN plan_visibility_members m ON m.plan_id = v.plan_id
            WHERE v.plan_id = p_plan AND v.mode = 'only_visible_to' AND m.user_id = p_user);
$$;

-- plan_alert_optin: trip members (not passengers) who also want a flight's
-- alerts.
CREATE TABLE plan_alert_optin (
    plan_id bigint NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    PRIMARY KEY (plan_id, user_id)
);

-- plan_reminder_optin: a reminder lead_hours before a plan starts.
CREATE TABLE plan_reminder_optin (
    plan_id bigint NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    enabled boolean NOT NULL,
    lead_hours integer NOT NULL DEFAULT 24
        CONSTRAINT plan_reminder_optin_lead_hours_check CHECK (lead_hours > 0),
    PRIMARY KEY (plan_id, user_id)
);

-- plan_links: title and URL pairs kept with a plan (an e-ticket, a
-- boarding pass), in the order they were entered.
CREATE TABLE plan_links (
    id bigserial PRIMARY KEY,
    plan_id bigint NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    "position" integer NOT NULL,
    title text NOT NULL,
    url text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX plan_links_plan_idx ON plan_links (plan_id, "position");

-- plan_attachments: uploaded files. The bytes live in an object store; the
-- row keeps the metadata and the store's key. Attachments outlive the
-- account that uploaded them.
CREATE TABLE plan_attachments (
    id bigserial PRIMARY KEY,
    plan_id bigint NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    uploaded_by bigint REFERENCES users (id) ON DELETE SET NULL,
    filename text NOT NULL,
    content_type text NOT NULL DEFAULT '',
    size_bytes bigint NOT NULL,
    storage_key text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX plan_attachments_plan_idx ON plan_attachments (plan_id);

--
-- Per-type details: one optional 1:1 row per plan part, in the table for
-- the plan's type.
--

-- flight_details: the tracker's view of one flight leg. ident is the
-- flight number (FA 123 as 'FA123'), icao24 the airframe's transponder
-- address, callsign what it broadcasts. Scheduled, estimated and actual
-- gate-out and gate-in times; flight_status as the data provider spells it
-- (Scheduled, Enroute, Arrived, Cancelled, Diverted, ...). last_alert_sig
-- stops the poller sending the same alert twice.
CREATE TABLE flight_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    ident text NOT NULL,
    icao24 text,
    callsign text,
    scheduled_out timestamptz NOT NULL,
    scheduled_in timestamptz NOT NULL,
    estimated_out timestamptz,
    estimated_in timestamptz,
    actual_out timestamptz,
    actual_in timestamptz,
    origin_iata text NOT NULL DEFAULT '',
    dest_iata text NOT NULL DEFAULT '',
    flight_status text NOT NULL DEFAULT 'Scheduled',
    last_polled_at timestamptz,
    last_resolved_at timestamptz,
    last_alert_sig text,
    origin_gate text,
    dest_gate text,
    origin_terminal text,
    dest_terminal text,
    aircraft_type text,
    dest_baggage_belt text,
    resolved boolean NOT NULL DEFAULT false
);

CREATE TABLE train_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    operator text NOT NULL DEFAULT '',
    service_no text NOT NULL DEFAULT '',
    coach text NOT NULL DEFAULT '',
    seat text NOT NULL DEFAULT '',
    class text NOT NULL DEFAULT '',
    platform text NOT NULL DEFAULT ''
);

-- hotel_details: any place to sleep; kind says what sort ('' = not
-- stated). The part's starts_at / ends_at are the check-in and check-out
-- instants; standard_checkin / standard_checkout are the property's usual
-- local times of day.
CREATE TABLE hotel_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    property_name text NOT NULL DEFAULT '',
    address text NOT NULL DEFAULT '',
    phone text NOT NULL DEFAULT '',
    room_type text NOT NULL DEFAULT '',
    guests integer,
    standard_checkin time,
    standard_checkout time,
    kind text NOT NULL DEFAULT ''
);

-- ground_details: taxis, shuttles and chauffeured transfers.
CREATE TABLE ground_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    provider text NOT NULL DEFAULT '',
    phone text NOT NULL DEFAULT '',
    vehicle text NOT NULL DEFAULT '',
    driver text NOT NULL DEFAULT '',
    pax integer
);

-- vehicle_hire_details: anything the traveller drives themselves. Excess
-- and deposit may be quoted in another currency than the booking.
CREATE TABLE vehicle_hire_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    category text NOT NULL DEFAULT '',
    vehicle text NOT NULL DEFAULT '',
    transmission text NOT NULL DEFAULT '',
    fuel_policy text NOT NULL DEFAULT '',
    mileage text NOT NULL DEFAULT '',
    excess_amount numeric(12,2),
    excess_currency text NOT NULL DEFAULT '',
    deposit_amount numeric(12,2),
    deposit_currency text NOT NULL DEFAULT ''
);

CREATE TABLE dining_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    party_size integer,
    reservation_name text NOT NULL DEFAULT '',
    phone text NOT NULL DEFAULT ''
);

CREATE TABLE excursion_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    provider text NOT NULL DEFAULT '',
    ticket_count integer
);

CREATE TABLE event_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    performer text NOT NULL DEFAULT '',
    category text NOT NULL DEFAULT '',
    venue_area text NOT NULL DEFAULT '',
    url text NOT NULL DEFAULT ''
);

CREATE TABLE meeting_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    location text NOT NULL DEFAULT '',
    organiser text NOT NULL DEFAULT '',
    platform text NOT NULL DEFAULT ''
);

-- ice_cream_details: an ice cream find, scored 0 to 5 after the fact.
CREATE TABLE ice_cream_details (
    plan_part_id bigint PRIMARY KEY REFERENCES plan_parts (id) ON DELETE CASCADE,
    rating smallint NOT NULL DEFAULT 0
        CONSTRAINT ice_cream_details_rating_check CHECK (rating >= 0 AND rating <= 5),
    what_ordered text NOT NULL DEFAULT ''
);

--
-- Flight tracking
--

-- positions: ADS-B fixes for a flight leg. When coverage drops out (over
-- an ocean), a dead reckoner extrapolates toward the destination and marks
-- those rows is_estimated. The partial index serves "last real fix".
CREATE TABLE positions (
    id bigserial PRIMARY KEY,
    ts timestamptz NOT NULL,
    lat double precision NOT NULL,
    lon double precision NOT NULL,
    altitude_ft integer,
    groundspeed_kt integer,
    heading_deg smallint,
    is_estimated boolean NOT NULL DEFAULT false,
    plan_part_id bigint NOT NULL REFERENCES plan_parts (id) ON DELETE CASCADE
);

CREATE INDEX positions_part_real_ts_idx ON positions (plan_part_id, ts DESC) WHERE is_estimated = false;
CREATE INDEX positions_part_ts_idx ON positions (plan_part_id, ts DESC);

--
-- Alerts, reminders and notifications
--

-- flight_alerts: the in-app inbox for flight news: kind is delayed,
-- cancelled, diverted or gate, or checkin, reminder or departure for the
-- opt-in nudges; status is the flight status at the time. read_at NULL
-- means unread, and the partial index makes the unread badge cheap.
CREATE TABLE flight_alerts (
    id bigserial PRIMARY KEY,
    user_id bigint NOT NULL,
    plan_part_id bigint NOT NULL,
    plan_id bigint NOT NULL,
    trip_id bigint NOT NULL,
    ident text NOT NULL,
    kind text NOT NULL,
    status text NOT NULL,
    message text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz,
    CONSTRAINT flight_alerts_part_fk FOREIGN KEY (plan_part_id) REFERENCES plan_parts (id) ON DELETE CASCADE,
    CONSTRAINT flight_alerts_plan_fk FOREIGN KEY (plan_id) REFERENCES plans (id) ON DELETE CASCADE,
    CONSTRAINT flight_alerts_trip_fk FOREIGN KEY (trip_id) REFERENCES trips (id) ON DELETE CASCADE,
    CONSTRAINT flight_alerts_user_fk FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX flight_alerts_plan_idx ON flight_alerts (plan_id);
CREATE INDEX flight_alerts_plan_part_idx ON flight_alerts (plan_part_id);
CREATE INDEX flight_alerts_trip_idx ON flight_alerts (trip_id);
CREATE INDEX flight_alerts_user_created_idx ON flight_alerts (user_id, created_at DESC);
CREATE INDEX flight_alerts_user_unread_idx ON flight_alerts (user_id) WHERE read_at IS NULL;

-- The "sent" tables make each nudge happen once per part and user. The
-- poller records the pair after trying to deliver, so a crash re-sends
-- rather than drops.
CREATE TABLE plan_reminder_sent (
    plan_part_id bigint NOT NULL REFERENCES plan_parts (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sent_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_part_id, user_id)
);

CREATE TABLE flight_checkin_sent (
    plan_part_id bigint NOT NULL REFERENCES plan_parts (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sent_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_part_id, user_id)
);

CREATE TABLE flight_departure_summary_sent (
    plan_part_id bigint NOT NULL REFERENCES plan_parts (id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sent_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_part_id, user_id)
);

-- notifications: the inbox for everything else; kind 'share' when a trip
-- or plan is shared with you.
CREATE TABLE notifications (
    id bigserial PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind text NOT NULL,
    actor_id bigint REFERENCES users (id) ON DELETE SET NULL,
    trip_id bigint REFERENCES trips (id) ON DELETE CASCADE,
    plan_id bigint REFERENCES plans (id) ON DELETE CASCADE,
    message text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz
);

CREATE INDEX notifications_plan_idx ON notifications (plan_id);
CREATE INDEX notifications_trip_idx ON notifications (trip_id);
CREATE INDEX notifications_user_created_idx ON notifications (user_id, created_at DESC);
CREATE INDEX notifications_user_unread_idx ON notifications (user_id) WHERE read_at IS NULL;

-- pending_shares: a trip (with a role) or a plan shared with an email
-- address that has no account yet; granted at the first verified login.
CREATE TABLE pending_shares (
    id bigserial PRIMARY KEY,
    email_lower text NOT NULL,
    kind text NOT NULL
        CONSTRAINT pending_shares_kind_check CHECK (kind IN ('trip', 'plan')),
    target_id bigint NOT NULL,
    role text
        CONSTRAINT pending_shares_role_check CHECK (role IN ('viewer', 'editor')),
    inviter_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pending_shares_email_lower_kind_target_id_key UNIQUE (email_lower, kind, target_id),
    CONSTRAINT pending_shares_check CHECK (kind = 'plan' OR role IN ('viewer', 'editor'))
);

CREATE INDEX pending_shares_email_idx ON pending_shares (email_lower);

-- email_ingests: a log of forwarded booking emails. status is ok,
-- partial, all_failed, nothing_found, no_user or rate_limited.
CREATE TABLE email_ingests (
    id bigserial PRIMARY KEY,
    received_at timestamptz NOT NULL DEFAULT now(),
    message_id text,
    from_address text NOT NULL,
    subject text NOT NULL DEFAULT '',
    dkim_pass boolean NOT NULL DEFAULT false,
    user_id bigint REFERENCES users (id) ON DELETE SET NULL,
    status text NOT NULL,
    flights_added integer NOT NULL DEFAULT 0,
    flights_failed integer NOT NULL DEFAULT 0,
    error text NOT NULL DEFAULT ''
);

CREATE INDEX email_ingests_user_idx ON email_ingests (user_id, received_at DESC);
