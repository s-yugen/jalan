import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RouteOptions: Sendable, Equatable {
    public var avoidTolls: Bool
    public var avoidMotorways: Bool
    public var alternatives: Bool

    public init(avoidTolls: Bool = false, avoidMotorways: Bool = false, alternatives: Bool = true) {
        self.avoidTolls = avoidTolls
        self.avoidMotorways = avoidMotorways
        self.alternatives = alternatives
    }
}

public protocol RoutingProvider: Sendable {
    func routes(from origin: Coordinate, to destination: Coordinate, options: RouteOptions) async throws -> [Route]
}

public enum RoutingError: Error, Equatable, LocalizedError {
    case noRoute
    case server(code: String, message: String?)
    case http(status: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .noRoute:
            return "No route found to this destination."
        case .server(code: "NoSegment", message: _):
            return "Couldn't find a road near the start or the destination."
        case .server(let code, let message):
            return message ?? "Routing failed (\(code))."
        case .http(status: 401), .http(status: 403):
            return "The routing service rejected the request. Check your Mapbox access token in Settings."
        case .http(status: 429):
            return "Too many routing requests. Wait a moment and try again."
        case .http(let status):
            return "Routing service error (HTTP \(status))."
        case .invalidResponse:
            return "Unexpected response from the routing service."
        }
    }
}

public enum RoutingBackend: Sendable, Equatable {
    /// Any OSRM server: the public demo, or your own built from a Malaysia OSM extract.
    case osrm(baseURL: URL)
    /// Mapbox Directions API with the live-traffic profile.
    case mapbox(accessToken: String)

    /// The public demo server. Fine for development; its usage policy forbids production traffic.
    public static let osrmDemo = RoutingBackend.osrm(baseURL: URL(string: "https://router.project-osrm.org")!)
}

/// Talks to OSRM or Mapbox Directions. Mapbox's API is OSRM-compatible (same request shape and
/// response JSON), so switching provider only changes the URL; parsing is shared.
public struct OSRMCompatibleRouter: RoutingProvider {
    public let backend: RoutingBackend
    private let session: URLSession

    public init(backend: RoutingBackend, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    public func routes(from origin: Coordinate, to destination: Coordinate, options: RouteOptions) async throws -> [Route] {
        let (data, response) = try await session.data(from: requestURL(from: origin, to: destination, options: options))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            return try Self.parse(data)
        } catch RoutingError.invalidResponse where !(200..<300).contains(status) {
            throw RoutingError.http(status: status)
        }
    }

    public func requestURL(from origin: Coordinate, to destination: Coordinate, options: RouteOptions) -> URL {
        let coordinates = String(format: "%.6f,%.6f;%.6f,%.6f",
                                 origin.longitude, origin.latitude, destination.longitude, destination.latitude)
        var query = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "alternatives", value: options.alternatives ? "true" : "false"),
        ]
        let base: String
        var exclude: [String] = []

        switch backend {
        case .osrm(let baseURL):
            var root = baseURL.absoluteString
            while root.hasSuffix("/") { root.removeLast() }
            base = "\(root)/route/v1/driving/\(coordinates)"
            // The stock OSRM car profile can only exclude one road class at a time. Malaysian tolled
            // roads are nearly all expressways tagged motorway, so avoiding motorways covers both.
            if options.avoidMotorways {
                exclude = ["motorway"]
            } else if options.avoidTolls {
                exclude = ["toll"]
            }
        case .mapbox(let token):
            base = "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/\(coordinates)"
            if options.avoidTolls { exclude.append("toll") }
            if options.avoidMotorways { exclude.append("motorway") }
            query.append(URLQueryItem(name: "access_token", value: token))
        }

        if !exclude.isEmpty {
            query.append(URLQueryItem(name: "exclude", value: exclude.joined(separator: ",")))
        }
        var components = URLComponents(string: base)!
        components.queryItems = query
        return components.url!
    }

    /// Parses an OSRM / Mapbox Directions v5 response.
    public static func parse(_ data: Data) throws -> [Route] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(ResponseDTO.self, from: data), let code = response.code else {
            throw RoutingError.invalidResponse
        }
        switch code {
        case "Ok": break
        case "NoRoute": throw RoutingError.noRoute
        default: throw RoutingError.server(code: code, message: response.message)
        }
        let routes = (response.routes ?? []).map(Route.init(dto:))
        if routes.isEmpty { throw RoutingError.noRoute }
        return routes
    }
}

// MARK: - Response format

private struct ResponseDTO: Decodable {
    let code: String?
    let message: String?
    let routes: [RouteDTO]?
}

private struct RouteDTO: Decodable {
    let distance: Double
    let duration: Double
    let geometry: LineStringDTO
    let legs: [LegDTO]
}

private struct LineStringDTO: Decodable {
    let coordinates: [[Double]]
}

private struct LegDTO: Decodable {
    let summary: String?
    let steps: [StepDTO]
}

private struct StepDTO: Decodable {
    let distance: Double
    let duration: Double
    let name: String?
    let ref: String?
    let destinations: String?
    let exits: String?
    let rotaryName: String?
    let geometry: LineStringDTO
    let maneuver: ManeuverDTO
    let intersections: [IntersectionDTO]?
}

private struct ManeuverDTO: Decodable {
    let type: String
    let modifier: String?
    let location: [Double]
    let bearingAfter: Double?
    let exit: Int?
}

private struct IntersectionDTO: Decodable {
    let classes: [String]?
}

private extension Route {
    init(dto: RouteDTO) {
        let summary = dto.legs.compactMap(\.summary).filter { !$0.isEmpty }.joined(separator: ", ")
        self.init(coordinates: dto.geometry.coordinates.compactMap(Coordinate.init(lonLat:)),
                  distance: dto.distance,
                  duration: dto.duration,
                  steps: dto.legs.flatMap(\.steps).map(RouteStep.init(dto:)),
                  summary: summary)
    }
}

private extension RouteStep {
    init(dto: StepDTO) {
        let coordinates = dto.geometry.coordinates.compactMap(Coordinate.init(lonLat:))
        let location = Coordinate(lonLat: dto.maneuver.location)
            ?? coordinates.first
            ?? Coordinate(latitude: 0, longitude: 0)
        let maneuver = Maneuver(type: ManeuverType(rawValue: dto.maneuver.type) ?? .unknown,
                                modifier: dto.maneuver.modifier.flatMap(ManeuverModifier.init(rawValue:)),
                                location: location,
                                bearingAfter: dto.maneuver.bearingAfter ?? 0,
                                exit: dto.maneuver.exit)
        self.init(maneuver: maneuver,
                  name: dto.name ?? "",
                  ref: dto.ref,
                  destinations: dto.destinations,
                  exits: dto.exits,
                  rotaryName: dto.rotaryName,
                  distance: dto.distance,
                  duration: dto.duration,
                  coordinates: coordinates,
                  isToll: dto.intersections?.contains { $0.classes?.contains("toll") == true } ?? false)
    }
}
