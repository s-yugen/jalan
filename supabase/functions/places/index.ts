// GET /functions/v1/places?q=mid+valley&lat=3.15&lon=101.71&limit=8&submit=1
// → {"places": [{"id": "w123", "name": "Mid Valley Megamall", "subtitle": "…", "lat": 3.11, "lon": 101.67}]}
//
// Deploy with `supabase functions deploy places --no-verify-jwt`: the app calls it without a key,
// like a public Photon server. The database behind it is only reachable with the service role key.

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  BadRequest,
  type Lookup,
  parseRequest,
  type Place,
  type PlaceStore,
  searchPlaces,
  type Service,
} from "./search.ts";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

/// How long a Photon or Nominatim answer is reused before the search is sent to them again.
const lookupMaxAge = "30 days";

const store: PlaceStore = {
  async search(query, near, limit) {
    const { data, error } = await supabase.rpc("search_places", {
      query,
      near_lat: near?.lat ?? null,
      near_lon: near?.lon ?? null,
      max_results: limit,
    });
    if (error) throw error;
    return data;
  },

  async recall(lookupKey) {
    const { data, error } = await supabase.rpc("recall_lookups", { lookup_key: lookupKey, max_age: lookupMaxAge });
    if (error) throw error;
    const lookups = new Map<Service, Lookup>();
    // A service that found nothing has one row, with a null id.
    for (const { service, id, name, subtitle, lat, lon } of data as ({ service: Service } & Place)[]) {
      const lookup = lookups.get(service) ?? { service, places: [] };
      lookups.set(service, lookup);
      if (id) lookup.places.push({ id, name, subtitle, lat, lon });
    }
    return [...lookups.values()];
  },

  async takeTurn(service, minGapSeconds) {
    const { data, error } = await supabase.rpc("take_turn", { service, min_gap: `${minGapSeconds} seconds` });
    if (error) throw error;
    return data === true;
  },

  async save(service, lookupKey, places) {
    const { error } = await supabase.rpc("save_places", { service, lookup_key: lookupKey, found_places: places });
    if (error) throw error;
  },
};

const services = {
  photonURL: Deno.env.get("PHOTON_URL") ?? "https://photon.komoot.io",
  nominatimURL: Deno.env.get("NOMINATIM_URL") ?? "https://nominatim.openstreetmap.org",
  fetch,
};

Deno.serve(async (request) => {
  if (request.method !== "GET") return json({ error: "Use GET" }, 405);
  try {
    const places = await searchPlaces(parseRequest(new URL(request.url)), store, services);
    return json({ places });
  } catch (error) {
    if (error instanceof BadRequest) return json({ error: error.message }, 400);
    console.error(error);
    return json({ error: "Search failed" }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
