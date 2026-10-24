import UIKit
import CarPlay
import MapKit
import Observation
import NavCore

/// The map on the car's screen. CarPlay draws its buttons and guidance panel over a UIKit view,
/// so this is MapKit's `MKMapView` rather than the SwiftUI `Map` in `RouteMapView`; the two draw
/// the same things. The car has its own camera, so panning one screen doesn't move the other.
final class CarPlayMapViewController: UIViewController, MKMapViewDelegate {
    private let model: AppModel
    private let mapView = MKMapView()

    /// The camera tracks the car until the driver pans or zooms.
    private(set) var isFollowing = true {
        didSet { if isFollowing != oldValue { onFollowingChange?(isFollowing) } }
    }
    var onFollowingChange: ((Bool) -> Void)?

    /// Set when CarPlay disconnects, to stop following the model.
    private var isStopped = false
    /// The camera shows the whole route choice, refitted when CarPlay's panels move.
    private var isShowingRoutes = false
    private var shownRouteIDs: [Route.ID] = []
    private var shownPhase: AppModel.Phase?
    private var shownMarker: PositionMarker?
    /// The 3D car, while it stands in for the blue dot.
    private weak var car: CarModelView?

    private static let selectedRouteTitle = "selected"

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = mapView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.delegate = self
        mapView.showsUserLocation = true
        // Apple's live traffic layer, as on the phone.
        mapView.showsTraffic = true
        mapView.setRegion(.malaysia, animated: false)
        observeOverlays()
        observeCamera()
        observeCar()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The route preview card and the guidance panel change the safe area as they come and go.
        if isShowingRoutes { showRoutes() }
    }

    func stop() {
        isStopped = true
    }

    // MARK: - Map buttons and panning

    func recenter() {
        isFollowing = true
        isShowingRoutes = false
        switch model.phase {
        case .browsing:
            mapView.setUserTrackingMode(.follow, animated: true)
        case .previewing:
            showRoutes()
        case .navigating:
            followCar()
        }
    }

    func zoom(by factor: Double) {
        stopFollowing()
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.centerCoordinateDistance = min(max(camera.centerCoordinateDistance * factor, 150), 3_000_000)
        mapView.setCamera(camera, animated: true)
    }

    /// Moves the map by a number of points; positive x shows more to the right, positive y more below.
    func pan(by offset: CGPoint, animated: Bool) {
        stopFollowing()
        let bounds = mapView.bounds
        let target = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        mapView.setCenter(mapView.convert(target, toCoordinateFrom: mapView), animated: animated)
    }

    /// A pan button moves the map by a third of the screen.
    func pan(_ direction: CPMapTemplate.PanDirection) {
        let size = mapView.bounds.size
        var offset = CGPoint.zero
        if direction.contains(.left) { offset.x -= size.width / 3 }
        if direction.contains(.right) { offset.x += size.width / 3 }
        if direction.contains(.up) { offset.y -= size.height / 3 }
        if direction.contains(.down) { offset.y += size.height / 3 }
        pan(by: offset, animated: true)
    }

    private func stopFollowing() {
        isFollowing = false
        isShowingRoutes = false
        mapView.setUserTrackingMode(.none, animated: false)
    }

    // MARK: - Following the model

    /// Routes, destination and hazard markers. Redrawn only when they change, not on every GPS fix.
    private func observeOverlays() {
        guard !isStopped else { return }
        withObservationTracking {
            drawOverlays()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOverlays() }
        }
    }

    private func drawOverlays() {
        mapView.removeOverlays(mapView.overlays)
        for route in model.alternativeRoutes {
            mapView.addOverlay(MKPolyline(coordinates: route.mapCoordinates, count: route.coordinates.count),
                               level: .aboveRoads)
        }
        if let route = model.selectedRoute {
            let line = MKPolyline(coordinates: route.mapCoordinates, count: route.coordinates.count)
            line.title = Self.selectedRouteTitle
            mapView.addOverlay(line, level: .aboveRoads)
        }

        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        if let destination = model.destination {
            let marker = MKPointAnnotation()
            marker.coordinate = CLLocationCoordinate2D(destination.coordinate)
            marker.title = destination.name
            mapView.addAnnotation(marker)
        }
        let language = model.settings.language
        mapView.addAnnotations(model.hazards.active().map { HazardAnnotation(report: $0, language: language) })

        // Fit a new set of route choices on screen, once; after that the driver may pan.
        let routeIDs = model.routes.map(\.id)
        if model.phase == .previewing, !routeIDs.isEmpty, routeIDs != shownRouteIDs {
            isFollowing = false
            showRoutes()
        }
        shownRouteIDs = routeIDs
    }

    /// The camera: follows the car on every fix while following, and changes mode with the phase.
    private func observeCamera() {
        guard !isStopped else { return }
        withObservationTracking {
            updateCamera()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCamera() }
        }
    }

    private func updateCamera() {
        let phase = model.phase
        let fix = model.location.lastLocation
        if phase != shownPhase {
            shownPhase = phase
            if phase != .previewing { recenter() }
            return
        }
        guard isFollowing else { return }
        if phase == .navigating, fix != nil {
            followCar()
        } else if phase == .browsing, mapView.userTrackingMode == .none {
            // Tracking mode switches itself off until the first fix arrives.
            mapView.setUserTrackingMode(.follow, animated: true)
        }
    }

    private func followCar() {
        guard let fix = model.location.lastLocation else { return }
        let follow = FollowCamera(fix: fix, routeBearing: model.progress?.routeBearing)
        let camera = MKMapCamera(lookingAtCenter: follow.center, fromDistance: follow.distance,
                                 pitch: FollowCamera.pitch, heading: follow.heading)
        mapView.setCamera(camera, animated: true)
    }

    /// The blue dot or the car, and which way the car faces.
    private func observeCar() {
        guard !isStopped else { return }
        withObservationTracking {
            updateCar()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCar() }
        }
    }

    private func updateCar() {
        let marker = model.settings.positionMarker
        let oldMarker = shownMarker
        shownMarker = marker
        if let oldMarker, marker != oldMarker {
            // MapKit only asks for the user location's view again when it's shown afresh.
            let mode = mapView.userTrackingMode
            car = nil
            mapView.showsUserLocation = false
            mapView.showsUserLocation = true
            mapView.setUserTrackingMode(mode, animated: false)
        }
        drawCar()
    }

    /// Paints the car and turns it the way it's driving, on the map as its camera is now.
    private func drawCar() {
        // Read before touching the car, so a change is observed even while there's no car yet.
        let heading = model.carHeading
        let color = model.settings.carColor
        car?.color = color
        car?.update(heading: heading, mapHeading: mapView.camera.heading, mapPitch: mapView.camera.pitch)
    }

    private func showRoutes() {
        let rect = mapView.overlays.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        guard !rect.isNull else { return }
        isShowingRoutes = true
        let insets = view.safeAreaInsets
        let padding = UIEdgeInsets(top: insets.top + 24, left: insets.left + 24,
                                   bottom: insets.bottom + 24, right: insets.right + 24)
        mapView.setUserTrackingMode(.none, animated: false)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: true)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        let isSelected = line.title == Self.selectedRouteTitle
        renderer.strokeColor = isSelected ? .systemBlue : UIColor.gray.withAlphaComponent(0.8)
        renderer.lineWidth = isSelected ? 8 : 6
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        // The car keeps pointing the way it drives as the map turns and tilts under it.
        drawCar()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation {
            guard model.settings.positionMarker == .car else { return nil }
            let view = CarAnnotationView(annotation: annotation, reuseIdentifier: nil)
            car = view.car
            drawCar()
            return view
        }
        let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
        if let hazard = annotation as? HazardAnnotation {
            view.markerTintColor = UIColor(hazard.report.type.color)
            view.glyphImage = UIImage(systemName: hazard.report.type.symbol)
            view.titleVisibility = .hidden
            // The destination marker wins when they overlap.
            view.displayPriority = .defaultLow
        } else {
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "flag.checkered")
            view.displayPriority = .required
        }
        return view
    }
}

/// The 3D car in place of MapKit's blue dot.
private final class CarAnnotationView: MKAnnotationView {
    let car = CarModelView(frame: CGRect(x: 0, y: 0, width: CarModelView.side, height: CarModelView.side))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = car.frame
        addSubview(car)
        zPriority = .max
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class HazardAnnotation: NSObject, MKAnnotation {
    let report: HazardReport
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(report: HazardReport, language: NavLanguage) {
        self.report = report
        coordinate = CLLocationCoordinate2D(report.coordinate)
        title = report.type.title(language)
    }
}
