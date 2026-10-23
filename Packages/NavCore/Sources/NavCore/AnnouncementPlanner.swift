import Foundation

/// Decides what to say and when: each maneuver is announced at most once per tier
/// (early on highways, "prepare" a few hundred metres out, and "now" at the turn).
public struct AnnouncementPlanner: Sendable {
    public var builder: InstructionBuilder

    private enum Tier: Hashable { case early, prepare, now }
    private struct Key: Hashable {
        let step: Int
        let tier: Tier
    }

    private var spoken: Set<Key> = []
    private var alertedHazards: Set<UUID> = []

    public init(language: NavLanguage) {
        builder = InstructionBuilder(language: language)
    }

    /// Call after a reroute: step indices refer to the new route.
    public mutating func routeChanged() {
        spoken.removeAll()
    }

    /// - Parameter speed: metres per second.
    public mutating func announcement(for progress: NavigationProgress, engine: NavigationEngine, speed: Double) -> String? {
        let index = progress.upcomingStepIndex
        guard engine.route.steps.indices.contains(index) else { return nil }
        let step = engine.route.steps[index]
        let distance = progress.distanceToUpcomingStep
        let legLength = index > 0 ? engine.maneuverDistances[index] - engine.maneuverDistances[index - 1] : distance

        // Scale with speed: about 5 s and 20 s before the maneuver.
        let v = max(0, speed)
        let nowDistance = min(max(v * 5, 30), 150)
        let prepareDistance = min(max(v * 20, 250), 800)

        if distance <= nowDistance {
            return say(index, .now, builder.spoken(step, in: nil))
        }
        if distance <= prepareDistance {
            // Skip when the previous maneuver was moments ago; its "now" prompt just played.
            guard legLength > prepareDistance + 100 else { return nil }
            return say(index, .prepare, builder.spoken(step, in: distance))
        }
        // Early warning on long expressway stretches at speed (> ~60 km/h).
        if distance <= 2_000, distance > prepareDistance + 200, legLength > 3_000, v > 16 {
            return say(index, .early, builder.spoken(step, in: distance))
        }
        return nil
    }

    public mutating func hazardAlert(_ hazard: HazardAhead) -> String? {
        guard hazard.distanceAhead <= 1_000, alertedHazards.insert(hazard.report.id).inserted else { return nil }
        let name = hazard.report.type.title(builder.language)
        let d = DistanceFormatter.spoken(hazard.distanceAhead, language: builder.language)
        return builder.language.pick("\(name) reported ahead, in \(d)", "\(name) dilaporkan di hadapan, dalam \(d)")
    }

    public func recalculating() -> String {
        builder.language.pick("Recalculating route", "Mengira semula laluan")
    }

    private mutating func say(_ step: Int, _ tier: Tier, _ text: String) -> String? {
        spoken.insert(Key(step: step, tier: tier)).inserted ? text : nil
    }
}
