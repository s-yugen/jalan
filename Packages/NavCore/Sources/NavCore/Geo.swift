import Foundation

/// A WGS84 coordinate. NavCore uses its own type instead of `CLLocationCoordinate2D`
/// so the navigation logic builds and tests without CoreLocation.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// From a GeoJSON / OSRM `[longitude, latitude]` pair.
    init?(lonLat: [Double]) {
        guard lonLat.count >= 2 else { return nil }
        self.init(latitude: lonLat[1], longitude: lonLat[0])
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLat = lat2 - lat1
        let dLon = radians(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b` in degrees clockwise from north, 0..<360.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest angle between two bearings, 0...180.
    public static func angleBetween(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    public static func interpolate(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                   longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Closest point to `p` on the segment `a`–`b`. Uses a local flat-earth projection,
    /// which is accurate to well under a metre at road-segment lengths.
    public static func project(_ p: Coordinate, ontoSegment a: Coordinate, _ b: Coordinate)
        -> (point: Coordinate, fraction: Double, distance: Double)
    {
        let k = cos(radians(p.latitude))
        let ax = (a.longitude - p.longitude) * k, ay = a.latitude - p.latitude
        let bx = (b.longitude - p.longitude) * k, by = b.latitude - p.latitude
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(1, max(0, -(ax * dx + ay * dy) / lengthSquared))
        let point = interpolate(a, b, t)
        return (point, t, distance(p, point))
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}

/// A route polyline with precomputed distances, for snapping GPS fixes onto it.
public struct RouteLine: Sendable {
    public let coordinates: [Coordinate]
    /// `cumulative[i]` is the distance in metres from the start to `coordinates[i]`.
    public let cumulative: [Double]

    public struct Snap: Sendable, Equatable {
        public let point: Coordinate
        /// Index of the first vertex of the segment the point lies on.
        public let segment: Int
        public let distanceAlong: Double
        /// Distance from the query point to the line.
        public let offset: Double
    }

    public init(_ coordinates: [Coordinate]) {
        self.coordinates = coordinates
        var cumulative: [Double] = []
        cumulative.reserveCapacity(coordinates.count)
        var total = 0.0
        for i in coordinates.indices {
            if i > 0 { total += Geo.distance(coordinates[i - 1], coordinates[i]) }
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    public var length: Double { cumulative.last ?? 0 }

    /// Nearest point on the line to `p`. With a `hint` (the previous distance along the line),
    /// only segments from `hint - behind` to `hint + ahead` are searched, so a road that loops
    /// back near itself doesn't make the driver jump to a later part of the route.
    public func snap(_ p: Coordinate, near hint: Double? = nil, behind: Double = 50, ahead: Double = 2_000) -> Snap? {
        guard coordinates.count >= 2 else {
            return coordinates.first.map { Snap(point: $0, segment: 0, distanceAlong: 0, offset: Geo.distance(p, $0)) }
        }
        let low = hint.map { $0 - behind } ?? -.infinity
        let high = hint.map { $0 + ahead } ?? .infinity
        var best: Snap?
        for i in 0..<(coordinates.count - 1) {
            if cumulative[i + 1] < low { continue }
            if cumulative[i] > high { break }
            let r = Geo.project(p, ontoSegment: coordinates[i], coordinates[i + 1])
            if best == nil || r.distance < best!.offset {
                let along = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * r.fraction
                best = Snap(point: r.point, segment: i, distanceAlong: along, offset: r.distance)
            }
        }
        return best
    }

    /// The point `distance` metres from the start of the line.
    public func coordinate(at distance: Double) -> Coordinate? {
        guard let first = coordinates.first else { return nil }
        if distance <= 0 { return first }
        if distance >= length { return coordinates.last }
        var low = 0, high = cumulative.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if cumulative[mid] <= distance { low = mid } else { high = mid }
        }
        let segmentLength = cumulative[high] - cumulative[low]
        let t = segmentLength > 0 ? (distance - cumulative[low]) / segmentLength : 0
        return Geo.interpolate(coordinates[low], coordinates[high], t)
    }

    /// Direction of travel along segment `i`.
    public func bearing(ofSegment i: Int) -> Double {
        guard i >= 0, i + 1 < coordinates.count else { return 0 }
        return Geo.bearing(from: coordinates[i], to: coordinates[i + 1])
    }
}
