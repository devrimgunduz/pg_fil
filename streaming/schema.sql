--
-- pg_fil: streaming
--
-- A subscription video streaming service: a catalog of movies and series,
-- licensed per region for limited periods, accounts with profiles and
-- devices, plans whose prices change over time, monthly invoices, and a
-- large, partitioned log of viewing sessions.
--
-- PostgreSQL features shown here:
--   * temporal primary keys (WITHOUT OVERLAPS) and temporal foreign keys
--     (PERIOD), PostgreSQL 18: plan prices, license windows, subscriptions
--   * declarative range partitioning of viewing_session by month, with an
--     optional pg_partman setup (pg_partman-setup.sql)
--   * MERGE ... RETURNING merge_action() to keep watch progress up to date
--   * uuidv7() primary keys (PostgreSQL 18) for accounts
--   * window functions for "continue watching" and binge streaks
--   * full-text search over the catalog, and pg_trgm fuzzy title search
--   * JSONB device capabilities
--   * pgvector "more like this" recommendations with an HNSW index
--
-- Requires PostgreSQL 18+ and pgvector. Load with:
--   createdb streaming
--   psql -d streaming -f schema.sql
--   psql -d streaming -f generate-data.sql
--

SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TYPE title_kind AS ENUM ('movie', 'series');
CREATE TYPE maturity_rating AS ENUM ('TV-Y', 'TV-G', 'TV-PG', 'TV-14', 'TV-MA');
CREATE TYPE credit_role AS ENUM ('creator', 'director', 'writer', 'actor');
CREATE TYPE video_quality AS ENUM ('SD', 'HD', 'UHD');
CREATE TYPE device_kind AS ENUM ('tv', 'phone', 'tablet', 'browser', 'console');

--
-- Catalog
--

CREATE TABLE genre (
    genre_id smallint PRIMARY KEY,
    name text NOT NULL UNIQUE
);

CREATE TABLE person (
    person_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    birth_year smallint
);

CREATE TABLE title (
    title_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind title_kind NOT NULL,
    name text NOT NULL,
    original_language char(2) NOT NULL,
    release_year smallint NOT NULL,
    maturity maturity_rating NOT NULL,
    runtime_min smallint CHECK ((kind = 'movie') = (runtime_min IS NOT NULL)),
    synopsis text NOT NULL,
    added_at date NOT NULL,
    search tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', name), 'A') ||
        setweight(to_tsvector('english', synopsis), 'B')
    ) STORED
);

CREATE INDEX title_search_idx ON title USING gin (search);
CREATE INDEX title_name_trgm_idx ON title USING gin (name gin_trgm_ops);

CREATE TABLE title_genre (
    title_id integer NOT NULL REFERENCES title ON DELETE CASCADE,
    genre_id smallint NOT NULL REFERENCES genre,
    PRIMARY KEY (title_id, genre_id)
);

CREATE INDEX title_genre_genre_id_idx ON title_genre (genre_id);

CREATE TABLE season (
    season_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title_id integer NOT NULL REFERENCES title ON DELETE CASCADE,
    season_no smallint NOT NULL CHECK (season_no > 0),
    released_on date NOT NULL,
    UNIQUE (title_id, season_no),
    UNIQUE (season_id, title_id)    -- target of episode's composite key below
);

-- episode.title_id repeats the season's title so that viewing_session and
-- watch_progress can check that an episode belongs to the title they name,
-- with a plain composite foreign key. The composite key to season keeps the
-- copy right: it must match the season's title.
CREATE TABLE episode (
    episode_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    season_id integer NOT NULL,
    title_id integer NOT NULL,
    episode_no smallint NOT NULL CHECK (episode_no > 0),
    name text NOT NULL,
    runtime_min smallint NOT NULL,
    UNIQUE (season_id, episode_no),
    UNIQUE (episode_id, title_id),
    FOREIGN KEY (season_id, title_id) REFERENCES season (season_id, title_id) ON DELETE CASCADE
);

