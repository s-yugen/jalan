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

extension HazardType {
    var symbol: String {
        switch self {
        case .accident: return "car.side.rear.and.collision.and.car.side.front"
        case .police: return "shield.lefthalf.filled"
        case .roadblock: return "xmark.octagon.fill"
        case .flood: return "water.waves"
        case .pothole: return "exclamationmark.circle.fill"
        case .jam: return "car.2.fill"
        case .stalledVehicle: return "car.fill"
        case .roadWorks: return "hammer.fill"
        }
    }

    var color: Color {
        switch self {
        case .accident: return .red
        case .police: return .blue
        case .roadblock: return .purple
        case .flood: return .teal
        case .pothole: return .brown
        case .jam: return .orange
        case .stalledVehicle: return .gray
        case .roadWorks: return Color(red: 0.85, green: 0.6, blue: 0)
        }
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
