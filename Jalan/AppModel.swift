import SwiftUI
import MapKit
import Observation
import NavCore

struct Destination: Equatable {
    var name: String
    var subtitle: String
    var coordinate: Coordinate
}

/// App state: browsing the map, previewing routes, or driving with turn-by-turn guidance.
@MainActor
@Observable
final class AppModel {
    enum Phase { case browsing, previewing, navigating }

    let settings = AppSettings()
    let location = LocationService()
    let search = PlaceSearch()
    let hazards = HazardStore()
    private let voice = VoiceGuide()

    var phase: Phase = .browsing
    var destination: Destination?
    var routes: [Route] = []
    var selectedRouteID: Route.ID?
    var isLoadingRoutes = false
    var isRerouting = false
    var errorMessage: String?
    var progress: NavigationProgress?
    var hazardAhead: HazardAhead?
    var camera: MapCameraPosition = .userLocation(fallback: .region(.malaysia))
    /// The camera tracks the car until the user pans the map.
    var isFollowing = true

    @ObservationIgnored private var engine: NavigationEngine?
    @ObservationIgnored private var planner: AnnouncementPlanner?
    @ObservationIgnored private var lastRerouteAt = Date.distantPast

    init() {
        location.onUpdate = { [weak self] in self?.locationDidUpdate($0) }
        search.geocoders = { [settings] in (settings.makeTypingGeocoders(), settings.makeSubmitGeocoders()) }
        location.start()
    }

    var selectedRoute: Route? {
        routes.first { $0.id == selectedRouteID } ?? routes.first
    }

    var alternativeRoutes: [Route] {
        routes.filter { $0.id != selectedRoute?.id }
    }

    var upcomingStep: RouteStep? {
        guard let progress, let route = selectedRoute,
              route.steps.indices.contains(progress.upcomingStepIndex) else { return nil }
        return route.steps[progress.upcomingStepIndex]
    }

    // MARK: - Destination and route preview

