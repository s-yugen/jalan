import Foundation
import Observation
import NavCore

enum RoutingProviderKind: String, CaseIterable, Identifiable {
    case osrm, mapbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .osrm: return "OpenStreetMap (OSRM)"
        case .mapbox: return "Mapbox (live traffic)"
        }
    }
}

/// User preferences, saved in UserDefaults.
@Observable
final class AppSettings {
    static let osrmDemoServer = "https://router.project-osrm.org"
    static let photonPublicServer = "https://photon.komoot.io"

    private let defaults = UserDefaults.standard

    var provider: RoutingProviderKind {
        get { access(keyPath: \.provider); return RoutingProviderKind(rawValue: read("provider", "")) ?? .osrm }
        set { withMutation(keyPath: \.provider) { defaults.set(newValue.rawValue, forKey: "provider") } }
    }

    var mapboxToken: String {
        get { access(keyPath: \.mapboxToken); return read("mapboxToken", "") }
        set {
            withMutation(keyPath: \.mapboxToken) {
                defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "mapboxToken")
            }
        }
    }

    var osrmServer: String {
        get { access(keyPath: \.osrmServer); return read("osrmServer", Self.osrmDemoServer) }
        set { withMutation(keyPath: \.osrmServer) { defaults.set(newValue, forKey: "osrmServer") } }
    }

    var language: NavLanguage {
        get { access(keyPath: \.language); return NavLanguage(rawValue: read("language", "")) ?? .english }
        set { withMutation(keyPath: \.language) { defaults.set(newValue.rawValue, forKey: "language") } }
    }

    var voiceEnabled: Bool {
        get { access(keyPath: \.voiceEnabled); return read("voiceEnabled", true) }
        set { withMutation(keyPath: \.voiceEnabled) { defaults.set(newValue, forKey: "voiceEnabled") } }
    }

    var avoidTolls: Bool {
        get { access(keyPath: \.avoidTolls); return read("avoidTolls", false) }
        set { withMutation(keyPath: \.avoidTolls) { defaults.set(newValue, forKey: "avoidTolls") } }
    }

    var avoidMotorways: Bool {
        get { access(keyPath: \.avoidMotorways); return read("avoidMotorways", false) }
        set { withMutation(keyPath: \.avoidMotorways) { defaults.set(newValue, forKey: "avoidMotorways") } }
    }

    // MARK: Place search

    var photonEnabled: Bool {
        get { access(keyPath: \.photonEnabled); return read("photonEnabled", true) }
        set { withMutation(keyPath: \.photonEnabled) { defaults.set(newValue, forKey: "photonEnabled") } }
    }

    var photonServer: String {
        get { access(keyPath: \.photonServer); return read("photonServer", Self.photonPublicServer) }
        set { withMutation(keyPath: \.photonServer) { defaults.set(newValue, forKey: "photonServer") } }
    }

    var nominatimEnabled: Bool {
        get { access(keyPath: \.nominatimEnabled); return read("nominatimEnabled", true) }
        set { withMutation(keyPath: \.nominatimEnabled) { defaults.set(newValue, forKey: "nominatimEnabled") } }
    }

    var openrouteserviceKey: String {
        get { access(keyPath: \.openrouteserviceKey); return read("openrouteserviceKey", "") }
        set { withMutation(keyPath: \.openrouteserviceKey) { saveKey(newValue, "openrouteserviceKey") } }
    }

    var stadiaKey: String {
        get { access(keyPath: \.stadiaKey); return read("stadiaKey", "") }
        set { withMutation(keyPath: \.stadiaKey) { saveKey(newValue, "stadiaKey") } }
    }

    var locationIQKey: String {
        get { access(keyPath: \.locationIQKey); return read("locationIQKey", "") }
        set { withMutation(keyPath: \.locationIQKey) { saveKey(newValue, "locationIQKey") } }
    }

    var mapTilerKey: String {
        get { access(keyPath: \.mapTilerKey); return read("mapTilerKey", "") }
        set { withMutation(keyPath: \.mapTilerKey) { saveKey(newValue, "mapTilerKey") } }
    }

    /// Services asked while the user types: Photon, and every keyed service that has a key.
    func makeTypingGeocoders() -> [WebGeocoder] {
        var backends: [GeocoderBackend] = []
        if photonEnabled {
            backends.append(URL(string: photonServer).map(GeocoderBackend.photon(baseURL:)) ?? .photonPublic)
        }
        if !openrouteserviceKey.isEmpty { backends.append(.openrouteservice(apiKey: openrouteserviceKey)) }
        if !stadiaKey.isEmpty { backends.append(.stadia(apiKey: stadiaKey)) }
        if !locationIQKey.isEmpty { backends.append(.locationIQ(apiKey: locationIQKey)) }
        if !mapTilerKey.isEmpty { backends.append(.mapTiler(apiKey: mapTilerKey)) }
        return backends.map { WebGeocoder(backend: $0) }
    }

    /// Nominatim's public server forbids search-as-you-type, so it's only asked on Search.
    func makeSubmitGeocoders() -> [WebGeocoder] {
        nominatimEnabled ? [WebGeocoder(backend: .nominatimPublic)] : []
    }

    var routeOptions: RouteOptions {
        RouteOptions(avoidTolls: avoidTolls, avoidMotorways: avoidMotorways)
    }

    /// True when Mapbox is chosen and usable; otherwise routing falls back to OSRM.
    var usesMapbox: Bool { provider == .mapbox && !mapboxToken.isEmpty }

    /// Swapping provider is just a different backend. Both speak the same API format.
    func makeRouter() -> any RoutingProvider {
        if usesMapbox {
            return OSRMCompatibleRouter(backend: .mapbox(accessToken: mapboxToken))
        }
        let url = URL(string: osrmServer) ?? URL(string: Self.osrmDemoServer)!
        return OSRMCompatibleRouter(backend: .osrm(baseURL: url))
    }

    private func saveKey(_ value: String, _ key: String) {
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }

    private func read<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }
}
