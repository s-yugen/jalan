import SwiftUI
import NavCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case search, settings
        var id: String { rawValue }
    }

    private var lang: NavLanguage { model.settings.language }

    var body: some View {
        RouteMapView()
            // The round buttons float over the map. Sitting inside the bottom inset, they stay above any card.
            .overlay(alignment: .bottom) {
                floatingButtons
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            // Only the full-width panels inset the map's safe area, so MapKit puts Apple's logo and Legal link
            // (which must stay visible), the scale and the camera just clear of them, and the logo stays in the
            // bottom-left corner when no card is up.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 10) { topPanel }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomCard
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .search: SearchView()
                case .settings: SettingsView()
                }
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
    private var floatingButtons: some View {
        switch model.phase {
        case .browsing:
            VStack(spacing: 10) {
                HStack(alignment: .bottom) {
                    CircleButton(systemImage: "gearshape.fill") { sheet = .settings }
                    Spacer()
                    CircleButton(systemImage: "location.fill") { model.recenter() }
                }
                // Apple's logo has the left end of this bottom row, so the credit takes the right end. The row
                // stays when there's no credit to show, so the gear button never covers the logo.
                credit
                    .opacity(model.settings.usesMapbox ? 0 : 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 100)
                    .allowsHitTesting(false)
            }
        case .previewing:
            EmptyView()
        case .navigating:
            HStack {
                Spacer()
                if !model.isFollowing {
                    CircleButton(systemImage: "location.north.line.fill") { model.recenter() }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomCard: some View {
        switch model.phase {
        case .browsing:
            EmptyView()
        case .previewing:
            VStack(spacing: 10) {
                RoutePreviewPanel()
                if !model.settings.usesMapbox {
                    credit
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        case .navigating:
            NavigationFooter()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    /// OSM data is ODbL-licensed and must be credited wherever routes from it are shown.
    private var credit: some View {
        Text("Routing © OpenStreetMap contributors")
            .font(.caption2)
            .foregroundStyle(.secondary)
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
