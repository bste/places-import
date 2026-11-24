-- Sanity check and swap of places_new -> places. Used after an import (import.sh)
-- and after restoring a dump built by CI (restore.sh). Needs: psql -v min_poi=<n> -v min_ratio=<0..1>
\set ON_ERROR_STOP on
SET search_path = places_new, public;

-- 1. Sanity check: never replace good data with a broken import. Absolute
--    minimum (min_poi), and relative to the data in use (min_ratio, e.g. 0.8:
--    the new import must have at least 80 % of the current places; 0 = off).
SELECT set_config('bste.min_poi', :'min_poi', false);
SELECT set_config('bste.min_ratio', :'min_ratio', false);
DO $$
DECLARE n bigint; current_n bigint; ratio numeric;
BEGIN
  SELECT count(*) INTO n FROM poi;
  IF n < current_setting('bste.min_poi')::bigint THEN
    RAISE EXCEPTION 'import has only % POIs (minimum %): keeping the old data',
      n, current_setting('bste.min_poi');
  END IF;
  ratio := current_setting('bste.min_ratio')::numeric;
  IF ratio > 0 AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'places') THEN
    EXECUTE 'SELECT count(*) FROM places.poi' INTO current_n;
    IF n < current_n * ratio THEN
      RAISE EXCEPTION 'import has % POIs, less than % of the % in use (MIN_POI_RATIO): keeping the old data',
        n, ratio, current_n;
    END IF;
  END IF;
END $$;
SELECT type, count(*) FROM poi GROUP BY type ORDER BY type;

-- 2. Swap places_new -> places in one transaction
BEGIN;
DROP SCHEMA IF EXISTS places_old CASCADE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'places') THEN
    ALTER SCHEMA places RENAME TO places_old;
  END IF;
END $$;
ALTER SCHEMA places_new RENAME TO places;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mcp_ro') THEN
    GRANT USAGE ON SCHEMA places TO mcp_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA places TO mcp_ro;
  END IF;
END $$;
COMMIT;
DROP SCHEMA IF EXISTS places_old CASCADE;
