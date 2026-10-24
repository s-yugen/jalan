import UIKit
import CarPlay
import MapKit
import Observation
import NavCore

/// The car's screen: the map and its buttons, search, route choices, turn-by-turn guidance and
/// hazard alerts. It runs on the same `AppModel` as the phone, so a destination chosen or a trip
/// started on either screen shows on both.
@MainActor
final class CarPlayController: NSObject, CPMapTemplateDelegate, CPSearchTemplateDelegate {
    private let model: AppModel
    private let interfaceController: CPInterfaceController
    private let map: CarPlayMapViewController
    private let mapTemplate: CPMapTemplate
    private var recenterButton: CPMapButton?

    /// Set when CarPlay disconnects, to stop following the model.
    private var isStopped = false

    // What the car's screen shows now, so CarPlay is only updated when the model changes it.
    private var shownBarButtons: String?
    private var previewTrip: CPTrip?
    private var previewRouteIDs: [Route.ID] = []
    private var trip: CPTrip?
    private var session: CPNavigationSession?
    private var shownManeuvers: ManeuverKey?
    private var pausedFor: PauseReason?
    private var shownHazard: HazardAhead?
    /// Hazards already warned about, or asked about, on this trip. GPS jitter can drop a hazard
    /// from "ahead" for a moment, and it shouldn't pop up again when it comes back.
    private var warnedHazards: Set<HazardReport.ID> = []
    private var askedHazards: Set<HazardReport.ID> = []
    private var shownError: String?

    private var searchTask: Task<Void, Never>?
    private var searchResults: [CPListItem] = []
    private var lastPanTranslation = CGPoint.zero

    private struct ManeuverKey: Equatable {
        let routeID: Route.ID
        let stepIndex: Int
    }

    private var language: NavLanguage { model.settings.language }

