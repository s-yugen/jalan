import SwiftUI
import MapKit
import NavCore

/// The map. Everything provider-specific about drawing lives here, so moving to another map SDK
/// (Mapbox Maps or MapLibre) means rewriting this one view.
struct RouteMapView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedHazard: HazardReport?
    @State private var cameraAngles = MapCameraAngles()

    var body: some View {
        @Bindable var model = model
        Map(position: $model.camera) {
            if model.settings.positionMarker == .dot {
                UserAnnotation()
            }
            if model.settings.positionMarker == .car {
                UserAnnotation { _ in
                    PositionCar(model: model, camera: cameraAngles)
                }
            }

            ForEach(model.alternativeRoutes) { route in
                MapPolyline(coordinates: route.mapCoordinates)
                    .stroke(Color.gray.opacity(0.8), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let route = model.selectedRoute {
                MapPolyline(coordinates: route.mapCoordinates)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }

            if let destination = model.destination {
                Marker(destination.name, systemImage: "flag.checkered",
                       coordinate: CLLocationCoordinate2D(destination.coordinate))
                    .tint(.red)
            }

            ForEach(model.hazards.active()) { report in
                Annotation(report.type.title(model.settings.language),
                           coordinate: CLLocationCoordinate2D(report.coordinate)) {
                    Button { selectedHazard = report } label: {
                        HazardIcon(type: report.type, size: 32)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        // Apple's live traffic layer is free and covers Malaysian cities.
        .mapStyle(.standard(showsTraffic: true))
        .mapControls {
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            cameraAngles.heading = context.camera.heading
            cameraAngles.pitch = context.camera.pitch
        }
    }
}

/// The map camera's heading and pitch, for the car. Kept in an object that only the car reads, so a
/// moving map redraws the car on every frame, not everything on the map.
@Observable
private final class MapCameraAngles {
    var heading: Double = 0
    var pitch: Double = 0
}

/// The 3D car in place of the blue dot, MapKit moving it as the GPS position changes.
private struct PositionCar: View {
    let model: AppModel
    let camera: MapCameraAngles

    var body: some View {
        CarModel(heading: model.carHeading, mapHeading: camera.heading, mapPitch: camera.pitch,
                 color: model.settings.carColor)
            .frame(width: CarModelView.side, height: CarModelView.side)
    }
}
