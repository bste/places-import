#!/usr/bin/env python3
"""Turn Geofabrik .poly files into SQL inserts for places_new.coverage.

Usage: poly2sql.py slovenia.poly croatia.poly ... > coverage.sql
The label is the file name without .poly (e.g. "slovenia", "nord-est").
Holes (sections starting with "!") are ignored: they are rare in Geofabrik boundaries.
"""
import os
import re
import sys


def read_poly(path):
    with open(path, encoding="utf-8") as f:
        lines = [l.strip() for l in f if l.strip()]
    polygons, i = [], 1  # line 0 is the file's name
    while i < len(lines) and lines[i] != "END":
        section, i = lines[i], i + 1
        ring = []
        while lines[i] != "END":
            x, y = lines[i].split()[:2]
            ring.append((float(x), float(y)))
            i += 1
        i += 1  # skip the section's END
        if section.startswith("!") or len(ring) < 3:
            continue
        if ring[0] != ring[-1]:
            ring.append(ring[0])
        polygons.append(ring)
    if not polygons:
        raise SystemExit(f"{path}: no polygon found")
    return polygons


def to_wkt(polygons):
    parts = []
    for ring in polygons:
        coords = ", ".join(f"{x:.7f} {y:.7f}" for x, y in ring)
        parts.append(f"(({coords}))")
    return "MULTIPOLYGON(" + ", ".join(parts) + ")"


def main(paths):
    print("CREATE TABLE IF NOT EXISTS places_new.coverage (country text NOT NULL, geom geography NOT NULL);")
    for path in paths:
        label = os.path.basename(path)[: -len(".poly")] if path.endswith(".poly") else os.path.basename(path)
        if not re.fullmatch(r"[a-z0-9-]+", label):
            raise SystemExit(f"{path}: unexpected file name")
        wkt = to_wkt(read_poly(path))
        print(f"INSERT INTO places_new.coverage VALUES ('{label}', ST_GeogFromText('SRID=4326;{wkt}'));")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    main(sys.argv[1:])
