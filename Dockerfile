FROM docker.io/library/postgres:18

# PostGIS, pgvector and pg_partman all come straight from the PGDG apt repo,
# which the official postgres image already has configured.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-18-postgis-3 \
        postgresql-18-pgvector \
        postgresql-18-partman; \
    rm -rf /var/lib/apt/lists/*
