import Foundation

/// Language for voice guidance, instructions and UI text.
public enum NavLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case malay = "ms"

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .malay: return "Bahasa Melayu"
        }
    }

    /// Text-to-speech voice identifier.
    public var voiceCode: String {
        switch self {
        case .english: return "en-GB"
        case .malay: return "ms-MY"
        }
    }

    public func pick(_ english: String, _ malay: String) -> String {
        self == .malay ? malay : english
    }
}

public enum DistanceFormatter {
    /// Short form for the screen: "40 m", "450 m", "1.2 km", "23 km".
    public static func string(_ metres: Double) -> String {
        let r = rounded(metres)
        return r.isKilometres ? "\(number(r.value)) km" : "\(Int(r.value)) m"
    }

    /// Long form for voice: "450 metres" / "450 meter".
    public static func spoken(_ metres: Double, language: NavLanguage) -> String {
        let r = rounded(metres)
        let n = r.isKilometres ? number(r.value) : String(Int(r.value))
        switch language {
        case .english:
            if r.isKilometres { return r.value == 1 ? "1 kilometre" : "\(n) kilometres" }
            return "\(n) metres"
        case .malay:
            return r.isKilometres ? "\(n) kilometer" : "\(n) meter"
        }
    }

    static func rounded(_ metres: Double) -> (value: Double, isKilometres: Bool) {
        let m = max(0, metres)
        if m < 100 { return ((m / 10).rounded() * 10, false) }
        if m < 975 { return ((m / 50).rounded() * 50, false) }
        let km = m / 1000
        return (km < 10 ? (km * 10).rounded() / 10 : km.rounded(), true)
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

public enum DurationFormatter {
    /// "8 min", "1 h 25 min" / "1 jam 25 min".
    public static func string(_ seconds: TimeInterval, language: NavLanguage) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        let unit = language.pick("h", "jam")
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) \(unit)" : "\(hours) \(unit) \(rest) min"
    }
}
