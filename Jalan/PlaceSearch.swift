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
    /// The query last sent to Apple and the as-you-type services, so Search doesn't send it twice.
    @ObservationIgnored private var sentQuery: String?
    @ObservationIgnored private var typingTask: Task<Void, Never>?
    @ObservationIgnored private var submitTask: Task<Void, Never>?

    /// Nothing is sent until typing pauses this long (or Search is pressed): a request per
    /// keystroke wastes the free plans' rate limits on half-typed words.
    static let typingPause = Duration.seconds(1)
    /// Web services need at least this many letters; shorter queries match too much to be useful.
    private static let minimumWebQueryLength = 3

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
            sentQuery = nil
            completer.cancel()
            appleResults = []
            appleStatus = .done
            sections = []
            return
        }
        appleStatus = .searching

        let (typing, onSubmit) = geocoders()
        let web = webServices(typing)
        // Keep the previous results on screen until new ones arrive, so the list doesn't flicker.
        sections = web.map { section(for: $0.source, status: .searching) }
            + onSubmit.map { section(for: $0.source, status: .waitingForSubmit) }

        typingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled, let self else { return }
            await self.send(query, to: web)
        }
    }

    /// The Search key on the keyboard: sends the query now instead of waiting for the pause,
    /// and also asks the services that don't allow search-as-you-type.
    func submit() {
        guard !query.isEmpty else { return }
        let query = query
        let (typing, onSubmit) = geocoders()
        // Already sent after a pause: only the Search-only services are left to ask.
        let web = (sentQuery == query ? [] : webServices(typing)) + onSubmit
        if sentQuery != query { typingTask?.cancel() }
        for geocoder in onSubmit { setStatus(.searching, for: geocoder.source) }
        submitTask?.cancel()
        submitTask = Task { [weak self] in await self?.send(query, to: web) }
    }

    private func webServices(_ typing: [WebGeocoder]) -> [WebGeocoder] {
        query.count >= Self.minimumWebQueryLength ? typing : []
    }

    private func send(_ query: String, to web: [WebGeocoder]) async {
        if sentQuery != query {
            sentQuery = query
            completer.queryFragment = query
        }
        await ask(web, query: query)
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

    /// One round of search for CarPlay, whose list is filled in one go rather than as each service
    /// answers: Apple Maps first, then the web services asked while typing, a few places from each.
    func places(matching query: String, perSource: Int) async -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = completer.region
        let near = biasCenter.map { Coordinate($0.coordinate) }
        let typing = geocoders().typing

        async let fromWeb = Self.search(typing, query: query, near: near, perSource: perSource)
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        let fromApple = items.prefix(perSource).map { item in
            PlaceResult(id: "apple-\(item.placemark.coordinate.latitude),\(item.placemark.coordinate.longitude)",
                        name: item.name ?? "", subtitle: item.placemark.title ?? "",
                        coordinate: Coordinate(item.placemark.coordinate), source: .apple)
        }
        return fromApple + (await fromWeb)
    }

    /// Places from each service, in the order the services are given; a service that fails adds none.
    private nonisolated static func search(_ geocoders: [WebGeocoder], query: String, near: Coordinate?,
                                           perSource: Int) async -> [PlaceResult] {
        await withTaskGroup(of: (Int, [PlaceResult]).self) { group in
            for (index, geocoder) in geocoders.enumerated() {
                group.addTask { (index, (try? await geocoder.search(query, near: near)) ?? []) }
            }
            var found: [Int: [PlaceResult]] = [:]
            for await (index, places) in group { found[index] = Array(places.prefix(perSource)) }
            return geocoders.indices.flatMap { found[$0] ?? [] }
        }
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
