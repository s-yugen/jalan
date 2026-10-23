import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a search result came from. Apple Maps results are made in the app with MapKit;
/// every other source is a web service queried by `WebGeocoder`.
public enum PlaceSource: String, CaseIterable, Sendable, Identifiable {
    case apple, photon, openrouteservice, stadia, locationIQ, mapTiler, nominatim

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: return "Apple Maps"
        case .photon: return "Photon"
        case .openrouteservice: return "openrouteservice"
        case .stadia: return "Stadia Maps"
        case .locationIQ: return "LocationIQ"
        case .mapTiler: return "MapTiler"
        case .nominatim: return "Nominatim"
        }
    }
}

public struct PlaceResult: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var coordinate: Coordinate
    public var source: PlaceSource

    public init(id: String, name: String, subtitle: String, coordinate: Coordinate, source: PlaceSource) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.source = source
    }
}

public protocol Geocoder: Sendable {
    var source: PlaceSource { get }
    func search(_ query: String, near: Coordinate?) async throws -> [PlaceResult]
}

public enum GeocodingError: Error, Equatable, LocalizedError {
    case http(status: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .http(status: 401), .http(status: 403):
            return "The service rejected the API key. Check it in Settings."
        case .http(status: 429):
            return "Too many searches. Wait a moment and try again."
        case .http(let status):
            return "Search service error (HTTP \(status))."
        case .invalidResponse:
            return "Unexpected response from the search service."
        }
    }
}

/// The free place-search services. All of them search OpenStreetMap data (some add other open data).
public enum GeocoderBackend: Sendable, Equatable {
    /// Komoot's public server is free with no key, on a fair-use basis. Or run your own.
    case photon(baseURL: URL)
    /// Pelias, hosted by HeiGIT. Free API key.
    case openrouteservice(apiKey: String)
    /// Pelias, hosted by Stadia Maps. Free API key for non-commercial use.
    case stadia(apiKey: String)
    /// Free API key, with a daily request allowance.
    case locationIQ(apiKey: String)
    /// Free API key for non-commercial use.
    case mapTiler(apiKey: String)
    /// The public server forbids search-as-you-type, so only call it when the user presses Search.
    case nominatim(baseURL: URL)

    public static let photonPublic = GeocoderBackend.photon(baseURL: URL(string: "https://photon.komoot.io")!)
    public static let nominatimPublic = GeocoderBackend.nominatim(baseURL: URL(string: "https://nominatim.openstreetmap.org")!)

    public var source: PlaceSource {
        switch self {
        case .photon: return .photon
        case .openrouteservice: return .openrouteservice
        case .stadia: return .stadia
        case .locationIQ: return .locationIQ
        case .mapTiler: return .mapTiler
        case .nominatim: return .nominatim
        }
    }
}

public struct WebGeocoder: Geocoder {
    /// Peninsular Malaysia, Sabah and Sarawak: min longitude, min latitude, max longitude, max latitude.
    static let malaysiaBox = (minLon: 99.6, minLat: 0.8, maxLon: 119.3, maxLat: 7.4)
    /// Nominatim's usage policy asks apps to identify themselves.
    static let userAgent = "Jalan/1.0 (iOS navigation app; https://github.com/s-yugen/jalan)"

    public let backend: GeocoderBackend
    public let limit: Int
    private let session: URLSession

    public init(backend: GeocoderBackend, limit: Int = 8, session: URLSession = .shared) {
        self.backend = backend
        self.limit = limit
        self.session = session
    }

    public var source: PlaceSource { backend.source }

    public func search(_ query: String, near: Coordinate?) async throws -> [PlaceResult] {
        let (data, response) = try await session.data(for: request(for: query, near: near))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        // LocationIQ answers "nothing found" with a 404.
        if status == 404, case .locationIQ = backend { return [] }
        guard (200..<300).contains(status) else { throw GeocodingError.http(status: status) }
        let places = try Self.parse(data, from: source)
        return Array(places.prefix(limit))
    }

