import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  BadRequest,
  type FoundPlace,
  type Lookup,
  lookupKey,
  parseNominatim,
  parsePhoton,
  parseRequest,
  type PlaceStore,
  searchPlaces,
  type SearchRequest,
  type Service,
  type StoredPlace,
} from "./search.ts";

const klcc = { lat: 3.1579, lon: 101.7123 };

function request(query: string, changes: Partial<SearchRequest> = {}): SearchRequest {
  return { query, near: klcc, limit: 8, submit: false, photon: true, nominatim: true, ...changes };
}

function stored(id: string, name: string, nameScore: number, at = klcc): StoredPlace {
  return { id, name, subtitle: "", lat: at.lat, lon: at.lon, name_score: nameScore };
}

/// A database in memory that records what the search saved.
class FakeStore implements PlaceStore {
  saved: { service: Service; key: string; places: FoundPlace[] }[] = [];
  turnsTaken = 0;

  constructor(
    private stored: StoredPlace[] = [],
    private lookups: Lookup[] = [],
    private turnFree = true,
  ) {}

  search() {
    return Promise.resolve(this.stored);
  }

  recall() {
    return Promise.resolve(this.lookups);
  }

  takeTurn() {
    this.turnsTaken++;
    return Promise.resolve(this.turnFree);
  }

  save(service: Service, key: string, places: FoundPlace[]) {
    this.saved.push({ service, key, places });
    return Promise.resolve();
  }
}

const photonAnswer = {
  features: [{
    geometry: { type: "Point", coordinates: [101.6772, 3.1182] },
    properties: {
      osm_type: "W",
      osm_id: 123,
      osm_key: "shop",
      osm_value: "mall",
      name: "Mid Valley Megamall",
      street: "Lingkaran Syed Putra",
      city: "Kuala Lumpur",
      state: "Kuala Lumpur",
    },
  }],
};

const nominatimAnswer = [{
  osm_type: "node",
  osm_id: 456,
  lat: "3.1500",
  lon: "101.7000",
  name: "Kedai Ah Seng",
  display_name: "Kedai Ah Seng, Jalan Alor, Bukit Bintang, Kuala Lumpur, Malaysia",
  category: "shop",
  type: "convenience",
}];

/// Fake Photon and Nominatim servers that record which were asked.
function fakeServices(answers: { photon?: unknown; nominatim?: unknown } = {}) {
  const asked: string[] = [];
  const fakeFetch = (input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : input);
    const service = url.host.startsWith("photon") ? "photon" : "nominatim";
    asked.push(service);
    const answer = answers[service];
    if (answer === undefined) return Promise.resolve(new Response("down", { status: 503 }));
    return Promise.resolve(Response.json(answer));
  };
  return {
    asked,
    services: {
      photonURL: "https://photon.test/",
      nominatimURL: "https://nominatim.test",
      fetch: fakeFetch as typeof fetch,
    },
  };
}

Deno.test("parseRequest reads the query, location and options", () => {
  const parsed = parseRequest(
    new URL("https://x.test/places?q=%20mid%20%20valley%20&lat=3.1&lon=101.7&limit=5&submit=1&photon=0"),
  );
  assertEquals(parsed, {
    query: "mid valley",
    near: { lat: 3.1, lon: 101.7 },
    limit: 5,
    submit: true,
    photon: false,
    nominatim: true,
  });

  const defaults = parseRequest(new URL("https://x.test/places?q=klcc&lat=99&lon=101&limit=500"));
  assertEquals(defaults.near, null);
  assertEquals(defaults.limit, 8);
  assertEquals(defaults.submit, false);

  assertThrows(() => parseRequest(new URL("https://x.test/places?q=%20")), BadRequest);
  assertThrows(() => parseRequest(new URL(`https://x.test/places?q=${"a".repeat(201)}`)), BadRequest);
});

Deno.test("lookupKey groups the same search in roughly the same area", () => {
  assertEquals(lookupKey("Mid Valley", klcc), "mid valley|3,101.5");
  assertEquals(lookupKey("Mid Valley", { lat: 3.2, lon: 101.6 }), "mid valley|3,101.5");
  assertEquals(lookupKey("Mid Valley", null), "mid valley|-");
});

Deno.test("a good match nearby in the table answers without asking Photon", async () => {
  const store = new FakeStore([stored("w1", "Mid Valley Megamall", 1)]);
  const { asked, services } = fakeServices({ photon: photonAnswer });
  const places = await searchPlaces(request("mid valley"), store, services);
  assertEquals(places.map((p) => p.id), ["w1"]);
  assertEquals(asked, []);
  assertEquals(store.saved, []);
});

Deno.test("a place missing from the table is asked of Photon and saved", async () => {
  const store = new FakeStore([stored("n9", "Valley Inn", 0.5)]);
  const { asked, services } = fakeServices({ photon: photonAnswer, nominatim: nominatimAnswer });
  const places = await searchPlaces(request("mid valley"), store, services);
  assertEquals(asked, ["photon"]);
  assertEquals(store.saved.length, 1);
  assertEquals(store.saved[0].service, "photon");
  assertEquals(store.saved[0].key, "mid valley|3,101.5");
  assertEquals(store.saved[0].places.map((p) => p.id), ["w123"]);
  // Photon's find first, then the table's weak match.
  assertEquals(places.map((p) => p.id), ["w123", "n9"]);
  assertEquals(Object.keys(places[0]).sort(), ["id", "lat", "lon", "name", "subtitle"]);
});

