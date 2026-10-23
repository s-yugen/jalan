import MapKit
import Observation
import NavCore

/// Searches Apple Maps and the free OpenStreetMap-based services at the same time. Each source's
/// results are kept apart so the search screen can list them side by side.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    enum Status: Equatable {
        case searching, done, failed(String)
        /// Nominatim's public server is only asked when the user presses Search.
        case waitingForSubmit
    }

    struct Section: Identifiable {
        let source: PlaceSource
        var status: Status
        var places: [PlaceResult] = []

        var id: PlaceSource { source }
    }

    /// Apple's suggestions, resolved to a coordinate only when one is chosen.
    private(set) var appleResults: [MKLocalSearchCompletion] = []
    private(set) var appleStatus: Status = .done
    /// One section per web service, in the order of `PlaceSource.allCases`.
    private(set) var sections: [Section] = []

    /// Set by `AppModel`: the services to ask while typing, and those to ask on Search.
    @ObservationIgnored var geocoders: () -> (typing: [WebGeocoder], onSubmit: [WebGeocoder]) = { ([], []) }

    private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var biasCenter: CLLocation?
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var typingTask: Task<Void, Never>?
    @ObservationIgnored private var submitTask: Task<Void, Never>?

    /// Web services are asked once the query is this long, and after a pause in typing,
    /// to stay within the free plans' rate limits.
    private static let minimumWebQueryLength = 3
    private static let typingPause = Duration.milliseconds(400)

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = .malaysia
    }

    func update(query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query != self.query else { return }
        self.query = query
        typingTask?.cancel()
        submitTask?.cancel()

        guard !query.isEmpty else {
            completer.cancel()
            appleResults = []
            appleStatus = .done
            sections = []
            return
        }
        appleStatus = .searching
        completer.queryFragment = query

        let (typing, onSubmit) = geocoders()
        let asksTyping = query.count >= Self.minimumWebQueryLength
        // Keep the previous results on screen until new ones arrive, so the list doesn't flicker.
        sections = (asksTyping ? typing : []).map { section(for: $0.source, status: .searching) }
            + onSubmit.map { section(for: $0.source, status: .waitingForSubmit) }
        guard asksTyping, !typing.isEmpty else { return }

        typingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            await self?.ask(typing, query: query)
        }
    }

    /// The Search key on the keyboard: also asks the services that don't allow search-as-you-type.
    func submit() {
        guard !query.isEmpty else { return }
        let onSubmit = geocoders().onSubmit
        guard !onSubmit.isEmpty else { return }
        for geocoder in onSubmit { setStatus(.searching, for: geocoder.source) }
        submitTask?.cancel()
        let query = query
        submitTask = Task { [weak self] in await self?.ask(onSubmit, query: query) }
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

    /// Asks every service at once and fills in each section as its answer arrives.
    private func ask(_ geocoders: [WebGeocoder], query: String) async {
        let near = biasCenter.map { Coordinate($0.coordinate) }
        await withTaskGroup(of: (PlaceSource, Result<[PlaceResult], Error>).self) { group in
            for geocoder in geocoders {
                group.addTask {
                    do {
                        return (geocoder.source, .success(try await geocoder.search(query, near: near)))
                    } catch {
                        return (geocoder.source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                guard !Task.isCancelled, query == self.query,
                      let index = sections.firstIndex(where: { $0.source == source }) else { continue }
                switch result {
                case .success(let places):
                    sections[index].places = places
                    sections[index].status = .done
                case .failure(let error):
                    sections[index].places = []
                    sections[index].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func section(for source: PlaceSource, status: Status) -> Section {
        Section(source: source, status: status, places: sections.first { $0.source == source }?.places ?? [])
    }

    private func setStatus(_ status: Status, for source: PlaceSource) {
        guard let index = sections.firstIndex(where: { $0.source == source }) else { return }
        sections[index].status = status
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated {
            self.appleResults = results
            self.appleStatus = .done
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Apple reports "nothing found" as an error; anything else (offline, throttled) is shown.
        let notFound = (error as? MKError)?.code == .placemarkNotFound
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.appleResults = []
            self.appleStatus = notFound ? .done : .failed(message)
        }
    }
}
