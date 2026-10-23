import Foundation

public enum HazardType: String, Codable, CaseIterable, Sendable {
    case accident, police, roadblock, flood, pothole, jam, stalledVehicle, roadWorks

    public func title(_ language: NavLanguage) -> String {
        switch self {
        case .accident: return language.pick("Accident", "Kemalangan")
        case .police: return language.pick("Police", "Polis")
        case .roadblock: return language.pick("Roadblock", "Sekatan jalan raya")
        case .flood: return language.pick("Flood", "Banjir")
        case .pothole: return language.pick("Pothole", "Lubang jalan")
        case .jam: return language.pick("Traffic jam", "Kesesakan lalu lintas")
        case .stalledVehicle: return language.pick("Stalled vehicle", "Kenderaan rosak")
        case .roadWorks: return language.pick("Road works", "Kerja jalan raya")
        }
    }

    /// How long a report stays on the map without being confirmed again.
    public var lifetime: TimeInterval {
        let hour: TimeInterval = 3_600
        switch self {
        case .jam: return 0.5 * hour
        case .stalledVehicle: return 0.75 * hour
        case .accident, .police: return hour
        case .roadblock: return 2 * hour
        case .flood: return 6 * hour
        case .roadWorks: return 7 * 24 * hour
        case .pothole: return 14 * 24 * hour
        }
    }
}

public struct HazardReport: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var type: HazardType
    public var coordinate: Coordinate
    /// Direction the reporter was driving, so a hazard on one carriageway
    /// isn't announced to drivers going the other way.
    public var heading: Double?
    public var reportedAt: Date
    public var lastConfirmedAt: Date
    public var confirmations: Int
    public var dismissals: Int

    public init(type: HazardType, coordinate: Coordinate, heading: Double? = nil,
                reportedAt: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.type = type
        self.coordinate = coordinate
        self.heading = heading
        self.reportedAt = reportedAt
        self.lastConfirmedAt = reportedAt
        self.confirmations = 1
        self.dismissals = 0
    }

    public var expiresAt: Date { lastConfirmedAt.addingTimeInterval(type.lifetime) }

    /// Active until it expires, or until more drivers say it's gone than say it's there.
    public func isActive(at date: Date = Date()) -> Bool {
        date < expiresAt && dismissals < confirmations
    }

    public mutating func confirm(at date: Date = Date()) {
        confirmations += 1
        lastConfirmedAt = date
    }

    public mutating func dismiss() {
        dismissals += 1
    }
}

public struct HazardAhead: Sendable, Equatable {
    public let report: HazardReport
    public let distanceAhead: Double
}

public enum HazardLocator {
    /// Reports on the route ahead of `distanceAlong`, nearest first.
    /// - Parameter corridor: max metres between a report and the route line.
    public static func hazardsAhead(of distanceAlong: Double, on line: RouteLine, among reports: [HazardReport],
                                    within range: Double = 2_000, corridor: Double = 40) -> [HazardAhead] {
        guard let here = line.coordinate(at: distanceAlong) else { return [] }
        return reports.compactMap { report -> HazardAhead? in
            guard Geo.distance(here, report.coordinate) <= range + corridor,
                  let snap = line.snap(report.coordinate, near: distanceAlong, behind: 0, ahead: range),
                  snap.offset <= corridor,
                  snap.distanceAlong > distanceAlong
            else { return nil }
            if let heading = report.heading,
               Geo.angleBetween(heading, line.bearing(ofSegment: snap.segment)) > 60 {
                return nil
            }
            return HazardAhead(report: report, distanceAhead: snap.distanceAlong - distanceAlong)
        }
        .sorted { $0.distanceAhead < $1.distanceAhead }
    }
}
