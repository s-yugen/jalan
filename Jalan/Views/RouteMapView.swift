import SwiftUI
import MapKit
import NavCore

/// The map. Everything provider-specific about drawing lives here, so moving to another map SDK
/// (Mapbox Maps or MapLibre) means rewriting this one view.
struct RouteMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Map(position: $model.camera) {
            UserAnnotation()

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
        }
        // Apple's live traffic layer is free and covers Malaysian cities.
        .mapStyle(.standard(showsTraffic: true))
        .mapControls {
            MapScaleView()
        }
    }
}
