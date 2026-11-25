--
-- pg_fil: ev-charging -- optional pg_partman setup
--
-- Hands future monthly partitions of meter_value over to pg_partman.
-- schema.sql already creates partitions through 2027-12, so pg_partman is
-- told to start at 2028-01 and leave those alone, and to keep the default
-- partition schema.sql made (p_default_table := false). From then on it
-- keeps p_premake (4) months of partitions ahead, as long as maintenance
-- runs regularly: from the pg_partman_bgw background worker (the Docker
-- image runs it), or for example from cron:
--
--   PGTZ=UTC psql -d ev-charging -c "CALL partman.run_maintenance_proc()"
--
-- Requires pg_partman 5.x (postgresql-19-partman on apt, pg_partman_19 on
-- dnf). Run after schema.sql:
--   psql -d ev-charging -f pg_partman-setup.sql
--

-- pg_partman works out month boundaries in the session time zone, while
-- schema.sql's partitions start at midnight UTC. Anything else would
-- make the new partitions overlap the existing ones, so use UTC here,
-- and in whatever runs maintenance (hence PGTZ=UTC above).
SET TIME ZONE 'UTC';

CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

SELECT partman.create_parent(
    p_parent_table    := 'public.meter_value',
    p_control         := 'measured_at',
    p_interval        := '1 month',
    p_type            := 'range',
    p_start_partition := '2028-01-01 00:00:00+00',
    p_default_table   := false
);
