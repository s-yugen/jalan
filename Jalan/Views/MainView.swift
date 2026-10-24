import SwiftUI
import NavCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var selectedHazard: HazardReport?

    enum Sheet: String, Identifiable {
        case search, report, settings
        var id: String { rawValue }
    }

    private var lang: NavLanguage { model.settings.language }

    var body: some View {
        RouteMapView(selectedHazard: $selectedHazard)
            // Inset the map's safe area rather than floating the panels over it, so MapKit keeps Apple's logo
            // and Legal link, the scale and the camera clear of them (the logo must stay visible).
            .safeAreaInset(edge: .top) {
                VStack(spacing: 10) { topPanel }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) { bottomPanel }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .search: SearchView()
                case .report: ReportView().presentationDetents([.medium])
                case .settings: SettingsView()
                }
            }
            .confirmationDialog(
                selectedHazard.map { $0.type.title(lang) } ?? "",
                isPresented: Binding(get: { selectedHazard != nil }, set: { if !$0 { selectedHazard = nil } }),
                titleVisibility: .visible,
                presenting: selectedHazard
            ) { report in
                Button(lang.pick("Still there", "Masih ada")) { model.hazards.confirm(report.id) }
                Button(lang.pick("Not there anymore", "Sudah tiada"), role: .destructive) { model.hazards.dismiss(report.id) }
            } message: { report in
                Text(lang.pick("Reported ", "Dilaporkan ") + report.reportedAt.formatted(.relative(presentation: .named)))
            }
    }

    @ViewBuilder
    private var topPanel: some View {
        switch model.phase {
        case .browsing:
            Button { sheet = .search } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(lang.pick("Where to?", "Ke mana?"))
                    Spacer()
                }
                .font(.title3)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        case .previewing:
            EmptyView()
        case .navigating:
            if let step = model.upcomingStep, let progress = model.progress {
                ManeuverBanner(step: step, distance: progress.distanceToUpcomingStep, language: lang)
            }
            if model.isRerouting {
                Label(lang.pick("Recalculating…", "Mengira semula…"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            if let hazard = model.hazardAhead {
                HStack {
                    HazardIcon(type: hazard.report.type, size: 30)
                    Text(hazard.report.type.title(lang)).bold()
                    Spacer()
                    Text(DistanceFormatter.string(hazard.distanceAhead)).monospacedDigit()
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }

        if model.location.isDenied {
            Notice(text: lang.pick("Location access is off. Turn it on in Settings > Jalan > Location.",
                                   "Akses lokasi dimatikan. Hidupkan di Tetapan > Jalan > Lokasi."))
        }
        if let error = model.errorMessage {
            Notice(text: error) { model.errorMessage = nil }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch model.phase {
        case .browsing:
            HStack(alignment: .bottom) {
                CircleButton(systemImage: "gearshape.fill") { sheet = .settings }
                Spacer()
                VStack(spacing: 12) {
                    CircleButton(systemImage: "location.fill") { model.recenter() }
                    reportButton
                }
            }
            attribution
        case .previewing:
            RoutePreviewPanel()
            attribution
        case .navigating:
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    if !model.isFollowing {
                        CircleButton(systemImage: "location.north.line.fill") { model.recenter() }
                    }
                    reportButton
                }
            }
            NavigationFooter()
        }
    }

    private var reportButton: some View {
        CircleButton(systemImage: "exclamationmark.bubble.fill", tint: .white, background: .orange) {
            sheet = .report
        }
        .disabled(model.location.lastLocation == nil)
    }

    /// OSM data is ODbL-licensed and must be credited wherever routes from it are shown.
    @ViewBuilder
    private var attribution: some View {
        if !model.settings.usesMapbox {
            Text("Routing © OpenStreetMap contributors")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Notice: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.footnote.bold()) }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CircleButton: View {
    let systemImage: String
    var tint: Color = .primary
    var background: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
                .background {
                    if let background {
                        Circle().fill(background)
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}

struct HazardIcon: View {
    let type: HazardType
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: type.symbol)
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(type.color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: max(1.5, size / 20)))
    }
}