    func choose(_ completion: MKLocalSearchCompletion) async {
        do {
            guard let item = try await search.resolve(completion) else { return }
            await preview(Destination(name: completion.title, subtitle: completion.subtitle,
                                      coordinate: Coordinate(item.placemark.coordinate)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A result from one of the web services, which already has its coordinate.
    func choose(_ place: PlaceResult) async {
        await preview(Destination(name: place.name, subtitle: place.subtitle, coordinate: place.coordinate))
    }

    private func preview(_ destination: Destination) async {
        self.destination = destination
        routes = []
        phase = .previewing
        await loadRoutes()
    }

    func loadRoutes() async {
        guard let destination else { return }
        guard let origin = location.coordinate else {
            errorMessage = settings.language.pick("Waiting for GPS…", "Menunggu isyarat GPS…")
            return
        }
        isLoadingRoutes = true
        defer { isLoadingRoutes = false }
        do {
            let found = try await settings.makeRouter()
                .routes(from: origin, to: destination.coordinate, options: settings.routeOptions)
            guard phase == .previewing else { return }
            routes = found
            selectedRouteID = found.first?.id
            errorMessage = nil
            fitCamera(to: found)
        } catch {
            routes = []
            errorMessage = error.localizedDescription
        }
    }

    func cancelPreview() {
        routes = []
        selectedRouteID = nil
        destination = nil
        phase = .browsing
        recenter()
    }

    // MARK: - Navigation

    func startNavigation() {
        guard let route = selectedRoute else { return }
        routes = [route]
        selectedRouteID = route.id
        engine = NavigationEngine(route: route)
        planner = AnnouncementPlanner(language: settings.language)
        progress = nil
        hazardAhead = nil
        isFollowing = true
        phase = .navigating
        location.setNavigationMode(true)
        if let first = route.steps.first {
            speak(InstructionBuilder(language: settings.language).instruction(for: first))
        }
        if let last = location.lastLocation {
            locationDidUpdate(last)
        }
    }

    func stopNavigation() {
        endNavigation()
        voice.stop()
    }

    func recenter() {
        isFollowing = true
        if phase == .navigating, let last = location.lastLocation {
            followCamera(last)
        } else {
            withAnimation { camera = .userLocation(fallback: .region(.malaysia)) }
        }
    }

    func report(_ type: HazardType) {
        guard let last = location.lastLocation else { return }
        hazards.add(HazardReport(type: type, coordinate: Coordinate(last.coordinate),
                                 heading: last.course >= 0 ? last.course : nil))
    }

    private func endNavigation() {
        engine = nil
        planner = nil
        progress = nil
        hazardAhead = nil
        isRerouting = false
        routes = []
        selectedRouteID = nil
        destination = nil
        phase = .browsing
        location.setNavigationMode(false)
        recenter()
    }

    private func locationDidUpdate(_ fix: CLLocation) {
        if phase != .navigating { search.bias(to: fix) }
        guard phase == .navigating, var engine, var planner else { return }

        let progress = engine.update(location: Coordinate(fix.coordinate), accuracy: fix.horizontalAccuracy,
                                     course: fix.course >= 0 ? fix.course : nil, speed: max(fix.speed, 0))
        self.engine = engine
        self.progress = progress

        if camera.positionedByUser { isFollowing = false }
        if isFollowing { followCamera(fix) }

        if progress.hasArrived {
            // The planner normally says "you have arrived" just before; this catches a skipped prompt.
            if let text = planner.announcement(for: progress, engine: engine, speed: 0) { speak(text) }
            endNavigation()
            return
        }
        if progress.isOffRoute {
            Task { await reroute(from: fix) }
            return
        }

        if let text = planner.announcement(for: progress, engine: engine, speed: max(fix.speed, 0)) {
            speak(text)
        }
        let ahead = HazardLocator.hazardsAhead(of: progress.distanceAlong, on: engine.line, among: hazards.active())
        hazardAhead = ahead.first
        if let nearest = ahead.first, let text = planner.hazardAlert(nearest) {
            speak(text)
        }
        self.planner = planner
    }

    private func reroute(from fix: CLLocation) async {
        guard !isRerouting, Date().timeIntervalSince(lastRerouteAt) > 10, let destination else { return }
        isRerouting = true
        lastRerouteAt = Date()
        defer { isRerouting = false }
        if let text = planner?.recalculating() { speak(text) }

        let router = settings.makeRouter()
        let origin = Coordinate(fix.coordinate)
        var options = settings.routeOptions
        options.alternatives = false
        if fix.course >= 0, fix.speed > 2 { options.originBearing = fix.course }
        do {
            let found: [Route]
            do {
                found = try await router.routes(from: origin, to: destination.coordinate, options: options)
            } catch let error as RoutingError where error.isNoRoadMatch && options.originBearing != nil {
                // No road nearby goes the way the GPS says the car is heading: retry without the hint.
                options.originBearing = nil
                found = try await router.routes(from: origin, to: destination.coordinate, options: options)
            }
            guard phase == .navigating, let route = found.first else { return }
            routes = [route]
            selectedRouteID = route.id
            engine = NavigationEngine(route: route)
            planner?.routeChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Speech and camera

    private func speak(_ text: String) {
        guard settings.voiceEnabled else { return }
        voice.speak(text, language: settings.language)
    }

    /// Heading-up, tilted view that zooms out with speed.
    private func followCamera(_ fix: CLLocation) {
        let heading = fix.course >= 0 && fix.speed > 2 ? fix.course : (progress?.routeBearing ?? 0)
        let distance = 500 + min(max(fix.speed, 0), 30) * 30
        withAnimation(.easeInOut(duration: 0.9)) {
            camera = .camera(MapCamera(centerCoordinate: fix.coordinate, distance: distance, heading: heading, pitch: 50))
        }
    }

    private func fitCamera(to routes: [Route]) {
        let points = routes.flatMap(\.coordinates).map { MKMapPoint(CLLocationCoordinate2D($0)) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let width = maxX - minX, height = maxY - minY
        // Extra room at the bottom, where the route panel covers the map.
        let rect = MKMapRect(x: minX - width * 0.15, y: minY - height * 0.25,
                             width: width * 1.3, height: height * 1.9)
        withAnimation { camera = .rect(rect) }
    }
}
