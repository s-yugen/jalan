import XCTest
import NavCore

final class GeoTests: XCTestCase {
    func testOneDegreeOfLatitude() {
        let d = Geo.distance(Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 1, longitude: 0))
        XCTAssertEqual(d, 111_195, accuracy: 1)
    }

    func testBearing() {
        let origin = Coordinate(latitude: 0, longitude: 0)
        XCTAssertEqual(Geo.bearing(from: origin, to: Coordinate(latitude: 1, longitude: 0)), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: origin, to: Coordinate(latitude: 0, longitude: 1)), 90, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: origin, to: Coordinate(latitude: 0, longitude: -1)), 270, accuracy: 0.01)
    }

    func testAngleBetween() {
        XCTAssertEqual(Geo.angleBetween(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(Geo.angleBetween(90, 270), 180, accuracy: 0.001)
    }

    func testSnapToLine() throws {
        let line = RouteLine([TestRoute.a, TestRoute.b, TestRoute.c])
        let snap = try XCTUnwrap(line.snap(Coordinate(latitude: 3.1501, longitude: 101.705)))
        XCTAssertEqual(snap.segment, 0)
        XCTAssertEqual(snap.offset, 11.1, accuracy: 0.5)
        XCTAssertEqual(snap.distanceAlong, line.cumulative[1] / 2, accuracy: 1)
    }

    func testCoordinateAtDistance() throws {
        let line = RouteLine([TestRoute.a, TestRoute.b, TestRoute.c])
        let corner = try XCTUnwrap(line.coordinate(at: line.cumulative[1]))
        XCTAssertEqual(Geo.distance(corner, TestRoute.b), 0, accuracy: 0.5)
        XCTAssertEqual(line.coordinate(at: 1e9), TestRoute.c)
    }
}
