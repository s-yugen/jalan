import Foundation
import Observation
import NavCore

/// Hazard reports, saved on the device.
///
/// MVP: reports stay on this phone. To share them between drivers (the core of a Waze-like app),
/// send `add`/`confirm`/`dismiss` to a backend and load nearby reports from it. See README.
@MainActor
@Observable
final class HazardStore {
    private(set) var reports: [HazardReport] = []

    private let fileURL = URL.applicationSupportDirectory.appending(path: "hazards.json")

    init() {
        load()
    }

    func active(at date: Date = .now) -> [HazardReport] {
        reports.filter { $0.isActive(at: date) }
    }

    func add(_ report: HazardReport) {
        reports.append(report)
        save()
    }

    func confirm(_ id: HazardReport.ID) {
        update(id) { $0.confirm() }
    }

    func dismiss(_ id: HazardReport.ID) {
        update(id) { $0.dismiss() }
    }

    private func update(_ id: HazardReport.ID, _ change: (inout HazardReport) -> Void) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        change(&reports[index])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([HazardReport].self, from: data) else { return }
        reports = saved.filter { $0.isActive() }
    }

    private func save() {
        reports.removeAll { !$0.isActive() }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(reports).write(to: fileURL, options: .atomic)
    }
}
