# Jalan: a Waze-style navigation app for Malaysia (iOS, Swift)

A working MVP: live GPS on a map, place search, route choices with toll badges, turn-by-turn
guidance with voice in **English or Bahasa Melayu**, and automatic rerouting. Hazard reports are
left out of the app until there's a backend to share them between drivers (see below); the hazard
logic in NavCore is kept for that. Your position shows as the blue dot or, if you prefer, a **3D car** that
points the way you're driving (Settings → Map). It also runs on the car's screen with **Apple CarPlay**.

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

GitHub Actions runs the same tests, and builds the app for the iOS Simulator, on every pull request and every push to `main`
(`.github/workflows/test.yml`).

## How it's put together

```
Packages/NavCore/          Pure Swift, no UI, unit-tested
  OSRMCompatibleRouter     Fetches and parses routes from OSRM *or* Mapbox (same format)
  WebGeocoder              Place search on Photon, openrouteservice, Stadia, LocationIQ, MapTiler, Nominatim
  NavigationEngine         Snaps GPS to the route, next maneuver, distance/ETA left, off-route detection
  InstructionBuilder       English and Malay instructions ("Di bulatan, ambil susur keluar ke-2…")
  AnnouncementPlanner      When to speak: early (highways), ~250–800 m out, at the turn
  Hazard                   Report types, expiry times, "is it on my road ahead, in my direction?"
Jalan/                     SwiftUI app
  AppModel                 State machine: browsing → route preview → navigating, shared by phone and car
  RouteMapView             The phone's map: the only phone file that knows about the map SDK (Apple MapKit)
  CarModelView             The 3D car that can stand in for the blue dot, on the phone and in CarPlay
  LocationService, PlaceSearch, VoiceGuide, AppSettings
Jalan/CarPlay/             The car's screen, on the same AppModel
  CarPlayController        Search, route choices, turn-by-turn panel
  CarPlayMapViewController The car's map (UIKit MKMapView, which CarPlay needs), with its own camera
```

Data sources in the MVP, chosen so it runs with no API keys:

| What | Source | Cost |
| --- | --- | --- |
| Base map and live traffic layer | Apple MapKit | Free |
| Place search | Apple MapKit (`MKLocalSearch`), plus the OpenStreetMap services below | Free |
| Routing | OSRM (OpenStreetMap) public demo server, or Mapbox Directions | Free / paid per request |

## Switching between OpenStreetMap and Mapbox

**Routing: already done.** Settings → Routing engine → Mapbox, paste a `pk.` token. Mapbox's
Directions API uses the same request and response format as OSRM, so one parser handles both.
Mapbox's `driving-traffic` profile adds live traffic to arrival times, which OSRM doesn't have.

**Base map: two files.** If you go to production with Mapbox Directions, check Mapbox's product terms.
They generally require Mapbox results to be shown on a Mapbox map. Then replace the MapKit `Map` in
`Jalan/Views/RouteMapView.swift` with the Mapbox Maps SDK's SwiftUI `Map` (or MapLibre for
self-hosted OSM tiles), and the `MKMapView` in `Jalan/CarPlay/CarPlayMapViewController.swift` with
the same SDK's UIKit `MapView`. Nothing else in the app touches the map SDK.

## CarPlay

The phone and the car's screen share one model, so a destination or trip started on either shows on
both, and voice prompts play through the car's speakers. On the car's screen:

- **Where to?** opens a search that asks Apple Maps and the OpenStreetMap services set up under
  Settings → Place search (CarPlay only allows the keyboard while parked).
- Route choices show time, distance and tolls; **Go** starts guidance in the green turn panel.
- Map buttons recentre, zoom and pan (arrow buttons, or drag on a touchscreen).

**Try it in the Simulator.** Run the app on an iPhone Simulator, then choose *I/O → External
Displays → CarPlay* in the Simulator's menu. Simulator builds already carry the CarPlay
entitlement (`Jalan/Jalan.entitlements`). Open the app on the phone once first to allow location.

**On a real car, or the App Store,** Apple has to approve the app for CarPlay first: request the
*CarPlay Navigation* entitlement at developer.apple.com/carplay with the paid developer account that
signs the app. Once it's granted, in *Build Settings → Code Signing Entitlements*, set
`Jalan/Jalan.entitlements` for all SDKs (it's set for the Simulator only now, because signing for a
phone with an entitlement your account doesn't have fails, and that would stop the app running on a
phone at all).

## Place search

Search asks every enabled service at once and lists each one's results in its own section, so you
can see which service knows a place. Set them up under Settings → Place search.

| Service | Key | Free use | When it's asked |
| --- | --- | --- | --- |
| Apple Maps | None | Free | As you type |
| [Photon](https://photon.komoot.io) (Komoot's public server, or your own) | None | Fair use, no guarantee | As you type, from 3 letters |
| [openrouteservice](https://openrouteservice.org) (Pelias) | Free sign-up | Daily request quota | As you type, from 3 letters |
| [Stadia Maps](https://stadiamaps.com) (Pelias) | Free sign-up | Non-commercial only | As you type, from 3 letters |
| [LocationIQ](https://locationiq.com) | Free sign-up | Daily request quota | As you type, from 3 letters |
| [MapTiler](https://www.maptiler.com/cloud/geocoding/) | Free sign-up | Non-commercial only | As you type, from 3 letters |
| [Nominatim](https://nominatim.org) (public server) | None | Light use only | When you press Search: its policy forbids search-as-you-type |

Everything except Apple searches OpenStreetMap data, so the app shows "© OpenStreetMap contributors".
A missing place can be added to OpenStreetMap by anyone (for example with the StreetComplete or
Every Door apps) and then shows up in these services after their next data update.

## Before going to production

- **Run your own OSRM server.** The public demo (`router.project-osrm.org`) forbids production use
  and is rate-limited. Download the Malaysia/Singapore/Brunei extract from Geofabrik,
  build it with the `osrm-backend` Docker image, and enter its URL under Settings → OSRM server.
  A small VPS can handle it.
- **Run your own Photon server** or move to paid search plans. Komoot's public Photon and the public
  Nominatim server don't allow heavy use, and the Stadia Maps and MapTiler free plans don't allow
  commercial use. Photon can sit on the same VPS as OSRM; enter its URL under Settings → Photon server.
- **Shared hazard reports.** This is what makes it Waze. Add a backend (for example PostgreSQL +
  PostGIS, or Supabase) that drivers POST reports to, and fetch reports within a few km of the
  driver every minute (or push them over WebSockets). NavCore's `HazardLocator` and
  `AnnouncementPlanner.hazardAlert` already work out which reports are on the road ahead and what
  to say; the app needs a report button, map markers and an "ahead" banner again (and the CarPlay
  report grid and alerts).
- **Crowd-sourced traffic.** Have phones send anonymised speed samples while navigating; aggregate
  them per road segment on the server and feed the result into routing weights.
- **PDPA 2010.** Location history is personal data under Malaysia's Personal Data Protection Act:
  get consent, publish a privacy notice, and keep only what you need.
- **App Store.** Background location needs a clear justification in review. CarPlay navigation
  needs a separate entitlement from Apple (see CarPlay above).

## Ideas that fit Malaysia

- Toll cost estimates per route (PLUS, LDP, SPRINT, and others) and Touch 'n Go / RFID lane hints
- Flood alerts from the JPS public flood portal (publicinfobanjir.water.gov.my) during monsoon season
- R&R stops, petrol stations and surau along the highway, with distances
- Speed camera (AES/AWAS) alerts from community data
- Expressway exit numbers on the banner (OSRM already returns them in `exits`)
