#!/bin/bash
# Runs once from /docker-entrypoint-initdb.d on the first container start:
# creates every pagila-ng database, loads its schema, runs its data
# generator and, where there is one, its pg_partman setup.
set -euo pipefail

for db in streaming stays ev-charging ticketing micromobility; do
    echo "pagila-ng: loading ${db}"
    createdb -U "$POSTGRES_USER" "$db"
    psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -f "/pagila-ng/${db}/schema.sql"
    psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -f "/pagila-ng/${db}/generate-data.sql"
    if [ -f "/pagila-ng/${db}/pg_partman-setup.sql" ]; then
        psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -f "/pagila-ng/${db}/pg_partman-setup.sql"
    fi
    psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -c "VACUUM ANALYZE"
done
