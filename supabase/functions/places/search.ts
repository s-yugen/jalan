// Place search for the Jalan app: the `places` table first, then Photon (and Nominatim, when the
// user presses Search) for what the table doesn't have. What those services find is saved, so the
// same search later is answered from the table.

export type Service = "photon" | "nominatim";

export interface LatLon {
  lat: number;
  lon: number;
}

export interface Place extends LatLon {
  id: string;
  name: string;
  subtitle: string;
}

/// A place from the table, with how well its name matched (1 when the whole query is in the name).
export interface StoredPlace extends Place {
  name_score: number;
}

/// A place from Photon or Nominatim, ready to save.
export interface FoundPlace extends Place {
  kind: string;
}

/// What Photon or Nominatim answered for a search earlier.
export interface Lookup {
  service: Service;
  places: Place[];
}

/// The database, behind the functions in supabase/migrations.
export interface PlaceStore {
  search(query: string, near: LatLon | null, limit: number): Promise<StoredPlace[]>;
  recall(lookupKey: string): Promise<Lookup[]>;
  takeTurn(service: Service, minGapSeconds: number): Promise<boolean>;
  save(service: Service, lookupKey: string, places: FoundPlace[]): Promise<void>;
}

export interface Services {
  photonURL: string;
  nominatimURL: string;
  fetch: typeof fetch;
}

export interface SearchRequest {
  query: string;
  near: LatLon | null;
  limit: number;
  /// The user pressed Search: Nominatim may be asked too. Its public server forbids search-as-you-type.
  submit: boolean;
  photon: boolean;
  nominatim: boolean;
}

/// A name match at least this good, within `nearbyKm` of the driver, means the table has the place.
const goodMatch = 0.8;
const nearbyKm = 30;
/// Nominatim's usage policy: at most one request a second, from the whole app.
const nominatimGapSeconds = 1;
/// Peninsular Malaysia, Sabah and Sarawak, as in the app.
const malaysiaBox = { minLon: 99.6, minLat: 0.8, maxLon: 119.3, maxLat: 7.4 };
/// Nominatim's usage policy asks apps to identify themselves.
const userAgent = "Jalan/1.0 (place search server; https://github.com/s-yugen/jalan)";

export class BadRequest extends Error {}

export function parseRequest(url: URL): SearchRequest {
  const params = url.searchParams;
  const query = (params.get("q") ?? "").trim().replace(/\s+/g, " ");
  if (query.length === 0 || query.length > 200) throw new BadRequest("q must be 1 to 200 characters");
  const lat = Number(params.get("lat"));
  const lon = Number(params.get("lon"));
  const hasNear = params.has("lat") && params.has("lon") && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
  const limit = Math.trunc(Number(params.get("limit") ?? 8));
  return {
    query,
    near: hasNear ? { lat, lon } : null,
    limit: limit >= 1 && limit <= 20 ? limit : 8,
    submit: params.get("submit") === "1",
    photon: params.get("photon") !== "0",
    nominatim: params.get("nominatim") !== "0",
  };
}

/// The same search in roughly the same area (cells about 55 km across) counts as one lookup.
export function lookupKey(query: string, near: LatLon | null): string {
  const area = near ? `${Math.round(near.lat * 2) / 2},${Math.round(near.lon * 2) / 2}` : "-";
  return `${query.toLowerCase()}|${area}`;
}

export async function searchPlaces(request: SearchRequest, store: PlaceStore, services: Services): Promise<Place[]> {
  const { query, near, limit } = request;
  const stored = await store.search(query, near, limit);
  const key = lookupKey(query, near);
  const lookups = await store.recall(key);
  const answered: Place[] = lookups.flatMap((lookup) => lookup.places);
  const asked = new Set(lookups.map((lookup) => lookup.service));

  const wanted: Service[] = [];
  if (request.photon) wanted.push("photon");
  if (request.submit && request.nominatim) wanted.push("nominatim");

  for (const service of wanted) {
    if (hasPlace(stored, near) || answered.length > 0) break;
    // Asked this search before and it found nothing.
    if (asked.has(service)) continue;
    if (service === "nominatim" && !(await store.takeTurn(service, nominatimGapSeconds))) continue;
    let found: FoundPlace[];
    try {
      found = service === "photon" ? await askPhoton(query, near, services) : await askNominatim(query, near, services);
    } catch (error) {
      console.error(`${service} failed:`, error);
      continue;
    }
    await store.save(service, key, found);
    answered.push(...found);
  }

  return rank(stored, answered, limit);
}

/// True when the table has a good name match near the driver (anywhere, when we don't know where they are).
function hasPlace(stored: StoredPlace[], near: LatLon | null): boolean {
  return stored.some((place) => place.name_score >= goodMatch && (!near || distanceKm(place, near) <= nearbyKm));
}

/// Good matches from the table, then what the services answered, then the table's weaker matches.
function rank(stored: StoredPlace[], answered: Place[], limit: number): Place[] {
  const good = stored.filter((place) => place.name_score >= goodMatch);
  const weak = stored.filter((place) => place.name_score < goodMatch);
  const seen = new Set<string>();
  const places: Place[] = [];
  for (const place of [...good, ...answered, ...weak]) {
    if (places.length === limit) break;
    if (seen.has(place.id)) continue;
    seen.add(place.id);
    places.push({ id: place.id, name: place.name, subtitle: place.subtitle, lat: place.lat, lon: place.lon });
  }
  return places;
}