CREATE TABLE title_credit (
    title_id integer NOT NULL REFERENCES title ON DELETE CASCADE,
    person_id integer NOT NULL REFERENCES person,
    role credit_role NOT NULL,
    character_name text,
    billing_order smallint NOT NULL,
    PRIMARY KEY (title_id, person_id, role)
);

CREATE INDEX title_credit_person_id_idx ON title_credit (person_id);

-- title_embedding: a 24-dimension vector per title for "more like this".
-- Dimensions 1-16 are the title's genres (multi-hot), 17-20 encode kind,
-- maturity, release era and length, and 21-24 are a hidden "tone" that the
-- generator also uses to decide who likes what. Not a language-model
-- embedding, but built so that nearest neighbours make sense.
CREATE TABLE title_embedding (
    title_id integer PRIMARY KEY REFERENCES title ON DELETE CASCADE,
    embedding vector(24) NOT NULL
);

CREATE INDEX title_embedding_hnsw_idx ON title_embedding
    USING hnsw (embedding vector_cosine_ops);

--
-- Regions, licensing and plans
--

CREATE TABLE region (
    region_code char(2) PRIMARY KEY,
    name text NOT NULL,
    currency char(3) NOT NULL,
    timezone text NOT NULL
);

-- license_window: when a title may be streamed in a region. A title can
-- leave a region and come back later (two windows), but its windows can't
-- overlap.
CREATE TABLE license_window (
    title_id integer NOT NULL REFERENCES title ON DELETE CASCADE,
    region_code char(2) NOT NULL REFERENCES region,
    valid_at daterange NOT NULL,
    PRIMARY KEY (title_id, region_code, valid_at WITHOUT OVERLAPS)
);

CREATE TABLE plan (
    plan_id smallint PRIMARY KEY,
    name text NOT NULL UNIQUE,
    max_streams smallint NOT NULL,
    max_quality video_quality NOT NULL,
    has_ads boolean NOT NULL
);

-- plan_price: a plan's monthly price in one region, over time. Each price
-- change closes the old row's period and opens a new one.
CREATE TABLE plan_price (
    plan_id smallint NOT NULL REFERENCES plan,
    region_code char(2) NOT NULL REFERENCES region,
    valid_at daterange NOT NULL,
    monthly_price numeric(8,2) NOT NULL CHECK (monthly_price > 0),
    PRIMARY KEY (plan_id, region_code, valid_at WITHOUT OVERLAPS)
);

--
-- Accounts
--

-- account_id is a UUID version 7: random, but ordered by creation time, so
-- it indexes as well as a serial. uuid_extract_timestamp(account_id) gives
-- back the moment it was created.
CREATE TABLE account (
    account_id uuid PRIMARY KEY DEFAULT uuidv7(),
    email text NOT NULL UNIQUE,
    region_code char(2) NOT NULL REFERENCES region,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (account_id, region_code)    -- target of subscription's composite key
);

CREATE TABLE profile (
    profile_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES account ON DELETE CASCADE,
    name text NOT NULL,
    is_kids boolean NOT NULL DEFAULT false,
    language char(2) NOT NULL DEFAULT 'en',
    UNIQUE (account_id, name)
);

-- device.info holds whatever the app reports, which differs by platform:
--   {"os": "tvOS 18", "app_version": "9.4.1", "model": "...",
--    "screen": {"resolution": "2160p", "hdr": ["dolby_vision", "hdr10"]},
--    "codecs": ["av1", "hevc", "h264"]}
CREATE TABLE device (
    device_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES account ON DELETE CASCADE,
    kind device_kind NOT NULL,
    info jsonb NOT NULL DEFAULT '{}',
    first_seen timestamptz NOT NULL
);

CREATE INDEX device_account_id_idx ON device (account_id);
CREATE INDEX device_info_idx ON device USING gin (info);