    init(model: AppModel, interfaceController: CPInterfaceController, window: CPWindow) {
        self.model = model
        self.interfaceController = interfaceController
        map = CarPlayMapViewController(model: model)
        mapTemplate = CPMapTemplate()
        super.init()

        window.rootViewController = map
        mapTemplate.mapDelegate = self
        // Malaysian road-sign green, as on the phone's turn banner.
        mapTemplate.guidanceBackgroundColor = UIColor(red: 0, green: 0.42, blue: 0.29, alpha: 1)
        mapTemplate.mapButtons = makeMapButtons()
        map.onFollowingChange = { [weak self] isFollowing in
            self?.recenterButton?.isHidden = isFollowing
        }
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)
        observe()
    }

    func disconnect() {
        isStopped = true
        map.stop()
        searchTask?.cancel()
    }

    // MARK: - Following the model

    private func observe() {
        guard !isStopped else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        updateBarButtons()
        switch model.phase {
        case .browsing:
            endTrip()
            hidePreview()
        case .previewing:
            endTrip()
            updatePreview()
        case .navigating:
            updateGuidance()
        }
        updateHazardAlert()
        updateErrorAlert()
    }

    // MARK: - Buttons

    private func makeMapButtons() -> [CPMapButton] {
        let recenter = mapButton("location.fill") { [weak self] in self?.map.recenter() }
        recenter.isHidden = map.isFollowing
        recenterButton = recenter
        return [
            recenter,
            mapButton("plus.magnifyingglass") { [weak self] in self?.map.zoom(by: 0.5) },
            mapButton("minus.magnifyingglass") { [weak self] in self?.map.zoom(by: 2) },
            mapButton("arrow.up.and.down.and.arrow.left.and.right") { [weak self] in
                self?.mapTemplate.showPanningInterface(animated: true)
            },
        ]
    }

    private func mapButton(_ systemImage: String, action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        button.image = UIImage(systemName: systemImage)
        return button
    }

    private func barButton(_ title: String, action: @escaping () -> Void) -> CPBarButton {
        CPBarButton(title: title) { _ in action() }
    }

    private func updateBarButtons() {
        let lang = language
        let isPanning = mapTemplate.isPanningInterfaceVisible
        let key = "\(model.phase) \(lang.rawValue) \(isPanning)"
        guard key != shownBarButtons else { return }
        shownBarButtons = key

        let report = barButton(lang.pick("Report", "Lapor")) { [weak self] in self?.showReport() }
        if isPanning {
            mapTemplate.leadingNavigationBarButtons = []
            mapTemplate.trailingNavigationBarButtons = [barButton(lang.pick("Done", "Selesai")) { [weak self] in
                self?.mapTemplate.dismissPanningInterface(animated: true)
            }]
            return
        }
        switch model.phase {
        case .browsing:
            mapTemplate.leadingNavigationBarButtons = [barButton(lang.pick("Where to?", "Ke mana?")) { [weak self] in
                self?.showSearch()
            }]
            mapTemplate.trailingNavigationBarButtons = [report]
        case .previewing:
            mapTemplate.leadingNavigationBarButtons = [barButton(lang.pick("Cancel", "Batal")) { [weak self] in
                self?.model.cancelPreview()
            }]
            mapTemplate.trailingNavigationBarButtons = []
        case .navigating:
            mapTemplate.leadingNavigationBarButtons = [report]
            mapTemplate.trailingNavigationBarButtons = [barButton(lang.pick("End", "Tamat")) { [weak self] in
                self?.model.stopNavigation()
            }]
        }
    }

    // MARK: - Search

    private func showSearch() {
        let search = CPSearchTemplate()
        search.delegate = self
        searchResults = []
        interfaceController.pushTemplate(search, animated: true, completion: nil)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3 else {
            searchResults = []
            completionHandler([])
            return
        }
        searchTask = Task {
            // Wait for a pause in typing, to stay within the free services' rate limits.
            // A search overtaken by more typing keeps the previous results on screen.
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled {
                completionHandler(self.searchResults)
                return
            }
            let places = await self.model.search.places(matching: query, perSource: 4)
            if Task.isCancelled {
                completionHandler(self.searchResults)
                return
            }
            self.searchResults = places.map { place in
                let detail = [place.subtitle, place.source.title].filter { !$0.isEmpty }.joined(separator: " · ")
                let item = CPListItem(text: place.name, detailText: detail)
                item.userInfo = place
                return item
            }
            completionHandler(self.searchResults)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let place = item.userInfo as? PlaceResult else { return }
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        Task { await model.choose(place) }
    }

    // MARK: - Hazard reports

    private func showReport() {
        let lang = language
        let buttons = HazardType.allCases.map { type in
            CPGridButton(titleVariants: [type.title(lang)], image: hazardImage(type)) { [weak self] _ in
                self?.model.report(type)
                self?.interfaceController.popTemplate(animated: true, completion: nil)
            }
        }
        // Eight hazard types: exactly what fits on a CarPlay grid.
        let grid = CPGridTemplate(title: lang.pick("Report here", "Laporkan di sini"), gridButtons: buttons)
        interfaceController.pushTemplate(grid, animated: true, completion: nil)
    }

    private func hazardImage(_ type: HazardType) -> UIImage {
        let image = UIImage(systemName: type.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 32))
        return image?.withTintColor(UIColor(type.color), renderingMode: .alwaysOriginal) ?? UIImage()
    }

    /// Warns of a hazard on the road ahead; once the driver has passed it, asks whether it's still there.
    private func updateHazardAlert() {
        let ahead = model.phase == .navigating ? model.hazardAhead : nil
        let previous = shownHazard
        shownHazard = ahead
        let lang = language

        if let ahead, ahead.report.id != previous?.report.id, !warnedHazards.contains(ahead.report.id) {
            warnedHazards.insert(ahead.report.id)
            let distance = DistanceFormatter.string(ahead.distanceAhead)
            let ok = CPAlertAction(title: "OK", style: .cancel) { _ in }
            present(CPNavigationAlert(titleVariants: [ahead.report.type.title(lang)],
                                      subtitleVariants: [lang.pick("\(distance) ahead", "\(distance) di hadapan")],
                                      image: hazardImage(ahead.report.type),
                                      primaryAction: ok, secondaryAction: nil, duration: 8))
        } else if let previous, ahead?.report.id != previous.report.id,
                  previous.distanceAhead < 200, model.phase == .navigating,
                  !askedHazards.contains(previous.report.id) {
            let passed = previous.report
            let id = passed.id
            askedHazards.insert(id)
            let yes = CPAlertAction(title: lang.pick("Still there", "Masih ada"), style: .default) { [weak self] _ in
                self?.model.hazards.confirm(id)
            }
            let no = CPAlertAction(title: lang.pick("Not there", "Sudah tiada"), style: .cancel) { [weak self] _ in
                self?.model.hazards.dismiss(id)
            }
            present(CPNavigationAlert(titleVariants: [passed.type.title(lang)],
                                      subtitleVariants: [lang.pick("Is it still there?", "Masih ada lagi?")],
                                      image: hazardImage(passed.type),
                                      primaryAction: yes, secondaryAction: no, duration: 10))
        }
    }

    private func present(_ alert: CPNavigationAlert) {
        if mapTemplate.currentNavigationAlert != nil {
            mapTemplate.dismissNavigationAlert(animated: false) { _ in }
        }
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func updateErrorAlert() {
        let message = model.errorMessage
        guard message != shownError else { return }
        if shownError != nil {
            interfaceController.dismissTemplate(animated: false, completion: nil)
        }
        shownError = message
        guard let message else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            // Clearing the message dismisses the alert on the next render.
            self?.model.errorMessage = nil
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: [message], actions: [ok]),
                                            animated: true, completion: nil)
    }

    // MARK: - Route choices

    private func updatePreview() {
        let routes = model.routes
        guard routes.map(\.id) != previewRouteIDs else { return }
        guard let destination = model.destination, let first = routes.first else {
            hidePreview()
            return
        }
        let lang = language
        let trip = makeTrip(to: destination, routes: routes)
        previewTrip = trip
        previewRouteIDs = routes.map(\.id)
        mapTemplate.showTripPreviews([trip], textConfiguration: CPTripPreviewTextConfiguration(
            startButtonTitle: lang.pick("Go", "Mula"),
            additionalRoutesButtonTitle: lang.pick("More routes", "Laluan lain"),
            overviewButtonTitle: lang.pick("Overview", "Gambaran keseluruhan")))
        mapTemplate.updateEstimates(estimates(first.distance, first.duration), for: trip)
    }

    private func hidePreview() {
        guard previewTrip != nil else { return }
        mapTemplate.hideTripPreviews()
        previewTrip = nil
        previewRouteIDs = []
    }

    private func makeTrip(to destination: Destination, routes: [Route]) -> CPTrip {
        let lang = language
        let choices = routes.map { route in
            let distance = DistanceFormatter.string(route.distance)
            let via = route.summary.isEmpty ? distance : lang.pick("via ", "melalui ") + route.summary
            var details = "\(DurationFormatter.string(route.duration, language: lang)) · \(distance)"
            if route.hasTolls { details += lang.pick(" · Toll", " · Tol") }
            let choice = CPRouteChoice(summaryVariants: [via], additionalInformationVariants: [details],
                                       selectionSummaryVariants: [details])
            choice.userInfo = route.id
            return choice
        }
        let end = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(destination.coordinate)))
        end.name = destination.name
        return CPTrip(origin: MKMapItem.forCurrentLocation(), destination: end, routeChoices: choices)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        guard let id = routeChoice.userInfo as? Route.ID,
              let route = model.routes.first(where: { $0.id == id }) else { return }
        model.selectedRouteID = id
        mapTemplate.updateEstimates(estimates(route.distance, route.duration), for: trip)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        if let id = routeChoice.userInfo as? Route.ID {
            model.selectedRouteID = id
        }
        model.startNavigation()
    }

    // MARK: - Guidance

    private func updateGuidance() {
        guard let route = model.selectedRoute else { return }
        if session == nil {
            // A trip started on the phone has no preview on the car's screen to start from.
            guard let trip = previewTrip ?? model.destination.map({ makeTrip(to: $0, routes: [route]) }) else { return }
            hidePreview()
            self.trip = trip
            session = mapTemplate.startNavigationSession(for: trip)
            shownManeuvers = nil
            pausedFor = nil
            warnedHazards = []
            askedHazards = []
        }
        guard let session, let trip else { return }

        let lang = language
        if model.isRerouting {
            pause(session, for: .rerouting, lang.pick("Recalculating…", "Mengira semula…"))
            return
        }
        guard let progress = model.progress else {
            pause(session, for: .locating, lang.pick("Waiting for GPS…", "Menunggu isyarat GPS…"))
            return
        }
        let steps = route.steps
        let index = progress.upcomingStepIndex
        guard steps.indices.contains(index) else { return }

        // Time to the next turn, at the average speed of the stretch the driver is on.
        var timeToTurn: TimeInterval = 0
        if index > 0, steps[index - 1].distance > 0 {
            timeToTurn = steps[index - 1].duration * min(1, progress.distanceToUpcomingStep / steps[index - 1].distance)
        }

        // CarPlay shows the next turn and the one after it. Updating the list also resumes a paused trip.
        let key = ManeuverKey(routeID: route.id, stepIndex: index)
        if key != shownManeuvers {
            shownManeuvers = key
            pausedFor = nil
            var maneuvers = [makeManeuver(steps[index], estimates(progress.distanceToUpcomingStep, timeToTurn))]
            if steps.indices.contains(index + 1) {
                maneuvers.append(makeManeuver(steps[index + 1], estimates(steps[index].distance, steps[index].duration)))
            }
            session.upcomingManeuvers = maneuvers
        }
        if let next = session.upcomingManeuvers.first {
            session.updateEstimates(estimates(progress.distanceToUpcomingStep, timeToTurn), for: next)
        }
        mapTemplate.updateEstimates(estimates(progress.distanceRemaining, progress.durationRemaining), for: trip)
    }

    /// Xcode 26's SDK renamed `CPTripPauseReason` to `CPNavigationSession.PauseReason` and rejects
    /// the old name; older SDKs only know the old one. The app keeps its own so it builds with both.
    private enum PauseReason { case rerouting, locating }

    private func pause(_ session: CPNavigationSession, for reason: PauseReason, _ description: String) {
        guard pausedFor != reason else { return }
        pausedFor = reason
        // Send the turn list again once guidance can resume.
        shownManeuvers = nil
        switch reason {
        case .rerouting: session.pauseTrip(for: .rerouting, description: description)
        case .locating: session.pauseTrip(for: .locating, description: description)
        }
    }

    private func makeManeuver(_ step: RouteStep, _ estimates: CPTravelEstimates) -> CPManeuver {
        let maneuver = CPManeuver()
        maneuver.instructionVariants = [InstructionBuilder(language: language).instruction(for: step)]
        maneuver.symbolImage = UIImage(systemName: ManeuverSymbol.name(for: step.maneuver),
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .bold))
        maneuver.initialTravelEstimates = estimates
        return maneuver
    }

    private func endTrip() {
        guard let session else { return }
        if model.lastTripArrived {
            session.finishTrip()
        } else {
            session.cancelTrip()
        }
        self.session = nil
        trip = nil
        shownManeuvers = nil
        pausedFor = nil
    }

    /// CarPlay ended the trip itself, for example because the driver started navigating in another app.
    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        session = nil
        trip = nil
        model.stopNavigation()
    }

    /// Rounded like the phone's banner, which CarPlay then formats in the car's units.
    private func estimates(_ metres: Double, _ seconds: TimeInterval) -> CPTravelEstimates {
        let m = max(0, metres)
        let distance: Measurement<UnitLength>
        if m < 100 {
            distance = Measurement(value: (m / 10).rounded() * 10, unit: .meters)
        } else if m < 975 {
            distance = Measurement(value: (m / 50).rounded() * 50, unit: .meters)
        } else {
            let km = m / 1000
            distance = Measurement(value: km < 10 ? (km * 10).rounded() / 10 : km.rounded(), unit: .kilometers)
        }
        return CPTravelEstimates(distanceRemaining: distance, timeRemaining: max(0, seconds))
    }

    // MARK: - Panning

    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        map.pan(direction)
    }

    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        updateBarButtons()
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        updateBarButtons()
    }

    /// Dragging on a touchscreen.
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        lastPanTranslation = .zero
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        map.pan(by: CGPoint(x: lastPanTranslation.x - translation.x, y: lastPanTranslation.y - translation.y),
                animated: false)
        lastPanTranslation = translation
    }
}
