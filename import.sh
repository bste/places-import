#!/usr/bin/env bash
# Weekly import of motorhome places from OpenStreetMap (Geofabrik extracts) into PostGIS.
# Connection: standard libpq variables PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE.
set -euo pipefail

DATA_DIR=${DATA_DIR:-/data}
REGIONS=${REGIONS:-"europe"}
MIN_POI=${MIN_POI:-200000}
# The new import must have at least this share of the places in use (0 = off).
MIN_POI_RATIO=${MIN_POI_RATIO:-0.8}
STYLE_DIR=${STYLE_DIR:-/import}
BASE=https://download.geofabrik.de
UA="bste-places-import/1.0"

log() { echo "$(date -u +%FT%TZ) $*"; }

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

pbfs=()
polys=()
if [[ -n "${LOCAL_PBF:-}" ]]; then
  # Testing: use a given .pbf/.osm and .poly instead of downloading
  pbfs=("$LOCAL_PBF")
  polys=("${LOCAL_POLY:?LOCAL_POLY is required with LOCAL_PBF}")
else
  for region in $REGIONS; do
    name=${region##*/}
    for f in "$name-latest.osm.pbf" "$name.poly"; do
      url="$BASE/${region%/*}/$f"
      [[ "$region" == */* ]] || url="$BASE/$f"
      cond=()
      [[ -f "$f" ]] && cond=(-z "$f")   # download only when Geofabrik has a newer file
      log "download $url"
      # -R keeps the server's time on the file, so -z compares against Geofabrik's date.
      # Retries: a short outage (connection refused, 5xx) must not end a multi-hour run.
      curl -fsSL -R -A "$UA" --retry 6 --retry-delay 60 --retry-all-errors --connect-timeout 30         "${cond[@]}" -o "$f.part" "$url"
      if [[ -s "$f.part" ]]; then mv "$f.part" "$f"; else rm -f "$f.part"; fi
    done
    pbfs+=("$name-latest.osm.pbf")
    polys+=("$name.poly")
  done
fi

# Oldest data timestamp of all extracts = how fresh the database is
osm_ts=""
for f in "${pbfs[@]}"; do
  ts=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$f" 2>/dev/null || true)
  [[ -z "$ts" ]] && ts=$(date -u -r "$f" +%FT%TZ)
  if [[ -z "$osm_ts" || "$ts" < "$osm_ts" ]]; then osm_ts=$ts; fi
done
log "OSM data timestamp: $osm_ts"

# Filter each extract first, then merge the small results: no temporary file
# as large as all extracts together, and each extract is read only once.
# Geofabrik extracts contain complete ways, so filtering before the merge loses
# nothing; merge drops the objects that are in two extracts.
filtered=()
for f in "${pbfs[@]}"; do
  out="${f%%.osm.pbf}.filtered.osm.pbf"
  out="${out##*/}"
  log "filter $f"
  osmium tags-filter "$f" \
    nwr/tourism=camp_site,caravan_site \
    nwr/amenity=sanitary_dump_station,drinking_water,water_point,fuel \
    nwr/sanitary_dump_station=yes,customers \
    nwr/motorhome=yes,designated \
    n/place=city,town,village,hamlet,suburb \
    w/highway=motorway \
    w/motorroad=yes \
    nwr/highway=services,rest_area \
    nwr/landuse=winter_sports \
    w/aerialway=cable_car,gondola,mixed_lift,chair_lift,drag_lift,t-bar,j-bar,platter,rope_tow \
    -o "$out" --overwrite
  filtered+=("$out")
done

log "merge ${#filtered[@]} filtered extract(s)"
osmium merge "${filtered[@]}" -o filtered.osm.pbf --overwrite
rm -f "${filtered[@]}"

log "prepare schema places_new"
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
DROP SCHEMA IF EXISTS places_new CASCADE;
CREATE SCHEMA places_new;
SQL

log "osm2pgsql"
# The filtered file is small; a bounded cache keeps memory low on a small server.
osm2pgsql --create --output=flex --style="$STYLE_DIR/places.lua" --schema=places_new \
  --cache="${OSM2PGSQL_CACHE:-256}" --number-processes=2 --log-level=warn filtered.osm.pbf

log "coverage"
python3 "$STYLE_DIR/poly2sql.py" "${polys[@]}" > coverage.sql
psql -X -q -v ON_ERROR_STOP=1 -f coverage.sql

log "post-processing"
psql -X -q -v ON_ERROR_STOP=1 -v osm_ts="$osm_ts" -f "$STYLE_DIR/post.sql"

if [[ "${SKIP_SWAP:-}" == "1" ]]; then
  # CI: leave the result in places_new for pg_dump (see .github/workflows/places-data.yml)
  psql -X -q -v ON_ERROR_STOP=1 -c "SELECT type, count(*) FROM places_new.poi GROUP BY 1 ORDER BY 1"
  n=$(psql -X -At -c "SELECT count(*) FROM places_new.poi")
  if (( n < MIN_POI )); then
    log "only $n POIs (minimum $MIN_POI): broken import"
    exit 3
  fi
else
  log "sanity check and swap"
  psql -X -q -v ON_ERROR_STOP=1 -v min_poi="$MIN_POI" -v min_ratio="$MIN_POI_RATIO" -f "$STYLE_DIR/swap.sql"
fi

rm -f filtered.osm.pbf coverage.sql
log "done"