-- subscription: which plan an account was on, and when. An account has at
-- most one plan at a time (WITHOUT OVERLAPS), and the temporal foreign key
-- requires that the plan had a price in the account's region for the whole
-- period: PERIOD valid_at must be covered by plan_price rows, even if it
-- spans several of them. The composite key to account makes region_code
-- the account's region; an account with subscriptions can't change region.
CREATE TABLE subscription (
    subscription_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id uuid NOT NULL,
    plan_id smallint NOT NULL,
    region_code char(2) NOT NULL,
    valid_at daterange NOT NULL,
    UNIQUE (account_id, valid_at WITHOUT OVERLAPS),
    FOREIGN KEY (account_id, region_code) REFERENCES account (account_id, region_code)
        ON DELETE CASCADE,
    FOREIGN KEY (plan_id, region_code, PERIOD valid_at)
        REFERENCES plan_price (plan_id, region_code, PERIOD valid_at)
);

CREATE TABLE invoice (
    invoice_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id integer NOT NULL REFERENCES subscription,
    period daterange NOT NULL,
    amount numeric(8,2) NOT NULL,
    currency char(3) NOT NULL,
    issued_at timestamptz NOT NULL,
    paid_at timestamptz
);

CREATE INDEX invoice_subscription_id_idx ON invoice (subscription_id);

--
-- Viewing
--

-- viewing_session: one row per playback session, the largest table by far.
-- It is range-partitioned by month on started_at, so queries over a period
-- only touch the matching partitions (partition pruning), and old months
-- can be detached or dropped cheaply. The primary key has to include the
-- partition key.
CREATE TABLE viewing_session (
    session_id bigint GENERATED ALWAYS AS IDENTITY,
    profile_id integer NOT NULL REFERENCES profile ON DELETE CASCADE,
    device_id integer NOT NULL REFERENCES device ON DELETE CASCADE,
    title_id integer NOT NULL REFERENCES title,
    episode_id integer,
    started_at timestamptz NOT NULL,
    ended_at timestamptz NOT NULL,
    position_from_s integer NOT NULL DEFAULT 0,
    position_to_s integer NOT NULL,
    quality video_quality NOT NULL,
    CHECK (ended_at > started_at),
    CHECK (position_to_s >= position_from_s),
    PRIMARY KEY (session_id, started_at),
    -- the episode, if any, must belong to title_id
    FOREIGN KEY (episode_id, title_id) REFERENCES episode (episode_id, title_id)
) PARTITION BY RANGE (started_at);

CREATE INDEX viewing_session_profile_idx ON viewing_session (profile_id, started_at);
CREATE INDEX viewing_session_title_idx ON viewing_session (title_id);

-- Monthly partitions from 2024-01 to 2027-12, a year past the generated
-- data. pg_partman-setup.sql can take over creating new ones from 2028-01.
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2024-01-01', date '2027-12-01', interval '1 month')::date
    LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF viewing_session FOR VALUES FROM (%L) TO (%L)',
            'viewing_session_p' || to_char(m, 'YYYYMMDD'),
            m::timestamp AT TIME ZONE 'UTC',
            (m + interval '1 month')::timestamp AT TIME ZONE 'UTC');
    END LOOP;
END
$$;

-- Rows past the last monthly partition land here instead of failing.
-- Keep it empty: attaching a new month fails if the default partition
-- already holds rows for that month.
CREATE TABLE viewing_session_default PARTITION OF viewing_session DEFAULT;

-- watch_progress: where each profile is in each title: the last episode and
-- position, for "continue watching". Kept up to date from viewing_session
-- with MERGE (see record_session() below).
CREATE TABLE watch_progress (
    profile_id integer NOT NULL REFERENCES profile ON DELETE CASCADE,
    title_id integer NOT NULL REFERENCES title,
    episode_id integer,
    position_s integer NOT NULL,
    finished boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL,
    PRIMARY KEY (profile_id, title_id),
    FOREIGN KEY (episode_id, title_id) REFERENCES episode (episode_id, title_id)
);

CREATE INDEX watch_progress_recent_idx ON watch_progress (profile_id, updated_at DESC)
    WHERE NOT finished;

