import SwiftUI
import MapKit
import NavCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let lang = model.settings.language
        NavigationStack {
            List(model.search.results, id: \.self) { completion in
                Button {
                    dismiss()
                    Task { await model.choose(completion) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title).foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView(lang.pick("Search places in Malaysia", "Cari tempat di Malaysia"),
                                           systemImage: "magnifyingglass",
                                           description: Text("Mid Valley, KLCC, R&R Tapah, Jalan Alor…"))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: lang.pick("Place or address", "Tempat atau alamat"))
            .onChange(of: query) { _, newValue in model.search.update(query: newValue) }
            .navigationTitle(lang.pick("Where to?", "Ke mana?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang.pick("Cancel", "Batal")) { dismiss() }
                }
            }
        }
    }
}

struct ReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lang = model.settings.language
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 20) {
                    ForEach(HazardType.allCases, id: \.self) { type in
                        Button {
                            model.report(type)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                HazardIcon(type: type, size: 64)
                                Text(type.title(lang))
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(lang.pick("Report here", "Laporkan di sini"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang.pick("Cancel", "Batal")) { dismiss() }
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        let lang = settings.language
        NavigationStack {
            Form {
                Section(lang.pick("Language", "Bahasa")) {
                    Picker(lang.pick("Language", "Bahasa"), selection: $settings.language) {
                        ForEach(NavLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle(lang.pick("Voice guidance", "Panduan suara"), isOn: $settings.voiceEnabled)
                }

                Section(lang.pick("Routes", "Laluan")) {
                    Toggle(lang.pick("Avoid tolls", "Elak tol"), isOn: $settings.avoidTolls)
                    Toggle(lang.pick("Avoid highways", "Elak lebuh raya"), isOn: $settings.avoidMotorways)
                }

                Section {
                    Picker(lang.pick("Provider", "Penyedia"), selection: $settings.provider) {
                        ForEach(RoutingProviderKind.allCases) { Text($0.title).tag($0) }
                    }
                    switch settings.provider {
                    case .osrm:
                        TextField("OSRM server", text: $settings.osrmServer)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.footnote.monospaced())
                    case .mapbox:
                        TextField("Mapbox access token (pk.…)", text: $settings.mapboxToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        if settings.mapboxToken.isEmpty {
                            Text(lang.pick("Add a token to use Mapbox. Until then routes come from OSRM.",
                                           "Masukkan token untuk guna Mapbox. Buat masa ini laluan dari OSRM."))
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text(lang.pick("Routing engine", "Enjin laluan"))
                } footer: {
                    Text(lang.pick(
                        "OSRM is free but has no live traffic, so arrival times are optimistic at rush hour. Mapbox uses live traffic and is paid per request beyond its free tier.",
                        "OSRM percuma tetapi tiada data trafik langsung, jadi anggaran masa tiba terlalu awal ketika waktu sibuk. Mapbox guna trafik langsung dan berbayar selepas had percuma."))
                }
            }
            .navigationTitle(lang.pick("Settings", "Tetapan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lang.pick("Done", "Selesai")) { dismiss() }
                }
            }
        }
    }
}
