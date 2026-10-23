import Foundation

/// Maneuver types as defined by the OSRM / Mapbox Directions v5 response format.
public enum ManeuverType: String, Sendable {
    case depart, arrive, turn, `continue`, merge, fork, roundabout, rotary, notification
    case newName = "new name"
    case onRamp = "on ramp"
    case offRamp = "off ramp"
    case endOfRoad = "end of road"
    case roundaboutTurn = "roundabout turn"
    case exitRoundabout = "exit roundabout"
    case exitRotary = "exit rotary"
    case useLane = "use lane"
    case unknown
}

public enum ManeuverModifier: String, Sendable {
    case uturn, right, straight, left
    case sharpRight = "sharp right"
    case slightRight = "slight right"
    case slightLeft = "slight left"
    case sharpLeft = "sharp left"

    public var isLeft: Bool { self == .left || self == .slightLeft || self == .sharpLeft }
    public var isRight: Bool { self == .right || self == .slightRight || self == .sharpRight }
}

public struct Maneuver: Sendable, Equatable {
    public var type: ManeuverType
    public var modifier: ManeuverModifier?
    public var location: Coordinate
    /// Direction of travel right after the maneuver, degrees from north.
    public var bearingAfter: Double
    /// Roundabout exit number, counting from 1.
    public var exit: Int?

    public init(type: ManeuverType, modifier: ManeuverModifier? = nil, location: Coordinate,
                bearingAfter: Double = 0, exit: Int? = nil) {
        self.type = type
        self.modifier = modifier
        self.location = location
        self.bearingAfter = bearingAfter
        self.exit = exit
    }
}

/// One instruction: the maneuver, then the stretch of road driven until the next maneuver.
public struct RouteStep: Sendable, Equatable {
    public var maneuver: Maneuver
    /// Road name, e.g. "Jalan Tun Razak". May be empty.
    public var name: String
    /// Road number, e.g. "E1" or "FT2". OSRM separates several with ";".
    public var ref: String?
    /// Signposted destinations, e.g. "Shah Alam, Klang".
    public var destinations: String?
    /// Exit number(s) for an off-ramp.
    public var exits: String?
    public var rotaryName: String?
    public var distance: Double
    public var duration: TimeInterval
    public var coordinates: [Coordinate]
    /// The step passes through a tolled road (OSRM/Mapbox intersection class "toll").
    public var isToll: Bool

    public init(maneuver: Maneuver, name: String = "", ref: String? = nil, destinations: String? = nil,
                exits: String? = nil, rotaryName: String? = nil, distance: Double, duration: TimeInterval,
                coordinates: [Coordinate] = [], isToll: Bool = false) {
        self.maneuver = maneuver
        self.name = name
        self.ref = ref
        self.destinations = destinations
        self.exits = exits
        self.rotaryName = rotaryName
        self.distance = distance
        self.duration = duration
        self.coordinates = coordinates
        self.isToll = isToll
    }
}

public struct Route: Identifiable, Sendable {
    public let id: UUID
    public var coordinates: [Coordinate]
    /// Metres.
    public var distance: Double
    /// Seconds. Includes live traffic only when the provider supports it (Mapbox driving-traffic).
    public var duration: TimeInterval
    public var steps: [RouteStep]
    /// Main roads used, e.g. "Federal Highway, Jalan Tun Razak".
    public var summary: String

    public var hasTolls: Bool { steps.contains { $0.isToll } }

    public init(id: UUID = UUID(), coordinates: [Coordinate], distance: Double, duration: TimeInterval,
                steps: [RouteStep], summary: String = "") {
        self.id = id
        self.coordinates = coordinates
        self.distance = distance
        self.duration = duration
        self.steps = steps
        self.summary = summary
    }
}
