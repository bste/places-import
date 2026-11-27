-- The public ski-area file (ski-areas.json): which ski areas have a motorhome stopover or
-- campsite near a lift. Runs after post.sql and prints one JSON document (psql -q -At).
-- Every value is read from OpenStreetMap; nothing is estimated. Distances are straight-line.
--
-- A ski area here is: outlines tagged landuse=winter_sports with a name (pieces with the same
-- name within about 3 km of each other count as one area) that hold at least :min_lifts ski
-- lifts. A lift belongs to the smallest outline that its bottom or top station lies in (or
-- within 150 m of), so a lift is counted once even where outlines overlap.
--
-- Needs the staging tables ski_poly, country and lift_station (places.lua); import.sh drops them.
\set ON_ERROR_STOP on
\set min_lifts 3
\set lift_m 2000
\set dump_m 15000
\set lpg_m 30000
SET search_path = places_new, public;
SET client_min_messages = warning;

-- 1. Outlines
CREATE TEMP TABLE piece AS
SELECT DISTINCT ON (osm_type, osm_id)
       lower(osm_type) || osm_id AS id, btrim(name) AS name, ST_MakeValid(geom) AS geom
  FROM ski_poly
 ORDER BY osm_type, osm_id;

CREATE TEMP TABLE part AS
SELECT id, name, lower(name) AS key,
       ST_ClusterDBSCAN(geom, 0.03, 1) OVER (PARTITION BY lower(name)) AS cl,
       geom::geography AS g, ST_Area(geom::geography) AS m2
  FROM piece
 WHERE NOT ST_IsEmpty(geom);
CREATE INDEX ON part USING gist (g);
ANALYZE part;

