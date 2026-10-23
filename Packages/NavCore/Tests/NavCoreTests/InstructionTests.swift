import XCTest
import NavCore

final class InstructionTests: XCTestCase {
    private let english = InstructionBuilder(language: .english)
    private let malay = InstructionBuilder(language: .malay)
    private let here = Coordinate(latitude: 3.15, longitude: 101.70)

    private func step(_ type: ManeuverType, _ modifier: ManeuverModifier? = nil, name: String = "",
                      ref: String? = nil, exit: Int? = nil, bearing: Double = 0,
                      destinations: String? = nil, exits: String? = nil) -> RouteStep {
        RouteStep(maneuver: Maneuver(type: type, modifier: modifier, location: here, bearingAfter: bearing, exit: exit),
                  name: name, ref: ref, destinations: destinations, exits: exits, distance: 100, duration: 10)
    }

    func testTurn() {
        let s = step(.turn, .left, name: "Jalan Tun Razak", ref: "FT1")
        XCTAssertEqual(english.instruction(for: s), "Turn left onto Jalan Tun Razak (FT1)")
        XCTAssertEqual(malay.instruction(for: s), "Belok kiri ke Jalan Tun Razak (FT1)")
    }

    func testDepart() {
        let s = step(.depart, name: "Jalan Ampang", bearing: 90)
        XCTAssertEqual(english.instruction(for: s), "Head east on Jalan Ampang")
        XCTAssertEqual(malay.instruction(for: s), "Menuju ke timur di Jalan Ampang")
    }

    func testRoundabout() {
        let s = step(.roundabout, .right, name: "Jalan Duta", exit: 2)
        XCTAssertEqual(english.instruction(for: s), "At the roundabout, take the 2nd exit onto Jalan Duta")
        XCTAssertEqual(malay.instruction(for: s), "Di bulatan, ambil susur keluar ke-2 ke Jalan Duta")
    }

    func testOffRamp() {
        let s = step(.offRamp, .slightLeft, name: "Lebuhraya Persekutuan", destinations: "Shah Alam, Klang", exits: "1102")
        XCTAssertEqual(english.instruction(for: s), "Take exit 1102 towards Shah Alam, Klang")
        XCTAssertEqual(malay.instruction(for: s), "Ambil susur keluar 1102 ke arah Shah Alam, Klang")
    }

    func testRefOnlyRoad() {
        let s = step(.merge, .slightRight, ref: "E1;AH2")
        XCTAssertEqual(english.instruction(for: s), "Merge right onto E1")
    }

    func testSpoken() {
        let s = step(.turn, .right, name: "Jalan Sultan Ismail")
        XCTAssertEqual(english.spoken(s, in: 437), "In 450 metres, turn right onto Jalan Sultan Ismail")
        XCTAssertEqual(malay.spoken(s, in: 437), "Dalam 450 meter, belok kanan ke Jalan Sultan Ismail")
        XCTAssertEqual(english.spoken(s, in: nil), "Turn right onto Jalan Sultan Ismail")
    }

    func testArrive() {
        XCTAssertEqual(english.instruction(for: step(.arrive, .left)), "Your destination is on the left")
        XCTAssertEqual(malay.spoken(step(.arrive), in: 200), "Dalam 200 meter, anda akan tiba di destinasi")
    }

    func testDistanceFormatting() {
        XCTAssertEqual(DistanceFormatter.string(37), "40 m")
        XCTAssertEqual(DistanceFormatter.string(449), "450 m")
        XCTAssertEqual(DistanceFormatter.string(980), "1 km")
        XCTAssertEqual(DistanceFormatter.string(1_234), "1.2 km")
        XCTAssertEqual(DistanceFormatter.string(23_600), "24 km")
        XCTAssertEqual(DistanceFormatter.spoken(1_000, language: .english), "1 kilometre")
        XCTAssertEqual(DistanceFormatter.spoken(2_500, language: .malay), "2.5 kilometer")
    }

    func testDurationFormatting() {
        XCTAssertEqual(DurationFormatter.string(480, language: .english), "8 min")
        XCTAssertEqual(DurationFormatter.string(5_100, language: .english), "1 h 25 min")
        XCTAssertEqual(DurationFormatter.string(7_200, language: .malay), "2 jam")
    }
}
