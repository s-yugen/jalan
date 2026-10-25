"""Imports Malaysia's OpenStreetMap places into the Jalan server's `places` table (Supabase).

    curl -O https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf
    python3 scripts/import_osm_places.py malaysia-singapore-brunei-latest.osm.pbf "$DATABASE_URL"

DATABASE_URL is the project's Postgres connection string (in Supabase: Connect → Session pooler).
Needs pyosmium and psycopg (pip install osmium "psycopg[binary]").

Run it again with a newer download (Geofabrik updates it daily; monthly is plenty): changed places are
updated and places deleted from OpenStreetMap are removed. Places that Photon and Nominatim found
for searches are kept.
"""
import math, os, sys, time
import osmium, psycopg

# Named things people drive to, by OpenStreetMap tag. None means any value.
PLACE_TAGS = {
    "amenity": None, "shop": None, "tourism": None, "leisure": None, "office": None, "healthcare": None,
    "craft": None, "historic": None,
    "place": {"city", "town", "village", "hamlet", "suburb", "quarter", "neighbourhood", "locality",
              "island", "islet", "isolated_dwelling"},
    "railway": {"station", "halt", "tram_stop"},
    "public_transport": {"station"},
    "aeroway": {"aerodrome", "terminal"},
    "highway": {"services", "rest_area"},  # R&R stops
    "barrier": {"toll_booth"},  # toll plazas
    "landuse": {"residential", "retail", "commercial", "industrial"},  # housing estates (taman), business parks
    "natural": {"peak", "beach", "bay", "cape"},
    "waterway": {"waterfall", "dam"},
    "man_made": {"lighthouse", "pier"},
    "building": None,  # last: a named building is a place only if nothing above says what it is
}
ROADS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
         "living_street", "pedestrian"}
# A road is mapped as many short ways; keep one per name in each cell about 2 km across.
ROAD_CELL = 0.02

NAME_TAGS = ("name", "name:ms", "name:en")
OTHER_NAME_TAGS = ("name:ms", "name:en", "name:zh", "name:ta", "alt_name", "short_name", "official_name",
                   "old_name", "loc_name", "int_name")

# Places that describe where something is: the nearest neighbourhood within 3 km and town within 25 km.
AREAS = {"suburb", "quarter", "neighbourhood", "village", "hamlet"}
TOWNS = {"city", "town"}
AREA_KM, TOWN_KM = 3, 25


