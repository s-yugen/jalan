import MapKit
import SwiftUI
import NavCore

extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension Route {
    var mapCoordinates: [CLLocationCoordinate2D] {
        coordinates.map { CLLocationCoordinate2D($0) }
    }
}

extension MKCoordinateRegion {
    /// Peninsular Malaysia, Sabah and Sarawak.
    static let malaysia = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 4.0, longitude: 109.5),
        span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 20)
    )
}

/// Heading-up, tilted view that zooms out with speed. Shared by the phone and CarPlay maps.
struct FollowCamera {
    static let pitch: Double = 50

    let center: CLLocationCoordinate2D
    let heading: CLLocationDirection
    let distance: CLLocationDistance

    init(fix: CLLocation, routeBearing: Double?) {
        center = fix.coordinate
        heading = fix.course >= 0 && fix.speed > 2 ? fix.course : (routeBearing ?? 0)
        distance = 500 + min(max(fix.speed, 0), 30) * 30
    }
}

enum ManeuverSymbol {
    static func name(for maneuver: Maneuver) -> String {
        switch maneuver.type {
        case .arrive: return "flag.checkered"
        // Clockwise: Malaysia drives on the left.
        case .roundabout, .rotary, .roundaboutTurn: return "arrow.clockwise.circle"
        case .merge: return "arrow.merge"
        case .fork: return maneuver.modifier?.isLeft == true ? "arrow.up.left" : "arrow.up.right"
        default: break
        }
        switch maneuver.modifier {
        case .uturn: return "arrow.uturn.down"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .straight, nil: return "arrow.up"
        }
    }
}
