-- osm2pgsql flex style for the bste places database.
-- Works with osm2pgsql 1.9+ and 2.x. Tables go to the schema given with --schema (places_new).
--
-- poi        one row per (object, type); an object can have several types (e.g. fuel + lpg)
-- settlement city / town / village / hamlet / suburb nodes, for the "near" field
-- road       motorways and expressways (trunk + motorroad=yes) and their slip roads (link=true);
--            staging only, dropped by post.sql
--
-- Types and flags follow the places server's Overpass code (internal/geo in the private repo: PlaceFilters, stations.go),
-- so local and Overpass answers match.
-- services   highway=services / rest_area; staging only, dropped by post.sql
-- lift       ski lifts (aerialway lines); staging only: post.sql turns each into a ski_lift poi at
--            its start point, the bottom station (OSM draws lifts uphill)

local tables = {}

tables.poi = osm2pgsql.define_table({
    name = 'poi',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'type', type = 'text', not_null = true },
        { column = 'name', type = 'text' },
        { column = 'tags', type = 'jsonb' },
        { column = 'geom', type = 'point', projection = 4326, not_null = true },
    },
    indexes = {},
})

tables.settlement = osm2pgsql.define_table({
    name = 'settlement',
    ids = { type = 'node', id_column = 'osm_id' },
    columns = {
        { column = 'name', type = 'text', not_null = true },
        { column = 'place', type = 'text', not_null = true },
        { column = 'population', type = 'int4' },
        { column = 'geom', type = 'point', projection = 4326, not_null = true },
    },
    indexes = {},
})

tables.road = osm2pgsql.define_table({
    name = 'road',
    ids = { type = 'way', id_column = 'osm_id' },
    columns = {
        { column = 'link', type = 'bool', not_null = true },
        { column = 'geom', type = 'linestring', projection = 4326, not_null = true },
    },
    indexes = {},
})

tables.services = osm2pgsql.define_table({
    name = 'services',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'geom', type = 'geometry', projection = 4326, not_null = true },
    },
    indexes = {},
})

tables.lift = osm2pgsql.define_table({
    name = 'lift',
    ids = { type = 'way', id_column = 'osm_id' },
    columns = {
        { column = 'name', type = 'text' },
        { column = 'tags', type = 'jsonb' },
        { column = 'geom', type = 'linestring', projection = 4326, not_null = true },
    },
    indexes = {},
})

-- Lifts that carry skiers up (keep in sync with liftTypes in internal/geo/overpass.go);
-- not zip lines, goods lifts or magic carpets.
local LIFT = {
    cable_car = true, gondola = true, mixed_lift = true, chair_lift = true, drag_lift = true,
    ['t-bar'] = true, ['j-bar'] = true, platter = true, rope_tow = true,
}

-- Keep in sync with reTruckOnly in internal/geo/stations.go:
--   \bAS ?24\b | tankpool ?24 | \bIDS\b | truck ?only | nur lkw
-- (Lua patterns; %f[...] is a word boundary.)
local TRUCK_PATTERNS = {
    '%f[%w]as ?24%f[%W]', 'tankpool ?24', '%f[%w]ids%f[%W]', 'truck ?only', 'nur lkw',
}

-- Same as the Overpass "near" lookup in internal/geo/placeinfo.go.
local SETTLEMENT = { city = true, town = true, village = true, hamlet = true, suburb = true }