class Nearest:
    """The nearest named point within `km`, from a grid of cells `km` wide."""

    def __init__(self, km):
        self.cell = km / 111.32
        self.km = km
        self.grid = {}

    def add(self, lat, lon, name):
        self.grid.setdefault((int(lat // self.cell), int(lon // self.cell)), []).append((lat, lon, name))

    def find(self, lat, lon):
        row, col = int(lat // self.cell), int(lon // self.cell)
        best, best_km = "", self.km
        for r in (row - 1, row, row + 1):
            for c in (col - 1, col, col + 1):
                for plat, plon, name in self.grid.get((r, c), ()):
                    km = 111.32 * math.hypot(plat - lat, (plon - lon) * math.cos(math.radians(lat)))
                    if km <= best_km:
                        best, best_km = name, km
        return best


class Localities(osmium.SimpleHandler):
    """First pass: the neighbourhoods and towns that subtitles name."""

    def __init__(self):
        super().__init__()
        self.areas, self.towns = Nearest(AREA_KM), Nearest(TOWN_KM)

    def node(self, n):
        place, name = n.tags.get("place"), n.tags.get("name")
        if name and place in AREAS:
            self.areas.add(n.location.lat, n.location.lon, name)
        elif name and place in TOWNS:
            self.towns.add(n.location.lat, n.location.lon, name)


class Places(osmium.SimpleHandler):
    """Second pass: every named place and road, as rows for `places`."""

    def __init__(self, localities, write):
        super().__init__()
        self.localities = localities
        self.write = write
        self.roads_seen = set()
        self.count = 0

    def node(self, n):
        kind = place_kind(n.tags)
        if kind and n.location.valid():
            self.add(f"n{n.id}", n.tags, kind, n.location.lat, n.location.lon)

    def way(self, w):
        tags = w.tags
        if tags.get("highway") not in ROADS or not tags.get("name") or len(w.nodes) == 0:
            return
        middle = w.nodes[len(w.nodes) // 2].location
        if not middle.valid():
            return
        key = (tags["name"].lower(), round(middle.lat / ROAD_CELL), round(middle.lon / ROAD_CELL))
        if key in self.roads_seen:
            return
        self.roads_seen.add(key)
        self.add(f"w{w.id}", tags, f"highway={tags['highway']}", middle.lat, middle.lon)

    def area(self, a):
        tags = a.tags
        if tags.get("highway") in ROADS:  # closed roads (loops) are handled in way()
            return
        kind = place_kind(tags)
        if not kind:
            return
        # The middle of its (first) outline. A ring ends where it starts, so leave out the last point.
        for ring in a.outer_rings():
            points = [(n.lat, n.lon) for n in ring][:-1]
            if not points:
                return
            lat = sum(p[0] for p in points) / len(points)
            lon = sum(p[1] for p in points) / len(points)
            self.add(f"{'w' if a.from_way() else 'r'}{a.orig_id()}", tags, kind, lat, lon)
            return

    def add(self, osm_id, tags, kind, lat, lon):
        name, other_names = names(tags)
        if not name:
            return
        self.write((osm_id, name, other_names, self.subtitle(tags, name, lat, lon), kind, lat, lon))
        self.count += 1
        if self.count % 100_000 == 0:
            print(f"  {self.count:,} places…", flush=True)

    def subtitle(self, tags, name, lat, lon):
        """Where it is, like "Jalan Telawi, Bangsar, Kuala Lumpur": its address if mapped, otherwise nearby places."""
        area = tags.get("addr:suburb") or tags.get("addr:district") or self.localities.areas.find(lat, lon)
        town = tags.get("addr:city") or self.localities.towns.find(lat, lon)
        parts, seen = [], {name}
        for part in (tags.get("addr:street"), area, town):
            if part and part not in seen:
                parts.append(part)
                seen.add(part)
        return ", ".join(parts)


def place_kind(tags):
    """The tag that makes this a place, like "amenity=fuel", or None."""
    if not any(tag in tags for tag in NAME_TAGS):
        return None
    for key, values in PLACE_TAGS.items():
        value = tags.get(key)
        if value and value != "no" and (values is None or value in values):
            return f"{key}={value}"
    return None


def names(tags):
    """The name to show, and the other names to search by."""
    name = next((tags[tag].strip() for tag in NAME_TAGS if tags.get(tag, "").strip()), "")
    others, seen = [], {name}
    for tag in OTHER_NAME_TAGS:
        for value in tags.get(tag, "").split(";"):
            value = value.strip()
            if value and value not in seen:
                others.append(value)
                seen.add(value)
    return name, " ".join(others)


def main(pbf, database_url):
    started = time.time()
    print("Finding neighbourhoods and towns…", flush=True)
    localities = Localities()
    localities.apply_file(pbf)

    with psycopg.connect(database_url) as connection, connection.cursor() as cursor:
        cursor.execute("set local statement_timeout = 0")
        cursor.execute("""create temporary table import (
            id text, name text, alt_names text, subtitle text, kind text, lat double precision,
            lon double precision) on commit drop""")
        print("Reading places…", flush=True)
        with cursor.copy("copy import (id, name, alt_names, subtitle, kind, lat, lon) from stdin") as copy:
            handler = Places(localities, copy.write_row)
            handler.apply_file(pbf, locations=True)
        print(f"Read {handler.count:,} places. Saving…", flush=True)

        cursor.execute("create index on import (id)")
        cursor.execute("analyze import")
        cursor.execute("""
            insert into public.places as p (id, name, alt_names, subtitle, kind, lat, lon, source)
            select distinct on (id) id, name, alt_names, subtitle, kind, lat, lon, 'osm' from import order by id
            on conflict (id) do update set
              name = excluded.name, alt_names = excluded.alt_names, subtitle = excluded.subtitle,
              kind = excluded.kind, lat = excluded.lat, lon = excluded.lon, source = 'osm', updated_at = now()
            where (p.name, p.alt_names, p.subtitle, p.kind, p.lat, p.lon, p.source)
                  is distinct from (excluded.name, excluded.alt_names, excluded.subtitle, excluded.kind,
                                    excluded.lat, excluded.lon, 'osm')""")
        changed = cursor.rowcount
        cursor.execute("""
            delete from public.places p
            where p.source = 'osm' and not exists (select 1 from import i where i.id = p.id)""")
        removed = cursor.rowcount
        cursor.execute("analyze public.places")
    print(f"Done in {time.time() - started:.0f} s: {changed:,} places added or changed, {removed:,} removed.")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 2 and "DATABASE_URL" not in os.environ):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else os.environ["DATABASE_URL"])
