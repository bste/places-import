#!/bin/sh
# Restores the places dump built by CI (.github/workflows/places-data.yml) into
# places_new, checks it and swaps it into places in one transaction.
# Connection: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (same env file as
# the import). Needs little memory: the heavy work happened in CI.
set -eu

MIN_POI=${MIN_POI:-200000}
# The new data must have at least this share of the places in use (0 = off).
MIN_POI_RATIO=${MIN_POI_RATIO:-0.8}
DUMP=/restore/places.dump

log() { echo "$(date -u +%FT%TZ) $*"; }

log "data built $(cat /restore/BUILT 2>/dev/null || echo '?') for: $(cat /restore/REGIONS 2>/dev/null || echo '?')"
log "prepare"
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
DROP SCHEMA IF EXISTS places_new CASCADE;
SQL

log "restore into places_new"
pg_restore --no-owner --no-privileges --exit-on-error -d "${PGDATABASE:?PGDATABASE is required}" "$DUMP"

log "sanity check and swap"
psql -X -q -v ON_ERROR_STOP=1 -v min_poi="$MIN_POI" -v min_ratio="$MIN_POI_RATIO" -f /restore/swap.sql

psql -X -q -v ON_ERROR_STOP=1 -c "SELECT imported_at, osm_timestamp FROM places.meta"
log "done"
