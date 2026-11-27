# places-import

Weekly import of motorhome places from OpenStreetMap into a PostGIS database: campsites, motorhome stopovers,
dump stations, drinking water, fuel and LPG stations, ski areas and lifts, for all of Europe. It feeds the places
server of [Halta](https://halta.camp), a motorhome assistant (the server itself is in a private repository).

Data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available under the Open Database
License (ODbL); extracts from [Geofabrik](https://download.geofabrik.de/).

**Where it runs:** the heavy part runs in **GitHub Actions** ([places-data.yml](.github/workflows/places-data.yml)),
not on the small server that uses the data: `osmium tags-filter` keeps a bitmap of node IDs that needs ~1.6 GB of
RAM for any extract (OSM node IDs go up to ~13 billion), more than that server can spare. The workflow imports into a
temporary PostGIS (same version as places-db), dumps the result and pushes it as the image
`ghcr.io/bste/halta-places-data`. The server only pulls that image and restores it (a few minutes, little
memory).

```
GitHub Actions (Saturday 01:00 UTC)                 Server (weekly job, Sunday)
download → filter → merge → osm2pgsql → post.sql    docker pull places-data
→ pg_dump places_new → image places-data     ──▶    restore.sh: pg_restore → swap.sql (check + swap)
```

## What the import does (import.sh)

1. Downloads the Geofabrik extracts in `REGIONS` (default: all of Europe, `europe`, about 30 GB) plus
   their `.poly` boundaries. A file is downloaded again only when Geofabrik has a newer one; a failed download is
   retried 6 times, a minute apart.
2. `osmium tags-filter` on each extract (keeps only what we use), then `osmium merge` of the small filtered files
   (removes objects that appear in two extracts). No temporary file as large as all extracts together.
3. `osm2pgsql` with `places.lua` into a fresh schema `places_new`.
4. `post.sql`:
   - converts geometries to `geography` and creates the indexes;
   - sets `bste:motorway=yes` on fuel stations within 250 m of `highway=services`/`rest_area` or 60 m of a
     motorway or trunk + `motorroad=yes` road (`places.lua` already sets `bste:truck_only=yes`);
   - writes `coverage` (one row per extract plus the unioned row `ALL`) and `meta` (import time, OSM data time).
5. `ski.sql` writes the public files `ski-areas.json` and `ski-lifts.json` (see [Ski-area file](#ski-area-file)) and the staging tables
   it needs (`ski_poly`, `country`, `lift_station`) are dropped. If it fails, the import goes on without the file.
6. `swap.sql` (skipped with `SKIP_SWAP=1`, as in CI, where the dump is taken from `places_new` instead):
   - **refuses to continue** if there are fewer than `MIN_POI` places, so a broken import never replaces good data;
   - swaps `places_new` → `places` in one transaction and grants `SELECT` to `mcp_ro` (if that role exists).

Tables after the import: `places.poi`, `places.settlement`, `places.coverage`, `places.meta` (and
`osm2pgsql_properties`, which the MCP ignores). An existing `places` schema is replaced completely.

Types in `poi.type`:

| type | OSM tags |
|---|---|
| `campsite` | `tourism=camp_site`, `tourism=caravan_site` |
| `motorhome_stop` | `tourism=caravan_site`; `amenity=parking` + `motorhome=designated/yes` |
| `dump_station` | `amenity=sanitary_dump_station`; `sanitary_dump_station=yes/customers` on any object (so campsites and stops with a dump station are included too; Overpass returns only `amenity=sanitary_dump_station`) |
| `water` | `amenity=drinking_water`, `amenity=water_point` |
| `fuel` | `amenity=fuel` |
| `lpg` | `amenity=fuel` + `fuel:lpg=yes` (the station is also in `fuel`) |
| `ski_area` | `landuse=winter_sports` |
| `ski_lift` | `aerialway=cable_car/gondola/mixed_lift/chair_lift/drag_lift/t-bar/j-bar/platter/rope_tow`, at the line's start point (the bottom station; staging table `lift`, turned into points by `post.sql`, which also stores the line's end point, the top station, in the tags `top_lat`/`top_lon`) |

Areas are stored as their centroid. Types, the truck-network list (`TRUCK_PATTERNS`), the motorway rule
(motorway, or trunk + `motorroad=yes`) and the settlement kinds (city, town, village, hamlet, suburb) match the
places server's Overpass queries (`internal/geo` in the private repository; comments in `places.lua` say which
part), so local and Overpass answers agree. **Change both together.**

## Ski-area file

`ski-areas.json` answers one question for all of Europe: **which ski areas have a motorhome stopover or campsite
within 2 km of a lift?** The weekly workflow publishes it as a release asset:

<https://github.com/bste/places-import/releases/download/data/ski-areas.json>

Every value is read from OpenStreetMap; nothing is estimated. Distances are straight-line, in km.

- **A ski area** is an outline tagged `landuse=winter_sports` with a name that holds at least 3 ski lifts (`minLifts`).
  Outlines with the same name within about 3 km of each other are one area. A lift belongs to the smallest
  outline that its bottom or top station lies in (or within 150 m of), so each lift is counted once.
- **A stay** is a campsite or motorhome stopover that a motorhome can use (not private, not for groups or scouts
  only, not tents only), within 2 km (`liftKm`) of the bottom station of one of the area's lifts.

| Field | |
|---|---|
| `osmDate` | date of the OpenStreetMap data |
| `totals` | `areas` (all ski areas), `withStay` (those with at least one stay), `withPower` (those with at least one stay tagged `power_supply`) |
| `countries` | the same three counts per country (ISO 3166-1 alpha-2) |
| `areas` | the areas with at least one stay, largest (most lifts) first |

Per area: `id` (the OSM object of its largest outline, e.g. `w123`), `name`, `country`, `near` (the nearest city,
town or village within 10 km), `lat`/`lon` (the middle of its lifts' bottom stations), `lifts`, `stays`, `stops`
(stays that are motorhome stopovers), `power` (stays with electricity), `nearest` and `nearestPower` (name, type, km
and the lift it is measured to), `dump` (the nearest dump station within 15 km of a lift; a public one before one
for guests only, marked `guests`), `lpg` (the nearest LPG station within 30 km that is not truck-only) and `topEle`
(the highest top station of the area's lifts, in metres, from the stations' `ele` tags; given only when at least
half of the lifts have one, never estimated).

**`ski-lifts.json`** (same place, `…/download/data/ski-lifts.json`) lists every ski area (also those without a
stay) with its lifts: `id`, `name`, `country`, and per lift its OSM way (`w123`), `name` and bottom station
(`lat`/`lon`). The halta.camp destination pages use it so that a page about one ski area counts only that area's
lifts, not those of a neighbouring one.

Use both freely under the ODbL: credit "© OpenStreetMap contributors".

## Configuration

| Variable | Default | |
|---|---|---|
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | – | Connection (needs rights to create schemas, e.g. the DB owner; **not** `mcp_ro`). |
| `REGIONS` | `europe` | Geofabrik paths, space-separated (see below); `europe` is the whole continent (~30 GB). |
| `MIN_POI` | `200000` | Minimum number of POI rows (import and restore); below it the old data is kept and the exit code is 3. Lower it for a small test region. |
| `MIN_POI_RATIO` | `0.8` | The new data must have at least this share of the places in use (so a half-broken import never replaces a good one); `0` turns it off, e.g. to shrink the region on purpose. |
| `DATA_DIR` | `/data` | Downloads and temporary files (keep it on a volume so unchanged extracts aren't re-downloaded). |
| `OSM2PGSQL_CACHE` | `256` | osm2pgsql node cache in MB (CI uses 4000). |
| `SKIP_SWAP` | – | `1`: leave the result in `places_new` (CI). |

## Restore the data

The workflow publishes the result as the image `ghcr.io/bste/halta-places-data`: the dump plus
`restore.sh`. Restore it into any PostGIS (the server needs little memory for this; the extracts are never
downloaded there):

```sh
docker pull ghcr.io/bste/halta-places-data:latest
docker run --rm --network <network of the database> --env-file places-import.env   ghcr.io/bste/halta-places-data:latest
```

`places-import.env` holds the connection (`PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`; keep it `chmod 600`).
`restore.sh` restores the dump into `places_new`, runs `swap.sql` (stops with the old data kept if there are fewer
than `MIN_POI` places or less than `MIN_POI_RATIO` of the places in use) and grants `mcp_ro` access. The log shows
when the data was built and for which regions. Run it weekly (e.g. Sunday; the data is built on Saturdays).

### Building the data

The workflow runs every Saturday, on every push to `main` that changes the import, and by hand
(GitHub → Actions → places-data → Run workflow, optionally with other regions). Its run summary shows the counts
per type, the regions and the dump size. The 3 newest data images are kept.

### Regions

The default is **all of Europe** (`europe`, one ~30 GB Geofabrik extract). The workflow keeps the download on the
runner's second disk (`/mnt`) and may run up to 5.5 hours. For a smaller area set the repository variable
**`PLACES_REGIONS`** (GitHub → Settings → Secrets and variables → Actions → Variables) or the `regions` input of a
manual run, e.g.

```
europe/slovenia europe/croatia europe/austria europe/italy europe/hungary
```

and lower `MIN_POI` for it (and set `MIN_POI_RATIO=0` on the restore once, since the new data is smaller on
purpose). The places server reads the imported area from the database (`places.coverage`), so nothing else changes.
Geofabrik's Italian sub-regions (`europe/italy/nord-est`, …) currently redirect to a broken URL (404); use
`europe/italy`.

Estimates (not measured): all of Europe ~30 GB of extracts, database ~2–4 GB, workflow ~1.5–3 h, restore
~30–60 min (the old data stays in use until the swap). The run summary shows the real numbers; check them after
the first run.

### Running the import elsewhere

The import image (`ghcr.io/bste/halta-places-import`, built by [places-import.yml](.github/workflows/places-import.yml))
can also run against any PostGIS on a machine with enough memory (2–3 GB free): `docker run` with that image, a
volume for `/data` and the variables above. Without `SKIP_SWAP=1` it checks and swaps itself.

## Check the result

```sql
SELECT type, count(*) FROM places.poi GROUP BY 1 ORDER BY 1;
SELECT * FROM places.meta;
SELECT country FROM places.coverage;
SELECT name, tags->>'bste:motorway' FROM places.poi WHERE type = 'fuel' AND tags ? 'bste:motorway' LIMIT 10;
```

## Test without downloading

```sh
LOCAL_PBF=/data/test.osm.pbf LOCAL_POLY=/data/slovenia.poly MIN_POI=1 /import/import.sh
```

Tested with osm2pgsql 1.11 and PostGIS on a small synthetic dataset: types, LPG, truck-only and motorway flags,
centroids of areas, settlements, coverage, re-import swap, the `MIN_POI` safety stop and `mcp_ro` access.
Not yet run on the real Geofabrik extracts.

## Repository

The images are `ghcr.io/bste/halta-places-data` and `ghcr.io/bste/halta-places-import` (until November 2026
`mcp.bste.si-places-data` and `mcp.bste.si-places-import`). This repository is public so that the weekly import
(about 25 minutes for all of Europe) runs on GitHub's free minutes; it contains no secrets (the workflows use only
`GITHUB_TOKEN`).
