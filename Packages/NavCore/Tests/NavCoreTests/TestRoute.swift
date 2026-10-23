import NavCore

/// An L-shaped route in KL: east along latitude 3.15 for ~1.1 km, then left (north) for ~1.1 km.
enum TestRoute {
    static let a = Coordinate(latitude: 3.15, longitude: 101.70)
    static let b = Coordinate(latitude: 3.15, longitude: 101.71)
    static let c = Coordinate(latitude: 3.16, longitude: 101.71)

    static func make() -> Route {
        let ab = Geo.distance(a, b), bc = Geo.distance(b, c)
        let steps = [
            RouteStep(maneuver: Maneuver(type: .depart, location: a, bearingAfter: 90),
                      name: "Jalan Ampang", distance: ab, duration: 100),
            RouteStep(maneuver: Maneuver(type: .turn, modifier: .left, location: b, bearingAfter: 0),
                      name: "Jalan Tun Razak", distance: bc, duration: 100),
            RouteStep(maneuver: Maneuver(type: .arrive, location: c),
                      name: "Jalan Tun Razak", distance: 0, duration: 0),
        ]
        return Route(coordinates: [a, b, c], distance: ab + bc, duration: 200, steps: steps)
    }
}
