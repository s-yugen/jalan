import CoreLocation
import Observation
import NavCore

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var lastLocation: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @ObservationIgnored var onUpdate: (@MainActor (CLLocation) -> Void)?

    private let manager = CLLocationManager()

    var coordinate: Coordinate? { lastLocation.map { Coordinate($0.coordinate) } }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func setNavigationMode(_ on: Bool) {
        manager.desiredAccuracy = on ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.distanceFilter = on ? kCLDistanceFilterNone : 5
        // Keeps guidance going with the screen locked; needs the "location" background mode.
        manager.allowsBackgroundLocationUpdates = on
        manager.showsBackgroundLocationIndicator = on
        manager.pausesLocationUpdatesAutomatically = !on
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
        MainActor.assumeIsolated {
            lastLocation = latest
            onUpdate?(latest)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
