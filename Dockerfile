FROM docker.io/library/postgres:19

# PostGIS, pgvector and pg_partman all come straight from the PGDG apt repo,
# which the official postgres image already has configured.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-19-postgis-3 \
        postgresql-19-pgvector \
        postgresql-19-partman; \
    rm -rf /var/lib/apt/lists/*

# pg_partman_bgw runs partition maintenance hourly in the three databases
# with a pg_partman setup, so new monthly partitions keep being created.
# It runs as pg_partman_bgw.role; the default, partman_maintainer, doesn't
# exist in this image. The image's time zone is UTC, which pg_partman needs
# to line up with schema.sql's partitions.
CMD ["postgres", \
     "-c", "shared_preload_libraries=pg_partman_bgw", \
     "-c", "pg_partman_bgw.dbname=streaming,ev-charging,micromobility", \
     "-c", "pg_partman_bgw.role=postgres", \
     "-c", "pg_partman_bgw.interval=3600"]
