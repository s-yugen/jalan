import SwiftUI
import NavCore

/// Next maneuver, in Malaysian road-sign green.
struct ManeuverBanner: View {
    let step: RouteStep
    let distance: Double
    let language: NavLanguage

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: ManeuverSymbol.name(for: step.maneuver))
                .font(.system(size: 38, weight: .bold))
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(DistanceFormatter.string(distance))
                    .font(.title.bold())
                    .monospacedDigit()
                Text(InstructionBuilder(language: language).instruction(for: step))
                    .font(.headline)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding()
        .background(Color(red: 0, green: 0.42, blue: 0.29), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// Arrival time, time and distance left, and the End button.
struct NavigationFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lang = model.settings.language
        HStack {
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Date.now.addingTimeInterval(progress.durationRemaining), style: .time)
                        .font(.title2.bold())
                    Text("\(DurationFormatter.string(progress.durationRemaining, language: lang)) · \(DistanceFormatter.string(progress.distanceRemaining))")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(lang.pick("Waiting for GPS…", "Menunggu isyarat GPS…"), systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(lang.pick("End", "Tamat")) { model.stopNavigation() }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Route choices before starting, with toll badges and an avoid-tolls switch.
struct RoutePreviewPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let lang = settings.language
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.destination?.name ?? "").font(.headline).lineLimit(1)
                    if let subtitle = model.destination?.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { model.cancelPreview() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if model.isLoadingRoutes {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(model.routes) { route in
                    RouteRow(route: route, isSelected: route.id == model.selectedRoute?.id, language: lang)
                        .onTapGesture { model.selectedRouteID = route.id }
                }
            }

            Toggle(lang.pick("Avoid tolls", "Elak tol"), isOn: $settings.avoidTolls)
                .onChange(of: settings.avoidTolls) {
                    Task { await model.loadRoutes() }
                }

            Button { model.startNavigation() } label: {
                Text(lang.pick("Go", "Mula")).font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedRoute == nil || model.isLoadingRoutes)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct RouteRow: View {
    let route: Route
    let isSelected: Bool
    let language: NavLanguage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DurationFormatter.string(route.duration, language: language)).font(.title3.bold())
                    Text(language.pick("Arrive ", "Tiba ")) + Text(Date.now.addingTimeInterval(route.duration), style: .time)
                }
                Text(details).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if route.hasTolls {
                Text(language.pick("Toll", "Tol"))
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.35), in: Capsule())
            }
        }
        .padding(10)
        .background(isSelected ? Color.blue.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private var details: String {
        let distance = DistanceFormatter.string(route.distance)
        guard !route.summary.isEmpty else { return distance }
        return distance + language.pick(" · via ", " · melalui ") + route.summary
    }
}
