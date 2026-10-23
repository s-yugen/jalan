import MapKit
import Observation

/// Place search using Apple's POI data: free, no API key, decent coverage of Malaysian
/// malls, kopitiams, R&Rs and addresses.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var biasCenter: CLLocation?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = .malaysia
    }

    func update(query: String) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    /// Prefer places near the driver; the region is a hint, so far-off matches still appear.
    func bias(to location: CLLocation) {
        if let biasCenter, biasCenter.distance(from: location) < 5_000 { return }
        biasCenter = location
        completer.region = MKCoordinateRegion(center: location.coordinate,
                                              latitudinalMeters: 150_000, longitudinalMeters: 150_000)
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> MKMapItem? {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response.mapItems.first
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated { self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}
