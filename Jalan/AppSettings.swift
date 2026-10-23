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

    private func read<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }
}