Deno.test("a good match far away doesn't count as found", async () => {
  const penang = { lat: 5.41, lon: 100.33 };
  const store = new FakeStore([stored("n1", "Kedai Ah Seng", 1, penang)]);
  const { asked, services } = fakeServices({ photon: { features: [] } });
  await searchPlaces(request("kedai ah seng"), store, services);
  assertEquals(asked, ["photon"]);
});

Deno.test("a search answered before is answered from the table", async () => {
  const remembered = { id: "w123", name: "Mid Valley Megamall", subtitle: "", lat: 3.1, lon: 101.6 };
  const store = new FakeStore([], [{ service: "photon", places: [remembered] }]);
  const { asked, services } = fakeServices({ photon: photonAnswer, nominatim: nominatimAnswer });
  const places = await searchPlaces(request("mid valley", { submit: true }), store, services);
  assertEquals(asked, []);
  assertEquals(places, [remembered]);
});

Deno.test("Search asks Nominatim when Photon found nothing", async () => {
  const store = new FakeStore([], [{ service: "photon", places: [] }]);
  const { asked, services } = fakeServices({ photon: photonAnswer, nominatim: nominatimAnswer });

  assertEquals(await searchPlaces(request("kedai ah seng"), store, services), []);
  assertEquals(asked, []);

  const places = await searchPlaces(request("kedai ah seng", { submit: true }), store, services);
  assertEquals(asked, ["nominatim"]);
  assertEquals(store.turnsTaken, 1);
  assertEquals(store.saved.map((s) => s.service), ["nominatim"]);
  assertEquals(places.map((p) => p.id), ["n456"]);
});

Deno.test("Nominatim isn't asked more than once a second, or when turned off", async () => {
  const busy = new FakeStore([], [{ service: "photon", places: [] }], false);
  const first = fakeServices({ nominatim: nominatimAnswer });
  assertEquals(await searchPlaces(request("kedai", { submit: true }), busy, first.services), []);
  assertEquals(first.asked, []);
  assertEquals(busy.saved, []);

  const off = fakeServices({ photon: { features: [] }, nominatim: nominatimAnswer });
  await searchPlaces(request("kedai", { submit: true, nominatim: false }), new FakeStore(), off.services);
  assertEquals(off.asked, ["photon"]);
});

Deno.test("a service that fails is skipped and nothing is saved for it", async () => {
  const store = new FakeStore([stored("n9", "Valley Inn", 0.5)]);
  const { asked, services } = fakeServices({ nominatim: nominatimAnswer });
  const places = await searchPlaces(request("mid valley", { submit: true }), store, services);
  assertEquals(asked, ["photon", "nominatim"]);
  assertEquals(store.saved.map((s) => s.service), ["nominatim"]);
  assertEquals(places.map((p) => p.id), ["n456", "n9"]);
});

Deno.test("results are ranked, without duplicates, up to the limit", async () => {
  const store = new FakeStore(
    [stored("n2", "Weak", 0.4), stored("n1", "Good", 0.9, { lat: 5.41, lon: 100.33 }), stored("w123", "Dup", 0.3)],
  );
  const { services } = fakeServices({ photon: photonAnswer });
  const places = await searchPlaces(request("x", { limit: 3 }), store, services);
  assertEquals(places.map((p) => p.id), ["n1", "w123", "n2"]);
});

Deno.test("parsePhoton keeps OpenStreetMap points with a name or address", () => {
  const places = parsePhoton({
    features: [
      ...photonAnswer.features,
      {
        geometry: { type: "Point", coordinates: [101.7, 3.15] },
        properties: { osm_type: "N", osm_id: 7, housenumber: "12", street: "Jalan Alor", city: "Kuala Lumpur" },
      },
      { geometry: { type: "Polygon", coordinates: [] }, properties: { osm_type: "W", osm_id: 8, name: "Area" } },
      { geometry: { type: "Point", coordinates: [101.7, 3.15] }, properties: { name: "No OSM id" } },
      { geometry: { type: "Point", coordinates: [101.7, 3.15] }, properties: { osm_type: "N", osm_id: 9 } },
    ],
  });
  assertEquals(places, [
    {
      id: "w123",
      name: "Mid Valley Megamall",
      subtitle: "Lingkaran Syed Putra, Kuala Lumpur",
      kind: "shop=mall",
      lat: 3.1182,
      lon: 101.6772,
    },
    { id: "n7", name: "12 Jalan Alor", subtitle: "Kuala Lumpur", kind: "", lat: 3.15, lon: 101.7 },
  ]);
});

Deno.test("parseNominatim maps OpenStreetMap types to ids", () => {
  const places = parseNominatim([
    ...nominatimAnswer,
    { osm_type: "relation", osm_id: 9, lat: "2.9", lon: "101.6", name: "", display_name: "Putrajaya, Malaysia" },
    { osm_type: "way", lat: "2.9", lon: "101.6", name: "No id" },
  ]);
  assertEquals(places, [
    {
      id: "n456",
      name: "Kedai Ah Seng",
      subtitle: "Jalan Alor, Bukit Bintang, Kuala Lumpur, Malaysia",
      kind: "shop=convenience",
      lat: 3.15,
      lon: 101.7,
    },
    { id: "r9", name: "Putrajaya", subtitle: "Malaysia", kind: "", lat: 2.9, lon: 101.6 },
  ]);
});