    public func request(for query: String, near: Coordinate?) -> URLRequest {
        let box = Self.malaysiaBox
        let limitItem = URLQueryItem(name: "limit", value: String(limit))
        let base: String
        var items: [URLQueryItem]

        switch backend {
        case .photon(let baseURL):
            base = Self.root(baseURL) + "/api/"
            items = [URLQueryItem(name: "q", value: query), limitItem,
                     URLQueryItem(name: "bbox", value: "\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat)")]
            if let near {
                items += [URLQueryItem(name: "lat", value: Self.format(near.latitude)),
                          URLQueryItem(name: "lon", value: Self.format(near.longitude))]
            }
        case .openrouteservice(let key), .stadia(let key):
            if case .stadia = backend {
                base = "https://api.stadiamaps.com/geocoding/v1/autocomplete"
            } else {
                base = "https://api.openrouteservice.org/geocode/autocomplete"
            }
            items = [URLQueryItem(name: "text", value: query), URLQueryItem(name: "api_key", value: key),
                     URLQueryItem(name: "boundary.country", value: "MY")]
            if let near {
                items += [URLQueryItem(name: "focus.point.lat", value: Self.format(near.latitude)),
                          URLQueryItem(name: "focus.point.lon", value: Self.format(near.longitude))]
            }
        case .locationIQ(let key):
            base = "https://api.locationiq.com/v1/autocomplete"
            items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "key", value: key), limitItem,
                     URLQueryItem(name: "countrycodes", value: "my"), URLQueryItem(name: "dedupe", value: "1")]
            if let near { items.append(Self.viewbox(around: near)) }
        case .mapTiler(let key):
            // The query goes in the path, so encode everything except ASCII unreserved characters
            // (Chinese and Tamil place names included).
            let unreserved = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let path = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            base = "https://api.maptiler.com/geocoding/\(path).json"
            items = [URLQueryItem(name: "key", value: key), limitItem,
                     URLQueryItem(name: "autocomplete", value: "true"),
                     URLQueryItem(name: "fuzzyMatch", value: "true"),
                     URLQueryItem(name: "country", value: "my")]
            if let near {
                items.append(URLQueryItem(name: "proximity",
                                          value: "\(Self.format(near.longitude)),\(Self.format(near.latitude))"))
            }
        case .nominatim(let baseURL):
            base = Self.root(baseURL) + "/search"
            items = [URLQueryItem(name: "q", value: query), limitItem,
                     URLQueryItem(name: "format", value: "jsonv2"),
                     URLQueryItem(name: "countrycodes", value: "my")]
            if let near { items.append(Self.viewbox(around: near)) }
        }

        var components = URLComponents(string: base)!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func parse(_ data: Data, from source: PlaceSource) throws -> [PlaceResult] {
        let decoder = JSONDecoder()
        do {
            switch source {
            case .photon:
                return try decoder.decode(FeatureCollection<PhotonProperties>.self, from: data).features
                    .compactMap(PlaceResult.init(photon:))
            case .openrouteservice, .stadia:
                return try decoder.decode(FeatureCollection<PeliasProperties>.self, from: data).features
                    .compactMap { PlaceResult(pelias: $0, source: source) }
            case .mapTiler:
                return try decoder.decode(MapTilerResponse.self, from: data).features
                    .compactMap(PlaceResult.init(mapTiler:))
            case .locationIQ, .nominatim:
                return try decoder.decode([OSMPlace].self, from: data)
                    .compactMap { PlaceResult(osm: $0, source: source) }
            case .apple:
                return []
            }
        } catch {
            throw GeocodingError.invalidResponse
        }
    }

    private static func root(_ url: URL) -> String {
        var root = url.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return root
    }

    private static func format(_ degrees: Double) -> String { String(format: "%.5f", degrees) }

    /// A box about 150 km across. Without `bounded=1` it ranks nearby places higher instead of filtering.
    private static func viewbox(around p: Coordinate) -> URLQueryItem {
        let d = 0.7
        return URLQueryItem(name: "viewbox", value: [p.longitude - d, p.latitude + d, p.longitude + d, p.latitude - d]
            .map(format).joined(separator: ","))
    }
}

// MARK: - Response formats

private struct FeatureCollection<Properties: Decodable>: Decodable {
    let features: [Feature<Properties>]
}

private struct Feature<Properties: Decodable>: Decodable {
    let geometry: PointDTO?
    let properties: Properties?

    enum CodingKeys: String, CodingKey { case geometry, properties }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A feature that isn't a point is skipped rather than failing the whole response.
        geometry = try? container.decodeIfPresent(PointDTO.self, forKey: .geometry)
        properties = try container.decodeIfPresent(Properties.self, forKey: .properties)
    }

    var coordinate: Coordinate? { geometry.flatMap { Coordinate(lonLat: $0.coordinates) } }
}

private struct PointDTO: Decodable {
    let coordinates: [Double]
}

private struct PhotonProperties: Decodable {
    let osmType: String?
    let osmId: Int?
    let name: String?
    let housenumber: String?
    let street: String?
    let district: String?
    let locality: String?
    let city: String?
    let county: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case osmType = "osm_type", osmId = "osm_id"
        case name, housenumber, street, district, locality, city, county, state
    }
}

