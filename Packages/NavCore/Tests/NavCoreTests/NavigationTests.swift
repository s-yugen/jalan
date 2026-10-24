import XCTest
import NavCore

final class NavigationTests: XCTestCase {
    private func point(_ lat: Double, _ lon: Double) -> Coordinate {
        Coordinate(latitude: lat, longitude: lon)
    }

    func testProgressHalfwayAlongFirstStep() {
        var engine = NavigationEngine(route: TestRoute.make())
        let p = engine.update(location: point(3.1501, 101.705))
        XCTAssertEqual(p.upcomingStepIndex, 1)
        XCTAssertEqual(p.distanceToUpcomingStep, 555, accuracy: 3)
        XCTAssertEqual(p.distanceFromRoute, 11.1, accuracy: 0.5)
        XCTAssertEqual(p.durationRemaining, 150, accuracy: 1)
        XCTAssertEqual(p.routeBearing, 90, accuracy: 0.1)
        XCTAssertFalse(p.isOffRoute)
        XCTAssertFalse(p.hasArrived)
    }

    func testOffRouteNeedsConsecutiveFixes() {
        var engine = NavigationEngine(route: TestRoute.make())
        _ = engine.update(location: point(3.15, 101.702))
        let away = point(3.152, 101.703) // ~220 m north of the route
        XCTAssertFalse(engine.update(location: away).isOffRoute)
        XCTAssertFalse(engine.update(location: away).isOffRoute)
        XCTAssertTrue(engine.update(location: away).isOffRoute)
        // Back on the road clears it.
        XCTAssertFalse(engine.update(location: point(3.15, 101.704)).isOffRoute)
    }

    func testHeadingAcrossTheRouteCountsAsOffRoute() {
        // On the road under a flyover: close to the route line, but driving north across it.
        var engine = NavigationEngine(route: TestRoute.make())
        _ = engine.update(location: point(3.15, 101.702), course: 90, speed: 15)
        XCTAssertFalse(engine.update(location: point(3.1501, 101.703), course: 0, speed: 15).isOffRoute)
        XCTAssertFalse(engine.update(location: point(3.1502, 101.703), course: 0, speed: 15).isOffRoute)
        XCTAssertTrue(engine.update(location: point(3.1503, 101.703), course: 0, speed: 15).isOffRoute)
        // Driving along the route again clears it.
        XCTAssertFalse(engine.update(location: point(3.15, 101.704), course: 85, speed: 15).isOffRoute)
    }

    func testHeadingIgnoredWhenSlowOrTurning() {
        var engine = NavigationEngine(route: TestRoute.make())
        _ = engine.update(location: point(3.15, 101.702), course: 90, speed: 15)
        for _ in 0..<5 {
            // Crawling in a jam, where GPS heading wanders.
            XCTAssertFalse(engine.update(location: point(3.15, 101.703), course: 0, speed: 2).isOffRoute)
        }
        for _ in 0..<5 {
            // ~22 m before the left turn, already swinging north.
            XCTAssertFalse(engine.update(location: point(3.15, 101.7098), course: 0, speed: 8).isOffRoute)
        }
    }

    func testArrival() {
        var engine = NavigationEngine(route: TestRoute.make())
        XCTAssertFalse(engine.update(location: point(3.159, 101.71)).hasArrived)
        XCTAssertTrue(engine.update(location: point(3.1599, 101.71)).hasArrived)
    }

    func testAnnouncementsSpokenOncePerTier() {
        var engine = NavigationEngine(route: TestRoute.make())
        var planner = AnnouncementPlanner(language: .english)
        func announce(at lon: Double) -> String? {
            let p = engine.update(location: point(3.15, lon))
            return planner.announcement(for: p, engine: engine, speed: 0)
        }
        XCTAssertNil(announce(at: 101.705))  // ~555 m out
        XCTAssertEqual(announce(at: 101.7078), "In 250 metres, turn left onto Jalan Tun Razak")  // ~244 m
        XCTAssertNil(announce(at: 101.7080))
        XCTAssertEqual(announce(at: 101.7098), "Turn left onto Jalan Tun Razak")  // ~22 m
        XCTAssertNil(announce(at: 101.7099))
    }

    func testHazardsAheadRespectDirection() {
        let line = RouteLine(TestRoute.make().coordinates)
        let eastbound = HazardReport(type: .accident, coordinate: point(3.1501, 101.706), heading: 90)
        let westbound = HazardReport(type: .police, coordinate: point(3.1501, 101.707), heading: 270)
        let behind = HazardReport(type: .pothole, coordinate: point(3.15, 101.7005))
        let offRoute = HazardReport(type: .flood, coordinate: point(3.155, 101.705))

        let ahead = HazardLocator.hazardsAhead(of: 100, on: line, among: [eastbound, westbound, behind, offRoute])
        XCTAssertEqual(ahead.map(\.report.id), [eastbound.id])
        XCTAssertEqual(ahead[0].distanceAhead, 566, accuracy: 3)

        var planner = AnnouncementPlanner(language: .malay)
        XCTAssertEqual(planner.hazardAlert(ahead[0]), "Kemalangan dilaporkan di hadapan, dalam 550 meter")
        XCTAssertNil(planner.hazardAlert(ahead[0]))
    }

    func testHazardExpiryAndDismissal() {
        let start = Date(timeIntervalSince1970: 0)
        var report = HazardReport(type: .jam, coordinate: point(3.15, 101.70), reportedAt: start)
        XCTAssertTrue(report.isActive(at: start.addingTimeInterval(20 * 60)))
        XCTAssertFalse(report.isActive(at: start.addingTimeInterval(31 * 60)))
        report.confirm(at: start.addingTimeInterval(25 * 60))
        XCTAssertTrue(report.isActive(at: start.addingTimeInterval(31 * 60)))
        report.dismiss()
        report.dismiss()
        XCTAssertFalse(report.isActive(at: start.addingTimeInterval(26 * 60)))
    }
}