local function add(list, value)
    for _, v in ipairs(list) do
        if v == value then return end
    end
    list[#list + 1] = value
end

local function poi_types(tags)
    local t = {}
    if tags.tourism == 'camp_site' then add(t, 'campsite') end
    if tags.tourism == 'caravan_site' then
        -- Overpass returns caravan sites for both types
        add(t, 'campsite')
        add(t, 'motorhome_stop')
    end
    if tags.amenity == 'parking' and (tags.motorhome == 'designated' or tags.motorhome == 'yes') then
        add(t, 'motorhome_stop')
    end
    if tags.amenity == 'sanitary_dump_station'
        or tags.sanitary_dump_station == 'yes' or tags.sanitary_dump_station == 'customers' then
        add(t, 'dump_station')
    end
    if tags.amenity == 'drinking_water' or tags.amenity == 'water_point' then add(t, 'water') end
    -- Water for a motorhome tank also at dump stations, caravan sites, campsites
    -- and camper stops with drinking water (same as the Overpass filters).
    if tags.drinking_water == 'yes' or tags.water_point == 'yes' then
        if tags.amenity == 'sanitary_dump_station' or tags.tourism == 'caravan_site' or tags.tourism == 'camp_site'
            or (tags.amenity == 'parking' and (tags.motorhome == 'designated' or tags.motorhome == 'yes')) then
            add(t, 'water')
        end
    end
    if tags.landuse == 'winter_sports' then add(t, 'ski_area') end
    if tags.amenity == 'fuel' then
        add(t, 'fuel')
        if tags['fuel:lpg'] == 'yes' then add(t, 'lpg') end
    end
    return t
end

local function truck_only(tags)
    if tags.amenity ~= 'fuel' then return false end
    if tags.motorcar == 'no' then return true end
    local s = ' ' .. ((tags.brand or '') .. ' ' .. (tags.name or '') .. ' ' .. (tags.operator or '')):lower() .. ' '
    for _, p in ipairs(TRUCK_PATTERNS) do
        if s:find(p) then return true end
    end
    return false
end

local function insert_poi(object, types, geom)
    -- The public can't use private places (the MCP filters them too).
    if object.tags.access == 'private' or object.tags.access == 'no' then return end
    local tags = {}
    for k, v in pairs(object.tags) do tags[k] = v end
    if truck_only(tags) then tags['bste:truck_only'] = 'yes' end
    for _, t in ipairs(types) do
        tables.poi:insert({ type = t, name = object.tags.name, tags = tags, geom = geom })
    end
end

local function parse_population(value)
    if not value then return nil end
    local digits = value:gsub('[%s,%.]', '')
    local n = tonumber(digits)
    if n and n >= 0 and n < 2000000000 then return math.floor(n) end
    return nil
end

local function is_services(tags)
    return tags.highway == 'services' or tags.highway == 'rest_area'
end

function osm2pgsql.process_node(object)
    local tags = object.tags
    local types = poi_types(tags)
    if #types > 0 then insert_poi(object, types, object:as_point()) end

    if SETTLEMENT[tags.place] and tags.name then
        tables.settlement:insert({
            name = tags.name,
            place = tags.place,
            population = parse_population(tags.population),
            geom = object:as_point(),
        })
    end

    if is_services(tags) then tables.services:insert({ geom = object:as_point() }) end
end

function osm2pgsql.process_way(object)
    local tags = object.tags
    local types = poi_types(tags)
    if #types > 0 then
        local geom
        if object.is_closed then
            geom = object:as_polygon():centroid()
        end
        if geom == nil or geom:is_null() then
            -- open way, or a closed way that is not a valid polygon
            geom = object:as_linestring():centroid()
        end
        insert_poi(object, types, geom)
    end

    if LIFT[tags.aerialway] and tags.access ~= 'private' and tags.access ~= 'no' then
        local lt = {}
        for k, v in pairs(tags) do lt[k] = v end
        tables.lift:insert({ name = tags.name, tags = lt, geom = object:as_linestring() })
    end

    local hw = tags.highway
    if hw == 'motorway' or (hw == 'trunk' and tags.motorroad == 'yes') then
        tables.road:insert({ link = false, geom = object:as_linestring() })
    elseif hw == 'motorway_link' or (hw == 'trunk_link' and tags.motorroad == 'yes') then
        tables.road:insert({ link = true, geom = object:as_linestring() })
    end

    if is_services(tags) then
        if object.is_closed then
            tables.services:insert({ geom = object:as_polygon() })
        else
            tables.services:insert({ geom = object:as_linestring() })
        end
    end
end

function osm2pgsql.process_relation(object)
    local tags = object.tags
    if tags.type ~= 'multipolygon' then return end
    local types = poi_types(tags)
    if #types > 0 then insert_poi(object, types, object:as_multipolygon():centroid()) end
    if is_services(tags) then tables.services:insert({ geom = object:as_multipolygon() }) end
end
