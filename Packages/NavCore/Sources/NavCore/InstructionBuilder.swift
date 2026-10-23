import Foundation

/// Turns route steps into English or Malay instructions.
///
/// OSRM returns maneuvers but no instruction text, and Mapbox has no Malay. Writing the text
/// here gives both providers the same wording in both languages.
public struct InstructionBuilder: Sendable {
    public var language: NavLanguage

    public init(language: NavLanguage) {
        self.language = language
    }

    private var malay: Bool { language == .malay }

    /// Instruction for the banner, e.g. "Turn left onto Jalan Tun Razak (FT1)".
    public func instruction(for step: RouteStep) -> String {
        let m = step.maneuver
        let road = Self.roadName(step)

        switch m.type {
        case .depart:
            let direction = cardinal(m.bearingAfter)
            return malay ? "Menuju ke \(direction)" + on(road) : "Head \(direction)" + on(road)

        case .arrive:
            if m.modifier?.isLeft == true {
                return malay ? "Destinasi anda di sebelah kiri" : "Your destination is on the left"
            }
            if m.modifier?.isRight == true {
                return malay ? "Destinasi anda di sebelah kanan" : "Your destination is on the right"
            }
            return malay ? "Anda telah tiba di destinasi" : "You have arrived at your destination"

        case .roundabout, .rotary:
            let place = step.rotaryName.flatMap { $0.isEmpty ? nil : $0 } ?? (malay ? "bulatan" : "the roundabout")
            if let exit = m.exit {
                return malay
                    ? "Di \(place), ambil susur keluar \(ordinal(exit))" + onto(road)
                    : "At \(place), take the \(ordinal(exit)) exit" + onto(road)
            }
            return malay ? "Masuk ke \(place)" : "Enter \(place)"

        case .exitRoundabout, .exitRotary:
            return (malay ? "Keluar dari bulatan" : "Exit the roundabout") + onto(road)

        case .offRamp:
            let text: String
            if let exits = step.exits, !exits.isEmpty {
                let number = exits.replacingOccurrences(of: ";", with: "/")
                text = malay ? "Ambil susur keluar \(number)" : "Take exit \(number)"
            } else {
                text = malay ? "Ambil susur keluar" : "Take the exit"
            }
            return text + towardsOrOnto(step, road)

        case .onRamp:
            return (malay ? "Ambil susur masuk" : "Take the ramp") + towardsOrOnto(step, road)

        case .fork:
            let text: String
            if let side = side(m.modifier) {
                text = malay ? "Ikut \(side) di simpang" : "Keep \(side) at the fork"
            } else {
                text = malay ? "Teruskan di simpang" : "Continue at the fork"
            }
            return text + towardsOrOnto(step, road)

        case .merge:
            if malay { return "Bergabung" + onto(road) }
            return "Merge" + (side(m.modifier).map { " \($0)" } ?? "") + onto(road)

        case .endOfRoad:
            return (malay ? "Di hujung jalan, " : "At the end of the road, ")
                + Self.lowercasedFirst(turn(m.modifier)) + onto(road)

        case .newName:
            return (malay ? "Teruskan" : "Continue") + onto(road)

        case .turn, .continue, .roundaboutTurn, .notification, .useLane, .unknown:
            if m.modifier == nil || m.modifier == .straight {
                if m.type == .turn { return turn(.straight) + onto(road) }
                return (malay ? "Teruskan perjalanan" : "Continue") + on(road)
            }
            return turn(m.modifier) + onto(road)
        }
    }

    /// Voice prompt, e.g. "In 400 metres, turn left onto Jalan Tun Razak".
    /// Pass `nil` for the prompt spoken right at the maneuver.
    public func spoken(_ step: RouteStep, in distance: Double?) -> String {
        let text = instruction(for: step)
        guard let distance else { return text }
        let d = DistanceFormatter.spoken(distance, language: language)
        if step.maneuver.type == .arrive {
            return malay ? "Dalam \(d), anda akan tiba di destinasi" : "In \(d), you will arrive at your destination"
        }
        return (malay ? "Dalam \(d), " : "In \(d), ") + Self.lowercasedFirst(text)
    }

    /// "Jalan Tun Razak (FT1)", "Jalan Duta", "E1", or nil for unnamed roads.
    public static func roadName(_ step: RouteStep) -> String? {
        let name = step.name.trimmingCharacters(in: .whitespaces)
        let ref = (step.ref ?? "").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
        switch (name.isEmpty, ref.isEmpty) {
        case (false, false): return name.contains(ref) ? name : "\(name) (\(ref))"
        case (false, true): return name
        case (true, false): return ref
        case (true, true): return nil
        }
    }

    // MARK: - Pieces

    private func on(_ road: String?) -> String {
        guard let road else { return "" }
        return malay ? " di \(road)" : " on \(road)"
    }

    private func onto(_ road: String?) -> String {
        guard let road else { return "" }
        return malay ? " ke \(road)" : " onto \(road)"
    }

    private func towardsOrOnto(_ step: RouteStep, _ road: String?) -> String {
        if let destinations = step.destinations, !destinations.isEmpty {
            return malay ? " ke arah \(destinations)" : " towards \(destinations)"
        }
        return onto(road)
    }

    private func turn(_ modifier: ManeuverModifier?) -> String {
        switch modifier {
        case .uturn: return malay ? "Buat pusingan U" : "Make a U-turn"
        case .sharpLeft: return malay ? "Belok tajam ke kiri" : "Turn sharp left"
        case .left: return malay ? "Belok kiri" : "Turn left"
        case .slightLeft: return malay ? "Belok sedikit ke kiri" : "Bear left"
        case .sharpRight: return malay ? "Belok tajam ke kanan" : "Turn sharp right"
        case .right: return malay ? "Belok kanan" : "Turn right"
        case .slightRight: return malay ? "Belok sedikit ke kanan" : "Bear right"
        case .straight, nil: return malay ? "Terus" : "Continue straight"
        }
    }

    private func side(_ modifier: ManeuverModifier?) -> String? {
        if modifier?.isLeft == true { return malay ? "kiri" : "left" }
        if modifier?.isRight == true { return malay ? "kanan" : "right" }
        return nil
    }

    private func cardinal(_ bearing: Double) -> String {
        let english = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let malayNames = ["utara", "timur laut", "timur", "tenggara", "selatan", "barat daya", "barat", "barat laut"]
        let index = Int(((bearing + 22.5) / 45).rounded(.down)) % 8
        return (malay ? malayNames : english)[(index + 8) % 8]
    }

    private func ordinal(_ n: Int) -> String {
        if malay { return n == 1 ? "pertama" : "ke-\(n)" }
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