-- rating: thumbs down (-1), up (1) or "love it" (2).
CREATE TABLE rating (
    profile_id integer NOT NULL REFERENCES profile ON DELETE CASCADE,
    title_id integer NOT NULL REFERENCES title,
    thumbs smallint NOT NULL CHECK (thumbs IN (-1, 1, 2)),
    rated_at timestamptz NOT NULL,
    PRIMARY KEY (profile_id, title_id)
);

CREATE INDEX rating_title_id_idx ON rating (title_id);

--
-- Functions and views
--

-- playable_runtime_s: the length of a movie, or of one episode, in seconds.
CREATE FUNCTION playable_runtime_s(p_title_id integer, p_episode_id integer)
RETURNS integer
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT 60 * coalesce(
        (SELECT e.runtime_min FROM episode e WHERE e.episode_id = p_episode_id),
        (SELECT t.runtime_min FROM title t WHERE t.title_id = p_title_id));
END;

-- record_session: log a playback session and fold it into watch_progress in
-- one MERGE. Returns 'INSERT' for a title the profile hadn't started yet,
-- 'UPDATE' otherwise. A session counts as finishing a title when it ends
-- within the last 5% of a movie, or of the series' final episode.
CREATE FUNCTION record_session(p_profile_id integer, p_device_id integer,
                               p_title_id integer, p_episode_id integer,
                               p_started_at timestamptz, p_ended_at timestamptz,
                               p_from_s integer, p_to_s integer,
                               p_quality video_quality)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_action text;
    v_last_episode integer;
BEGIN
    INSERT INTO viewing_session (profile_id, device_id, title_id, episode_id, started_at,
                                 ended_at, position_from_s, position_to_s, quality)
    VALUES (p_profile_id, p_device_id, p_title_id, p_episode_id, p_started_at,
            p_ended_at, p_from_s, p_to_s, p_quality);

    SELECT e.episode_id INTO v_last_episode
    FROM episode e JOIN season s USING (season_id)
    WHERE s.title_id = p_title_id
    ORDER BY s.season_no DESC, e.episode_no DESC
    LIMIT 1;

    MERGE INTO watch_progress w
    USING (SELECT p_profile_id AS profile_id, p_title_id AS title_id,
                  p_episode_id AS episode_id, p_to_s AS position_s, p_ended_at AS ended_at,
                  -- false, not NULL, for a series with no episodes yet
                  coalesce(p_to_s >= 0.95 * playable_runtime_s(p_title_id, p_episode_id)
                           AND p_episode_id IS NOT DISTINCT FROM v_last_episode,
                           false) AS finished) s
    ON w.profile_id = s.profile_id AND w.title_id = s.title_id
    WHEN MATCHED AND s.ended_at > w.updated_at THEN
        UPDATE SET episode_id = s.episode_id, position_s = s.position_s,
                   finished = s.finished, updated_at = s.ended_at
    WHEN NOT MATCHED THEN
        INSERT (profile_id, title_id, episode_id, position_s, finished, updated_at)
        VALUES (s.profile_id, s.title_id, s.episode_id, s.position_s, s.finished, s.ended_at)
    RETURNING merge_action() INTO v_action;

    RETURN coalesce(v_action, 'NONE');
END
$$;

-- available_titles: what can be streamed in a region on a given day.
CREATE FUNCTION available_titles(p_region char(2), p_day date)
RETURNS SETOF title
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT t.* FROM title t
    WHERE EXISTS (SELECT FROM license_window l
                  WHERE l.title_id = t.title_id
                    AND l.region_code = p_region
                    AND l.valid_at @> p_day);
END;

-- subscription_price: each subscription period split by the price periods
-- it spans, with the price that applied, by joining the two temporal
-- tables on overlapping ranges.
CREATE VIEW subscription_price AS
SELECT s.subscription_id, s.account_id, s.plan_id, s.region_code,
       s.valid_at * p.valid_at AS valid_at,
       p.monthly_price,
       r.currency
FROM subscription s
JOIN plan_price p ON p.plan_id = s.plan_id
                 AND p.region_code = s.region_code
                 AND p.valid_at && s.valid_at
JOIN region r ON r.region_code = s.region_code;
