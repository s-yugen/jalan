import SwiftUI
import MapKit
import NavCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let lang = model.settings.language
        let search = model.search
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section {
                        ForEach(search.appleResults, id: \.self) { completion in
                            Button {
                                dismiss()
                                Task { await model.choose(completion) }
                            } label: {
                                PlaceRow(title: completion.title, subtitle: completion.subtitle)
                            }
                        }
                        SearchStatusRow(status: search.appleStatus, isEmpty: search.appleResults.isEmpty,
                                        source: .apple, lang: lang)
                    } header: {
                        SourceHeader(source: .apple, status: search.appleStatus, count: search.appleResults.count)
                    }

                    ForEach(search.sections) { section in
                        Section {
                            ForEach(section.places) { place in
                                Button {
                                    dismiss()
                                    Task { await model.choose(place) }
                                } label: {
                                    PlaceRow(title: place.name, subtitle: place.subtitle)
                                }
                            }
                            SearchStatusRow(status: section.status, isEmpty: section.places.isEmpty,
                                            source: section.source, lang: lang)
                        } header: {
                            SourceHeader(source: section.source, status: section.status, count: section.places.count)
                        }
                    }

                    Text(lang.pick(
                        "Results other than Apple Maps: © OpenStreetMap contributors. Add free API keys in Settings to compare more services.",
                        "Hasil selain Apple Maps: © penyumbang OpenStreetMap. Masukkan kunci API percuma dalam Tetapan untuk bandingkan lebih banyak perkhidmatan."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
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
            .onSubmit(of: .search) { model.search.submit() }
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

private struct PlaceRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SourceHeader: View {
    let source: PlaceSource
    let status: PlaceSearch.Status
    let count: Int

    var body: some View {
        HStack {
            Text(source.title)
            Spacer()
            if status == .searching {
                ProgressView().controlSize(.mini)
            } else if count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
    }
}

/// What a source has to say when it has no results to list: still searching, failed, or found nothing.
private struct SearchStatusRow: View {
    let status: PlaceSearch.Status
    let isEmpty: Bool
    let source: PlaceSource
    let lang: NavLanguage

    var body: some View {
        switch status {
        case .searching where isEmpty:
            Text(lang.pick("Searching…", "Mencari…")).font(.footnote).foregroundStyle(.secondary)
        case .done where isEmpty:
            Text(lang.pick("No results", "Tiada hasil")).font(.footnote).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        case .waitingForSubmit:
            Text(lang.pick("Press Search on the keyboard to ask \(source.title).",
                           "Tekan Cari pada papan kekunci untuk tanya \(source.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
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

                Section {
                    Picker(lang.pick("Your position", "Kedudukan anda"), selection: $settings.positionMarker) {
                        ForEach(PositionMarker.allCases) { Text($0.title(lang)).tag($0) }
                    }
                    if settings.positionMarker == .car {
                        Picker(lang.pick("Car colour", "Warna kereta"), selection: $settings.carColor) {
                            ForEach(CarColor.allCases) { Text($0.title(lang)).tag($0) }
                        }
                        CarModel(heading: 35, mapHeading: 0, mapPitch: FollowCamera.pitch, color: settings.carColor)
                            .frame(width: 110, height: 110)
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text(lang.pick("Map", "Peta"))
                } footer: {
                    if settings.positionMarker == .car {
                        Text(lang.pick("The car turns to face the way you're driving, on the phone and in CarPlay.",
                                       "Kereta berpusing mengikut arah anda memandu, pada telefon dan dalam CarPlay."))
                    }
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

                Section {
                    CodeField(lang.pick("Jalan server (Supabase project URL)", "Pelayan Jalan (URL projek Supabase)"),
                              text: $settings.jalanServer)
                        .keyboardType(.URL)
                    Toggle("Photon", isOn: $settings.photonEnabled)
                    // The Jalan server asks its own Photon server.
                    if settings.photonEnabled && settings.jalanServer.isEmpty {
                        CodeField("Photon server", text: $settings.photonServer)
                            .keyboardType(.URL)
                    }
                    Toggle(lang.pick("Nominatim (on Search)", "Nominatim (bila tekan Cari)"),
                           isOn: $settings.nominatimEnabled)
                    CodeField("openrouteservice API key", text: $settings.openrouteserviceKey)
                    CodeField("Stadia Maps API key", text: $settings.stadiaKey)
                    CodeField("LocationIQ API key", text: $settings.locationIQKey)
                    CodeField("MapTiler API key", text: $settings.mapTilerKey)
                } header: {
                    Text(lang.pick("Place search", "Carian tempat"))
                } footer: {
                    Text(lang.pick(
                        "Apple Maps is always searched. Photon and Nominatim need no key. With a Jalan server, they are asked through it only for places it doesn't have, and what they find is saved there for the next search. openrouteservice, Stadia Maps, LocationIQ and MapTiler are free once you sign up for a key on their websites; the Stadia Maps and MapTiler free plans are for non-commercial use. Each service's results are listed separately.",
                        "Apple Maps sentiasa dicari. Photon dan Nominatim tidak perlu kunci. Dengan pelayan Jalan, mereka ditanya melaluinya hanya untuk tempat yang belum ada padanya, dan apa yang dijumpai disimpan di sana untuk carian seterusnya. openrouteservice, Stadia Maps, LocationIQ dan MapTiler percuma selepas anda daftar untuk kunci di laman web mereka; pelan percuma Stadia Maps dan MapTiler untuk kegunaan bukan komersial. Hasil setiap perkhidmatan disenaraikan berasingan."))
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

/// A text field for URLs and API keys: no autocapitalisation or autocorrection.
private struct CodeField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        TextField(title, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.footnote.monospaced())
    }
}