private struct PeliasProperties: Decodable {
    let gid: String?
    let name: String?
    let label: String?
    let street: String?
    let neighbourhood: String?
    let locality: String?
    let region: String?
}

private struct MapTilerResponse: Decodable {
    let features: [MapTilerFeature]
}

/// MapTiler puts the names and a `center` point beside the geometry, which can be a polygon for areas.
private struct MapTilerFeature: Decodable {
    let id: String?
    let text: String?
    let placeName: String?
    let center: [Double]?

    enum CodingKeys: String, CodingKey { case id, text, placeName = "place_name", center }
}

/// Nominatim's jsonv2 and LocationIQ's autocomplete share this shape; coordinates are strings.
private struct OSMPlace: Decodable {
    let placeId: String?
    let lat: String
    let lon: String
    let name: String?
    let displayName: String?
    let displayPlace: String?
    let displayAddress: String?

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id", lat, lon, name
        case displayName = "display_name", displayPlace = "display_place", displayAddress = "display_address"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Nominatim sends place_id as a number, LocationIQ as a string.
        if let text = try? container.decodeIfPresent(String.self, forKey: .placeId) {
            placeId = text
        } else {
            placeId = try container.decodeIfPresent(Int.self, forKey: .placeId).map(String.init)
        }
        lat = try container.decode(String.self, forKey: .lat)
        lon = try container.decode(String.self, forKey: .lon)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        displayPlace = try container.decodeIfPresent(String.self, forKey: .displayPlace)
        displayAddress = try container.decodeIfPresent(String.self, forKey: .displayAddress)
    }
}

private extension PlaceResult {
    init?(photon feature: Feature<PhotonProperties>) {
        guard let p = feature.properties, let coordinate = feature.coordinate else { return nil }
        let street = [p.housenumber, p.street].compactMap { $0 }.joined(separator: " ")
        guard let name = Self.firstNonEmpty(p.name, street, p.locality, p.city) else { return nil }
        let subtitle = Self.join([p.name == nil ? nil : street, p.district ?? p.locality, p.city ?? p.county, p.state],
                                 excluding: name)
        let osmID = p.osmId.map { "\(p.osmType ?? "")\($0)" }
        self.init(id: "photon:\(osmID ?? Self.key(coordinate))", name: name, subtitle: subtitle,
                  coordinate: coordinate, source: .photon)
    }

    init?(pelias feature: Feature<PeliasProperties>, source: PlaceSource) {
        guard let p = feature.properties, let coordinate = feature.coordinate,
              let name = Self.firstNonEmpty(p.name, p.label) else { return nil }
        let subtitle = p.label.map { Self.dropPrefix(name, from: $0) }
            ?? Self.join([p.street, p.neighbourhood, p.locality, p.region], excluding: name)
        self.init(id: "\(source.rawValue):\(p.gid ?? Self.key(coordinate))",
                  name: name, subtitle: subtitle, coordinate: coordinate, source: source)
    }

    init?(mapTiler feature: MapTilerFeature) {
        guard let coordinate = feature.center.flatMap(Coordinate.init(lonLat:)),
              let name = Self.firstNonEmpty(feature.text, feature.placeName) else { return nil }
        self.init(id: "mapTiler:\(feature.id ?? Self.key(coordinate))", name: name,
                  subtitle: feature.placeName.map { Self.dropPrefix(name, from: $0) } ?? "",
                  coordinate: coordinate, source: .mapTiler)
    }

    init?(osm place: OSMPlace, source: PlaceSource) {
        guard let lat = Double(place.lat), let lon = Double(place.lon) else { return nil }
        let display = place.displayName ?? ""
        let firstPart = display.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = Self.firstNonEmpty(place.displayPlace, place.name, firstPart) else { return nil }
        let subtitle = place.displayAddress ?? Self.dropPrefix(name, from: display)
        let coordinate = Coordinate(latitude: lat, longitude: lon)
        self.init(id: "\(source.rawValue):\(place.placeId ?? Self.key(coordinate))", name: name, subtitle: subtitle,
                  coordinate: coordinate, source: source)
    }

    /// Fallback id for results without one.
    static func key(_ c: Coordinate) -> String { "\(c.latitude),\(c.longitude)" }

    static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// "Mid Valley Megamall, Kuala Lumpur, Malaysia" → "Kuala Lumpur, Malaysia"
    static func dropPrefix(_ name: String, from label: String) -> String {
        guard label.hasPrefix(name) else { return label }
        return String(label.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    }

    static func join(_ parts: [String?], excluding name: String) -> String {
        var seen: Set<String> = [name]
        return parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}