function distanceKm(a: LatLon, b: LatLon): number {
  const dLon = (a.lon - b.lon) * Math.cos((b.lat * Math.PI) / 180);
  return 111.32 * Math.hypot(a.lat - b.lat, dLon);
}

// MARK: - Photon

interface PhotonFeature {
  geometry?: { type?: string; coordinates?: number[] };
  properties?: Record<string, unknown>;
}

async function askPhoton(query: string, near: LatLon | null, services: Services): Promise<FoundPlace[]> {
  const url = new URL(root(services.photonURL) + "/api/");
  const box = malaysiaBox;
  url.searchParams.set("q", query);
  url.searchParams.set("limit", "10");
  url.searchParams.set("bbox", `${box.minLon},${box.minLat},${box.maxLon},${box.maxLat}`);
  if (near) {
    url.searchParams.set("lat", near.lat.toFixed(5));
    url.searchParams.set("lon", near.lon.toFixed(5));
  }
  const body = await get(url, services);
  return parsePhoton(body as { features?: PhotonFeature[] });
}

export function parsePhoton(body: { features?: PhotonFeature[] }): FoundPlace[] {
  const places: FoundPlace[] = [];
  for (const feature of body.features ?? []) {
    const p = feature.properties ?? {};
    const [lon, lat] = (feature.geometry?.coordinates ?? []).map(Number);
    const type = text(p.osm_type).toLowerCase();
    const osmId = Number(p.osm_id);
    if (feature.geometry?.type !== "Point" || !isCoordinate(lat, lon)) continue;
    if (!["n", "w", "r"].includes(type) || !Number.isInteger(osmId) || osmId <= 0) continue;
    const street = [text(p.housenumber), text(p.street)].filter(Boolean).join(" ");
    const name = firstNonEmpty(text(p.name), street, text(p.locality), text(p.city));
    if (!name) continue;
    const subtitle = join([
      text(p.name) ? street : "",
      text(p.district) || text(p.locality),
      text(p.city) || text(p.county),
      text(p.state),
    ], name);
    const kind = text(p.osm_key) && text(p.osm_value) ? `${text(p.osm_key)}=${text(p.osm_value)}` : "";
    places.push({ id: `${type}${osmId}`, name, subtitle, kind, lat, lon });
  }
  return places;
}

// MARK: - Nominatim

interface NominatimPlace {
  osm_type?: string;
  osm_id?: number;
  lat?: string;
  lon?: string;
  name?: string;
  display_name?: string;
  category?: string;
  type?: string;
}

async function askNominatim(query: string, near: LatLon | null, services: Services): Promise<FoundPlace[]> {
  const url = new URL(root(services.nominatimURL) + "/search");
  url.searchParams.set("q", query);
  url.searchParams.set("format", "jsonv2");
  url.searchParams.set("countrycodes", "my");
  url.searchParams.set("limit", "10");
  if (near) {
    // A box about 150 km across. Without `bounded=1` it ranks nearby places higher instead of filtering.
    const d = 0.7;
    url.searchParams.set(
      "viewbox",
      [near.lon - d, near.lat + d, near.lon + d, near.lat - d]
        .map((value) => value.toFixed(5)).join(","),
    );
  }
  const body = await get(url, services);
  return parseNominatim(body as NominatimPlace[]);
}

export function parseNominatim(body: NominatimPlace[]): FoundPlace[] {
  const types: Record<string, string> = { node: "n", way: "w", relation: "r" };
  const places: FoundPlace[] = [];
  for (const place of Array.isArray(body) ? body : []) {
    const type = types[place.osm_type ?? ""];
    const lat = Number(place.lat);
    const lon = Number(place.lon);
    if (!type || !Number.isInteger(place.osm_id) || !isCoordinate(lat, lon)) continue;
    const display = text(place.display_name);
    const name = firstNonEmpty(text(place.name), display.split(",")[0].trim());
    if (!name) continue;
    const subtitle = display.startsWith(name) ? display.slice(name.length).replace(/^[,\s]+/, "") : display;
    const kind = place.category && place.type ? `${place.category}=${place.type}` : "";
    places.push({ id: `${type}${place.osm_id}`, name, subtitle, kind, lat, lon });
  }
  return places;
}

// MARK: - Helpers

async function get(url: URL, services: Services): Promise<unknown> {
  const response = await services.fetch(url, {
    headers: { "User-Agent": userAgent },
    signal: AbortSignal.timeout(8000),
  });
  if (!response.ok) throw new Error(`${url.host} answered HTTP ${response.status}`);
  return await response.json();
}

function root(url: string): string {
  return url.replace(/\/+$/, "");
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function firstNonEmpty(...values: string[]): string {
  return values.find((value) => value.length > 0) ?? "";
}

function isCoordinate(lat: number, lon: number): boolean {
  return Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
}

/// "Lingkaran Syed Putra", "Kuala Lumpur", "Kuala Lumpur" → "Lingkaran Syed Putra, Kuala Lumpur"
function join(parts: string[], name: string): string {
  const seen = new Set([name]);
  return parts.filter((part) => part && !seen.has(part) && seen.add(part)).join(", ");
}
