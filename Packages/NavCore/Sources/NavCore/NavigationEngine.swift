import Foundation

public struct NavigationProgress: Sendable, Equatable {
    public var snappedLocation: Coordinate
    /// Metres between the GPS fix and the route.
    public var distanceFromRoute: Double
    public var distanceAlong: Double
    /// Direction of the route where the driver is, degrees from north.
    public var routeBearing: Double
    /// Index into `route.steps` of the next maneuver.
    public var upcomingStepIndex: Int
    public var distanceToUpcomingStep: Double
    public var distanceRemaining: Double
    public var durationRemaining: TimeInterval
    public var isOffRoute: Bool
    public var hasArrived: Bool
}

/// Follows the driver along a route: snaps GPS fixes to it, works out the next maneuver,
/// remaining distance and time, and decides when the driver has left the route.
public struct NavigationEngine: Sendable {
    public let route: Route
    public let line: RouteLine
    /// Distance along `line` at which each step's maneuver happens.
    public let maneuverDistances: [Double]

    /// How far (metres) from the route a fix may be before it counts as off route.
    public var offRouteThreshold: Double = 50
    /// Consecutive off-route fixes needed before rerouting, to ride out GPS spikes
    /// (common under flyovers and between KL tower blocks).
    public var offRouteConfirmations = 3
    /// A fix close to the route still counts as off route when the car heads this many degrees
    /// away from the road's direction: the road under a flyover, a crossing road, the other carriageway.
    public var offRouteHeadingThreshold: Double = 60
    /// Below this speed (m/s) the GPS heading is too noisy to compare.
    public var headingCheckMinimumSpeed: Double = 5
    /// The heading isn't compared this close (metres along the route) to a maneuver, where the car is mid-turn.
    public var headingCheckManeuverMargin: Double = 40
    public var arrivalThreshold: Double = 30

    private var lastAlong: Double?
    private var offRouteStreak = 0

    public init(route: Route) {
        self.route = route
        let line = RouteLine(route.coordinates)
        self.line = line
        // Step distances come from the same geometry; scaling removes any rounding drift.
        let scale = route.distance > 0 ? line.length / route.distance : 1
        var along = 0.0
        var distances: [Double] = []
        for step in route.steps {
            distances.append(min(along * scale, line.length))
            along += step.distance
        }
        maneuverDistances = distances
    }

    /// - Parameters:
    ///   - course: GPS heading in degrees from north, or nil when the GPS doesn't know it.
    ///   - speed: metres per second.
    public mutating func update(location: Coordinate, accuracy: Double = 10,
                                course: Double? = nil, speed: Double = 0) -> NavigationProgress {
        let tolerance = max(offRouteThreshold, min(max(accuracy, 0), 100) * 1.5)
        var snap = line.snap(location, near: lastAlong)
            ?? RouteLine.Snap(point: location, segment: 0, distanceAlong: 0, offset: 0)
        if lastAlong != nil, snap.offset > tolerance, let global = line.snap(location), global.offset < snap.offset {
            // GPS jumped, or the previous position went stale: search the whole route.
            snap = global
        }

        // Before the driver first reaches the route (e.g. still in a car park), be lenient.
        let limit = lastAlong == nil ? max(tolerance, 200) : tolerance
        if snap.offset > limit || headsAway(course: course, speed: speed, at: snap.distanceAlong) {
            offRouteStreak += 1
        } else {
            offRouteStreak = 0
            lastAlong = snap.distanceAlong
        }
        let isOffRoute = offRouteStreak >= offRouteConfirmations

        let along = snap.distanceAlong
        let steps = route.steps
        let upcoming = maneuverDistances.firstIndex { $0 > along + 1 } ?? max(steps.count - 1, 0)
        let toUpcoming = steps.isEmpty ? line.length - along : max(0, maneuverDistances[upcoming] - along)

        var duration = 0.0
        if !steps.isEmpty {
            if upcoming > 0 {
                let current = upcoming - 1
                let length = maneuverDistances[upcoming] - maneuverDistances[current]
                let fraction = length > 0 ? min(1, toUpcoming / length) : 0
                duration += steps[current].duration * fraction
            }
            duration += steps[upcoming...].reduce(0) { $0 + $1.duration }
        }

        let remaining = max(0, line.length - along)
        let nearEnd = route.coordinates.last.map { Geo.distance(location, $0) <= arrivalThreshold } ?? false
        let arrived = nearEnd || (remaining <= arrivalThreshold && snap.offset <= tolerance)

        return NavigationProgress(
            snappedLocation: snap.point,
            distanceFromRoute: snap.offset,
            distanceAlong: along,
            routeBearing: line.bearing(ofSegment: snap.segment),
            upcomingStepIndex: upcoming,
            distanceToUpcomingStep: toUpcoming,
            distanceRemaining: remaining,
            durationRemaining: duration,
            isOffRoute: isOffRoute,
            hasArrived: arrived
        )
    }

    /// True when the car is clearly not driving along the route where it was matched to it.
    private func headsAway(course: Double?, speed: Double, at along: Double) -> Bool {
        guard let course, course >= 0, speed >= headingCheckMinimumSpeed else { return false }
        if maneuverDistances.contains(where: { abs($0 - along) < headingCheckManeuverMargin }) { return false }
        // On a roundabout the road keeps curving, and the GPS heading lags behind it.
        if let current = maneuverDistances.lastIndex(where: { $0 <= along }),
           [.roundabout, .rotary, .roundaboutTurn].contains(route.steps[current].maneuver.type) {
            return false
        }
        // The road's direction over a short stretch, so a kink in the line doesn't count.
        guard let behind = line.coordinate(at: along - 15), let ahead = line.coordinate(at: along + 15),
              behind != ahead else { return false }
        return Geo.angleBetween(course, Geo.bearing(from: behind, to: ahead)) > offRouteHeadingThreshold
    }
}
