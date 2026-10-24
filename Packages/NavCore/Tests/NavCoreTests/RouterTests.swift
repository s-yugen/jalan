import XCTest
import NavCore

final class RouterTests: XCTestCase {
    private let from = Coordinate(latitude: 3.15, longitude: 101.70)
    private let to = Coordinate(latitude: 3.1579, longitude: 101.7123)

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testOSRMURL() {
        let router = OSRMCompatibleRouter(backend: .osrm(baseURL: URL(string: "https://osrm.example.my/")!))
        let url = router.requestURL(from: from, to: to, options: RouteOptions(avoidTolls: true))
        // Compare the string: Foundation may treat ";" in a path as a parameter separator.
        XCTAssertTrue(url.absoluteString.hasPrefix(
            "https://osrm.example.my/route/v1/driving/101.700000,3.150000;101.712300,3.157900?"))
        XCTAssertEqual(query(url)["exclude"], "toll")
        XCTAssertEqual(query(url)["geometries"], "geojson")
        XCTAssertNil(query(url)["access_token"])
    }

    func testOSRMExcludesOnlyOneClass() {
        let router = OSRMCompatibleRouter(backend: .osrmDemo)
        let url = router.requestURL(from: from, to: to, options: RouteOptions(avoidTolls: true, avoidMotorways: true))
        XCTAssertEqual(query(url)["exclude"], "motorway")
    }

    func testMapboxURL() {
        let router = OSRMCompatibleRouter(backend: .mapbox(accessToken: "pk.test"))
        let url = router.requestURL(from: from, to: to, options: RouteOptions(avoidTolls: true, avoidMotorways: true))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://api.mapbox.com/directions/v5/mapbox/driving-traffic/"))
        XCTAssertEqual(query(url)["exclude"], "toll,motorway")
        XCTAssertEqual(query(url)["access_token"], "pk.test")
    }

    func testOriginBearing() {
        let osrm = OSRMCompatibleRouter(backend: .osrmDemo)
        XCTAssertNil(query(osrm.requestURL(from: from, to: to, options: RouteOptions()))["bearings"])
        let east = osrm.requestURL(from: from, to: to, options: RouteOptions(originBearing: 90.4))
        XCTAssertEqual(query(east)["bearings"], "90,45;")
        let north = OSRMCompatibleRouter(backend: .mapbox(accessToken: "pk.test"))
            .requestURL(from: from, to: to, options: RouteOptions(originBearing: 359.7))
        XCTAssertEqual(query(north)["bearings"], "0,45;")
    }

    func testNoRoadMatch() {
        XCTAssertTrue(RoutingError.noRoute.isNoRoadMatch)
        XCTAssertTrue(RoutingError.server(code: "NoSegment", message: "Could not find a matching segment").isNoRoadMatch)
        XCTAssertFalse(RoutingError.http(status: 429).isNoRoadMatch)
    }

    func testParseResponse() throws {
        let routes = try OSRMCompatibleRouter.parse(Data(Self.sampleResponse.utf8))
        XCTAssertEqual(routes.count, 1)
        let route = routes[0]
        XCTAssertEqual(route.coordinates.count, 3)
        XCTAssertEqual(route.coordinates[0], Coordinate(latitude: 3.15, longitude: 101.70))
        XCTAssertEqual(route.distance, 1222.2, accuracy: 0.01)
        XCTAssertEqual(route.summary, "Jalan Ampang, Jalan Tun Razak")
        XCTAssertEqual(route.steps.count, 3)
        XCTAssertEqual(route.steps[0].maneuver.type, .depart)
        XCTAssertEqual(route.steps[0].maneuver.bearingAfter, 90)
        XCTAssertEqual(route.steps[1].maneuver.type, .turn)
        XCTAssertEqual(route.steps[1].maneuver.modifier, .left)
        XCTAssertEqual(route.steps[1].ref, "FT1")
        XCTAssertEqual(route.steps[2].maneuver.type, .arrive)
        XCTAssertTrue(route.hasTolls)
    }

    func testParseNoRoute() {
        let data = Data(#"{"code":"NoRoute","message":"Impossible route between points"}"#.utf8)
        XCTAssertThrowsError(try OSRMCompatibleRouter.parse(data)) { error in
            XCTAssertEqual(error as? RoutingError, .noRoute)
        }
    }

    func testParseMapboxAuthError() {
        // Mapbox answers a bad token with a message but no code.
        let data = Data(#"{"message":"Not Authorized - Invalid Token"}"#.utf8)
        XCTAssertThrowsError(try OSRMCompatibleRouter.parse(data)) { error in
            XCTAssertEqual(error as? RoutingError, .invalidResponse)
        }
    }

    static let sampleResponse = """
    {
      "code": "Ok",
      "routes": [{
        "distance": 1222.2, "duration": 200,
        "geometry": {"type": "LineString", "coordinates": [[101.70, 3.15], [101.71, 3.15], [101.71, 3.16]]},
        "legs": [{
          "summary": "Jalan Ampang, Jalan Tun Razak", "distance": 1222.2, "duration": 200,
          "steps": [
            {
              "distance": 1110.3, "duration": 100, "name": "Jalan Ampang", "ref": "",
              "geometry": {"type": "LineString", "coordinates": [[101.70, 3.15], [101.71, 3.15]]},
              "maneuver": {"type": "depart", "location": [101.70, 3.15], "bearing_before": 0, "bearing_after": 90},
              "intersections": [{"location": [101.70, 3.15], "classes": ["toll"]}]
            },
            {
              "distance": 111.9, "duration": 100, "name": "Jalan Tun Razak", "ref": "FT1",
              "geometry": {"type": "LineString", "coordinates": [[101.71, 3.15], [101.71, 3.16]]},
              "maneuver": {"type": "turn", "modifier": "left", "location": [101.71, 3.15], "bearing_before": 90, "bearing_after": 0},
              "intersections": [{"location": [101.71, 3.15]}]
            },
            {
              "distance": 0, "duration": 0, "name": "Jalan Tun Razak",
              "geometry": {"type": "LineString", "coordinates": [[101.71, 3.16], [101.71, 3.16]]},
              "maneuver": {"type": "arrive", "location": [101.71, 3.16], "bearing_before": 0, "bearing_after": 0}
            }
          ]
        }]
      }],
      "waypoints": []
    }
    """
}
