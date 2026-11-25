--
-- pagila-ng: micromobility -- optional pg_partman setup
--
-- Hands future monthly partitions of vehicle_status over to pg_partman.
-- schema.sql already creates partitions through 2026-12, so pg_partman is
-- told to start at 2027-01 and leave those alone. From then on it keeps
-- p_premake (4) months of partitions ahead, as long as maintenance runs
-- regularly, for example from cron:
--
--   psql -d micromobility -c "CALL partman.run_maintenance_proc()"
--
-- Requires pg_partman 5.x (postgresql-18-partman on apt, pg_partman_18 on
-- dnf). Run after schema.sql:
--   psql -d micromobility -f pg_partman-setup.sql
--

CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

SELECT partman.create_parent(
    p_parent_table    := 'public.vehicle_status',
    p_control         := 'reported_at',
    p_interval        := '1 month',
    p_type            := 'range',
    p_start_partition := '2027-01-01 00:00:00+00'
);