-- 2. Lifts: bottom station (the place's point) and top station (top_lat/top_lon, see post.sql)
CREATE TEMP TABLE sl AS
SELECT osm_id, name, geom AS bottom,
       ST_SetSRID(ST_MakePoint((tags->>'top_lon')::float8, (tags->>'top_lat')::float8), 4326)::geography AS top
  FROM poi
 WHERE type = 'ski_lift';
CREATE INDEX ON sl USING gist (bottom);
CREATE INDEX ON sl USING gist (top);
ANALYZE sl;

CREATE TEMP TABLE area_lift AS
WITH m AS (
    SELECT l.osm_id, p.key, p.cl, p.m2 FROM sl l JOIN part p ON ST_DWithin(p.g, l.bottom, 150)
    UNION ALL
    SELECT l.osm_id, p.key, p.cl, p.m2 FROM sl l JOIN part p ON ST_DWithin(p.g, l.top, 150)
)
SELECT DISTINCT ON (osm_id) osm_id, key, cl
  FROM m
 ORDER BY osm_id, m2, key, cl;

-- 3. Areas with enough lifts; the name and id come from the largest piece
CREATE TEMP TABLE area AS
SELECT a.key, a.cl, count(*) AS lifts,
       ST_Centroid(ST_Collect(l.bottom::geometry)) AS centre
  FROM area_lift a JOIN sl l USING (osm_id)
 GROUP BY a.key, a.cl
HAVING count(*) >= :min_lifts;
ALTER TABLE area ADD COLUMN id text, ADD COLUMN name text, ADD COLUMN country text,
                 ADD COLUMN near text, ADD COLUMN top_ele int;
UPDATE area a SET (id, name) = (
    SELECT p.id, p.name FROM part p
     WHERE p.key = a.key AND p.cl = a.cl
     ORDER BY p.m2 DESC, p.id LIMIT 1);

-- The lifts of those areas
CREATE TEMP TABLE al AS
SELECT a.key, a.cl, l.osm_id, l.name, l.bottom, l.top
  FROM area a JOIN area_lift x USING (key, cl) JOIN sl l USING (osm_id);
CREATE INDEX ON al USING gist (bottom);
ANALYZE al;

-- Country (borders cut into small parts, so the point test is fast)
CREATE TEMP TABLE cpart AS
SELECT code, ST_Subdivide(ST_MakeValid(geom), 256) AS geom FROM country;
CREATE INDEX ON cpart USING gist (geom);
ANALYZE cpart;
UPDATE area a SET country = (
    SELECT c.code FROM cpart c WHERE ST_Intersects(c.geom, a.centre) ORDER BY c.code LIMIT 1);

-- The nearest town or village to the middle of the lifts
UPDATE area a SET near = (
    SELECT s.name FROM settlement s
     WHERE s.place IN ('city', 'town', 'village') AND ST_DWithin(s.geom, a.centre::geography, 10000)
     ORDER BY s.geom <-> a.centre::geography LIMIT 1);

-- The highest top station, only where OpenStreetMap has a height (ele) for the top station of at
-- least half of the area's lifts: with fewer, the highest known one says little about the area.
CREATE TEMP TABLE stn AS
SELECT DISTINCT ON (osm_type, osm_id) ele, geom::geography AS g FROM lift_station ORDER BY osm_type, osm_id;
CREATE INDEX ON stn USING gist (g);
ANALYZE stn;
UPDATE area a SET top_ele = (
    SELECT CASE WHEN count(e.ele) * 2 >= count(*) THEN round(max(e.ele))::int END
      FROM al l LEFT JOIN LATERAL (
            SELECT max(s.ele) AS ele FROM stn s WHERE ST_DWithin(s.g, l.top, 80)) e ON true
     WHERE l.key = a.key AND l.cl = a.cl);

-- 4. Stopovers and campsites a motorhome can use (the places server's rules: not private, not
--    for groups or scouts only, not tents only). One row per object; a caravan site is a stopover.
CREATE TEMP TABLE stay AS
SELECT DISTINCT ON (osm_type, osm_id) osm_type, osm_id, name, geom,
       bool_or(type = 'motorhome_stop') OVER (PARTITION BY osm_type, osm_id) AS stop,
       coalesce(nullif(tags->>'power_supply', ''), 'no') <> 'no' AS power
  FROM poi p
 WHERE type IN ('campsite', 'motorhome_stop')
   AND coalesce(tags->>'access', '') NOT IN ('private', 'no')
   AND NOT coalesce(tags->>'tourism' IN ('camp_site', 'caravan_site') AND (
           tags->>'group_only' = 'yes' OR tags->>'scout' = 'yes' OR tags->>'motorhome' = 'no'
           OR (tags->>'caravans' = 'no' AND coalesce(tags->>'motorhome', '') NOT IN ('yes', 'designated'))), false)
 ORDER BY osm_type, osm_id;
CREATE INDEX ON stay USING gist (geom);
ANALYZE stay;

-- Each stay within :lift_m of a lift of the area, with its nearest lift
CREATE TEMP TABLE near_stay AS
SELECT DISTINCT ON (l.key, l.cl, s.osm_type, s.osm_id)
       l.key, l.cl, s.name, s.stop, s.power, ST_Distance(s.geom, l.bottom) AS m, l.name AS lift
  FROM al l JOIN stay s ON ST_DWithin(s.geom, l.bottom, :lift_m)
 ORDER BY l.key, l.cl, s.osm_type, s.osm_id, ST_Distance(s.geom, l.bottom);

-- 5. The nearest dump station (a public one before a guests-only one) and LPG station (not a
--    truck-only one) to any lift of the area
CREATE TEMP TABLE near_dump AS
SELECT DISTINCT ON (l.key, l.cl) l.key, l.cl, d.name, d.m, d.guests
  FROM al l CROSS JOIN LATERAL (
        SELECT p.name, ST_Distance(p.geom, l.bottom) AS m,
               coalesce(p.tags->>'access', '') = 'customers' AS guests
          FROM poi p
         WHERE p.type = 'dump_station' AND ST_DWithin(p.geom, l.bottom, :dump_m)
         ORDER BY 3, 2 LIMIT 1) d
 ORDER BY l.key, l.cl, d.guests, d.m;

CREATE TEMP TABLE near_lpg AS
SELECT DISTINCT ON (l.key, l.cl) l.key, l.cl, d.name, d.m
  FROM al l CROSS JOIN LATERAL (
        SELECT coalesce(p.name, p.tags->>'brand') AS name, ST_Distance(p.geom, l.bottom) AS m
          FROM poi p
         WHERE p.type = 'lpg' AND ST_DWithin(p.geom, l.bottom, :lpg_m)
           AND coalesce(p.tags->>'bste:truck_only', '') <> 'yes'
         ORDER BY p.geom <-> l.bottom LIMIT 1) d
 ORDER BY l.key, l.cl, d.m;

-- 6. One row per area
CREATE TEMP TABLE result AS
SELECT a.*,
       coalesce(n.stays, 0) AS stays, coalesce(n.stops, 0) AS stops, coalesce(n.power, 0) AS power,
       (SELECT jsonb_strip_nulls(jsonb_build_object(
                   'name', s.name, 'type', CASE WHEN s.stop THEN 'motorhome_stop' ELSE 'campsite' END,
                   'km', round((s.m / 1000)::numeric, 1), 'power', s.power OR NULL, 'lift', s.lift))
          FROM near_stay s WHERE s.key = a.key AND s.cl = a.cl
         ORDER BY s.m, s.name LIMIT 1) AS nearest,
       (SELECT jsonb_strip_nulls(jsonb_build_object(
                   'name', s.name, 'type', CASE WHEN s.stop THEN 'motorhome_stop' ELSE 'campsite' END,
                   'km', round((s.m / 1000)::numeric, 1), 'lift', s.lift))
          FROM near_stay s WHERE s.key = a.key AND s.cl = a.cl AND s.power
         ORDER BY s.m, s.name LIMIT 1) AS nearest_power,
       (SELECT jsonb_strip_nulls(jsonb_build_object(
                   'name', d.name, 'km', round((d.m / 1000)::numeric, 1), 'guests', d.guests OR NULL))
          FROM near_dump d WHERE d.key = a.key AND d.cl = a.cl) AS dump,
       (SELECT jsonb_strip_nulls(jsonb_build_object('name', d.name, 'km', round((d.m / 1000)::numeric, 1)))
          FROM near_lpg d WHERE d.key = a.key AND d.cl = a.cl) AS lpg
  FROM area a
  LEFT JOIN (SELECT key, cl, count(*) AS stays, count(*) FILTER (WHERE stop) AS stops,
                    count(*) FILTER (WHERE power) AS power
               FROM near_stay GROUP BY key, cl) n USING (key, cl);

-- 7. The document. The list holds only the areas with a stopover or campsite by a lift; the
--    totals count every area.
SELECT jsonb_build_object(
    'source', 'OpenStreetMap',
    'attribution', '© OpenStreetMap contributors (ODbL)',
    'osmDate', (SELECT to_char(osm_timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD') FROM meta LIMIT 1),
    'minLifts', :min_lifts,
    'liftKm', round(:lift_m / 1000.0, 1),
    'totals', (SELECT jsonb_build_object(
                   'areas', count(*), 'withStay', count(*) FILTER (WHERE stays > 0),
                   'withPower', count(*) FILTER (WHERE power > 0)) FROM result),
    'countries', (SELECT coalesce(jsonb_agg(c ORDER BY c->>'country'), '[]') FROM (
                   SELECT jsonb_build_object(
                              'country', country, 'areas', count(*),
                              'withStay', count(*) FILTER (WHERE stays > 0),
                              'withPower', count(*) FILTER (WHERE power > 0)) AS c
                     FROM result WHERE country IS NOT NULL GROUP BY country) x),
    'areas', (SELECT coalesce(jsonb_agg(r ORDER BY (r->>'lifts')::int DESC, r->>'name', r->>'id'), '[]') FROM (
                   SELECT jsonb_strip_nulls(jsonb_build_object(
                              'id', id, 'name', name, 'country', country, 'near', near,
                              'lat', round(ST_Y(centre)::numeric, 4), 'lon', round(ST_X(centre)::numeric, 4),
                              'lifts', lifts, 'topEle', top_ele,
                              'stays', stays, 'stops', stops, 'power', power,
                              'nearest', nearest, 'nearestPower', nearest_power,
                              'dump', dump, 'lpg', lpg)) AS r
                     FROM result WHERE stays > 0) y)
)::text;
