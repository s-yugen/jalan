# Jalan: a Waze-style navigation app for Malaysia (iOS, Swift)

A working MVP: live GPS on a map, place search, route choices with toll badges, turn-by-turn
guidance with voice in **English or Bahasa Melayu**, automatic rerouting, and hazard reports
(accident, police, roadblock/SJR, flood, pothole, jam, stalled vehicle, road works) announced
when they're on the road ahead.

## Run it

Needs a Mac with Xcode 15 or later (iOS 17 SDK or newer).

```sh
git clone https://github.com/s-yugen/jalan.git
open jalan/Jalan.xcodeproj
```

Or double-click `Jalan.xcodeproj` in Finder. No other tools are needed.

1. Select the **Jalan** target → *Signing & Capabilities* → choose your Team (a free Apple ID works
   for running on your own phone). Change the bundle ID from `com.example.jalan` to your own.
2. Run on an iPhone. In the Simulator, set a location with *Features → Location* (for example
   *Freeway Drive*), or *Custom Location* with KL coordinates `3.1579, 101.7123`.
3. For Malay voice prompts, install the Malay voice on the phone:
   *Settings → Accessibility → Spoken Content → Voices → Malay*.

Run the core logic's unit tests (no simulator needed), or open `Packages/NavCore` in Xcode and press ⌘U:

```sh
cd Packages/NavCore && swift test
```

## How it's put together

```
Packages/NavCore/          Pure Swift, no UI, unit-tested
  OSRMCompatibleRouter     Fetches and parses routes from OSRM *or* Mapbox (same format)
  NavigationEngine         Snaps GPS to the route, next maneuver, distance/ETA left, off-route detection
  InstructionBuilder       English and Malay instructions ("Di bulatan, ambil susur keluar ke-2…")
  AnnouncementPlanner      When to speak: early (highways), ~250–800 m out, at the turn
  Hazard                   Report types, expiry times, "is it on my road ahead, in my direction?"
Jalan/                     SwiftUI app
  AppModel                 State machine: browsing → route preview → navigating
  RouteMapView             The only file that knows about the map SDK (Apple MapKit)
  LocationService, PlaceSearch, VoiceGuide, HazardStore, AppSettings
```

Data sources in the MVP, chosen so it runs with no API keys:

| What | Source | Cost |
| --- | --- | --- |
| Base map and live traffic layer | Apple MapKit | Free |
| Place search | Apple MapKit (`MKLocalSearch`) | Free |
| Routing | OSRM (OpenStreetMap) public demo server, or Mapbox Directions | Free / paid per request |
| Hazard reports | Stored on the phone | Free |

## Switching between OpenStreetMap and Mapbox

**Routing: already done.** Settings → Routing engine → Mapbox, paste a `pk.` token. Mapbox's
Directions API uses the same request and response format as OSRM, so one parser handles both.
Mapbox's `driving-traffic` profile adds live traffic to arrival times, which OSRM doesn't have.

**Base map: one file.** If you go to production with Mapbox Directions, check Mapbox's product terms.
They generally require Mapbox results to be shown on a Mapbox map. Then replace the MapKit `Map` in
`Jalan/Views/RouteMapView.swift` with the Mapbox Maps SDK's SwiftUI `Map` (or MapLibre for
self-hosted OSM tiles). Nothing else in the app touches the map SDK.

## Before going to production

- **Run your own OSRM server.** The public demo (`router.project-osrm.org`) forbids production use
  and is rate-limited. Download the Malaysia/Singapore/Brunei extract from Geofabrik,
  build it with the `osrm-backend` Docker image, and enter its URL under Settings → OSRM server.
  A small VPS can handle it.
- **Shared hazard reports.** This is what makes it Waze. Add a backend (for example PostgreSQL +
  PostGIS, or Supabase), POST reports from `HazardStore.add/confirm/dismiss`, and fetch reports
  within a few km of the driver every minute (or push them over WebSockets).
- **Crowd-sourced traffic.** Have phones send anonymised speed samples while navigating; aggregate
  them per road segment on the server and feed the result into routing weights.
- **PDPA 2010.** Location history is personal data under Malaysia's Personal Data Protection Act:
  get consent, publish a privacy notice, and keep only what you need.
- **App Store.** Background location needs a clear justification in review. CarPlay navigation
  needs a separate entitlement from Apple.

## Ideas that fit Malaysia

- Toll cost estimates per route (PLUS, LDP, SPRINT, and others) and Touch 'n Go / RFID lane hints
- Flood alerts from the JPS public flood portal (publicinfobanjir.water.gov.my) during monsoon season
- R&R stops, petrol stations and surau along the highway, with distances
- Speed camera (AES/AWAS) alerts from community data
- Expressway exit numbers on the banner (OSRM already returns them in `exits`)
