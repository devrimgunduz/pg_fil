#!/bin/bash
# Load <db>'s schema.sql into a scratch database, run generate-data.sql and
# then queries.sql, stopping at the first error. Uses the PG* environment
# variables for the connection, as psql does.
#
#   scripts/check.sh stays
#   SCALE=3 scripts/check.sh stays
set -euo pipefail

db=${1:?usage: $0 <database directory>}
scale=${SCALE:-1}
root=$(cd "$(dirname "$0")/.." && pwd)
tmp="pg_fil_check_${db//-/_}"

dropdb --if-exists "$tmp"
createdb "$tmp"
psql -X -q -v ON_ERROR_STOP=1 -d "$tmp" -f "$root/$db/schema.sql"
time psql -X -q -v ON_ERROR_STOP=1 -v scale="$scale" -d "$tmp" -f "$root/$db/generate-data.sql"
psql -X -q -v ON_ERROR_STOP=1 -d "$tmp" -c "VACUUM ANALYZE"
psql -X -v ON_ERROR_STOP=1 -d "$tmp" -f "$root/$db/queries.sql" > "${TMPDIR:-/tmp}/pg_fil-$db-queries.out"
[ -n "${KEEP:-}" ] || dropdb "$tmp"
echo "$db: OK"
