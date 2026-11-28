-- Runs after osm2pgsql has filled places_new. Needs: psql -v osm_ts='<ISO timestamp>'
\set ON_ERROR_STOP on
SET search_path = places_new, public;

-- 1. Geography columns and indexes (osm2pgsql writes geometry, the MCP queries geography)
ALTER TABLE poi        ALTER COLUMN geom TYPE geography(Point, 4326) USING geom::geography;
ALTER TABLE settlement ALTER COLUMN geom TYPE geography(Point, 4326) USING geom::geography;
ALTER TABLE road       ALTER COLUMN geom TYPE geography USING geom::geography;
ALTER TABLE services   ALTER COLUMN geom TYPE geography USING geom::geography;
ALTER TABLE coverage   ALTER COLUMN geom TYPE geography(Geometry, 4326);

-- Ski lifts: one ski_lift place per lift at its bottom station (the line's start point;
-- OSM draws lifts uphill). The top station (the line's end point) goes into the tags as
-- top_lat/top_lon: the places server finds the highest point of a ski area from it.
-- The lift table is staging only.
INSERT INTO poi (osm_type, osm_id, type, name, tags, geom)
SELECT 'W', osm_id, 'ski_lift', name,
       coalesce(tags, '{}'::jsonb) || jsonb_build_object(
           'top_lat', round(ST_Y(ST_EndPoint(geom))::numeric, 5)::text,
           'top_lon', round(ST_X(ST_EndPoint(geom))::numeric, 5)::text),
       ST_StartPoint(geom)::geography
  FROM lift;
DROP TABLE lift;

-- Same object listed twice (overlapping extracts) -> keep one row
DELETE FROM poi a USING poi b
 WHERE a.ctid < b.ctid AND a.osm_type = b.osm_type AND a.osm_id = b.osm_id AND a.type = b.type;
DELETE FROM settlement a USING settlement b
 WHERE a.ctid < b.ctid AND a.osm_id = b.osm_id;

ALTER TABLE poi ADD PRIMARY KEY (osm_type, osm_id, type);
CREATE INDEX poi_geom_idx ON poi USING gist (geom);
CREATE INDEX poi_type_idx ON poi (type);
CREATE INDEX settlement_geom_idx ON settlement USING gist (geom);
-- Settlement names by their first letters (any case), for the places server's "did you mean" when a place name
-- is not found: lower(name) LIKE 'ara%'.
CREATE INDEX settlement_name_prefix_idx ON settlement (lower(name) text_pattern_ops);
CREATE INDEX road_geom_idx ON road USING gist (geom);
CREATE INDEX services_geom_idx ON services USING gist (geom);
ANALYZE road; ANALYZE services;

-- 2. Fuel stations on motorways / expressways (same rules as the Overpass code):
--    within 100 m of a services/rest area that itself lies within 250 m of a
--    motorway/expressway or its slip road (some city stations are wrongly mapped
--    as highway=services), or within 30 m of a carriageway.
DELETE FROM services s
 WHERE NOT EXISTS (SELECT 1 FROM road r WHERE ST_DWithin(r.geom, s.geom, 250));
UPDATE poi p
   SET tags = p.tags || '{"bste:motorway": "yes"}'
 WHERE p.type IN ('fuel', 'lpg')
   AND (EXISTS (SELECT 1 FROM services s WHERE ST_DWithin(s.geom, p.geom, 100))
     OR EXISTS (SELECT 1 FROM road r WHERE NOT r.link AND ST_DWithin(r.geom, p.geom, 30)));

DROP TABLE road;
DROP TABLE services;

-- 3. Coverage: one unioned row for the MCP's Covers() check
INSERT INTO coverage (country, geom)
SELECT 'ALL', ST_Union(geom::geometry)::geography FROM coverage;

-- 4. Meta
CREATE TABLE meta (imported_at timestamptz NOT NULL, osm_timestamp timestamptz NOT NULL);
INSERT INTO meta VALUES (now(), :'osm_ts');

ANALYZE poi; ANALYZE settlement; ANALYZE coverage;

-- Sanity check and swap: swap.sql (also used when restoring a dump built by CI).
