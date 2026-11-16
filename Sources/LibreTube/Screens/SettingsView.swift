import LibreTubeCore
import SwiftUI
import UniformTypeIdentifiers

enum SponsorBlockCategory {
    /// Category ids used by the SponsorBlock API (see res/values/array.xml).
    static let all = [
        "sponsor", "intro", "selfpromo", "interaction", "outro",
        "filler", "music_offtopic", "preview",
    ]

    static func title(for category: String) -> String {
        switch category {
        case "sponsor": "Sponsor"
        case "intro": "Intermission / Intro Animation"
        case "selfpromo": "Unpaid / Self Promotion"
        case "interaction": "Interaction Reminder"
        case "outro": "Endcards / Credits"
        case "filler": "Filler Tangent"
        case "music_offtopic": "Music: Non-Music Section"
        case "preview": "Preview / Recap"
        default: category.capitalized
        }
    }
}

struct InstanceOption: Hashable, Identifiable {
    let name: String
    let url: URL
    let locations: String
    var id: URL { url }
}

@MainActor
final class InstancesViewModel: ObservableObject {
    @Published private(set) var options: [InstanceOption] = []
    @Published private(set) var phase: LoadPhase = .loading

    func load() async {
        phase = .loading
        do {
            let instances = try await PipedAPI.instances()
            options = instances.compactMap { instance -> InstanceOption? in
                guard let url = URL(string: optional(instance.apiUrl) ?? "") else { return nil }
                return InstanceOption(
                    name: optional(instance.name) ?? url.host() ?? url.absoluteString,
                    url: url,
                    locations: optional(instance.locations) ?? ""
                )
            }
            phase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

struct SettingsView: View {
    private static let qualities = ["auto", "2160p", "1440p", "1080p", "720p", "480p", "360p", "240p", "144p"]

    private static let regions: [String] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .sorted { regionName($0) < regionName($1) }

    private static func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var library = LibraryStore.shared
    @StateObject private var instances = InstancesViewModel()
    @State private var customInstance = ""
    @State private var confirmingClearHistory = false
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        Form {
            streamSourceSection
            instanceSection
            contentSection
            sponsorBlockSection
            importSection
            historySection
            aboutSection
        }
        .navigationTitle("Settings")
        .task {
            if instances.options.isEmpty { await instances.load() }
        }
    }

    // MARK: Sections

    private var streamSourceSection: some View {
        Section {
            Picker("Video Source", selection: $settings.streamSource) {
                ForEach(StreamSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Playback")
        } footer: {
            switch settings.streamSource {
            case .onDevice:
                Text("Streams are fetched from YouTube directly by this device, using your own connection. Works when public Piped servers are blocked. Trending, search, channels and comments still use the Piped instance below.")
            case .piped:
                Text("Streams are fetched through the Piped instance below. More private, but many public instances are currently blocked by YouTube.")
            }
        }
    }

    private var instanceSection: some View {
        Section {
            switch instances.phase {
            case .loading:
                HStack {
                    Text("Instance")
                    Spacer()
                    ProgressView()
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't load instances").font(.subheadline)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await instances.load() } }
                        .buttonStyle(.borderless)
                }
            case .loaded:
                Picker("Instance", selection: $settings.instanceURL) {
                    ForEach(instanceOptions) { option in
                        VStack(alignment: .leading) {
                            Text(option.name)
                            if !option.locations.isEmpty {
                                Text(option.locations).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(option.url)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            HStack {
                TextField("Custom API URL", text: $customInstance)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(applyCustomInstance)
                Button("Use", action: applyCustomInstance)
                    .buttonStyle(.borderless)
                    .disabled(customInstanceURL == nil)
            }
        } header: {
            Text("Piped Instance")
        } footer: {
            Text("Current: \(settings.instanceURL.absoluteString)")
        }
    }

    private var contentSection: some View {
        Section("Content") {
            Picker("Home", selection: $settings.homeContent) {
                ForEach(HomeContent.allCases) { Text($0.title).tag($0) }
            }

            Picker("Trending Region", selection: $settings.region) {
                ForEach(Self.regions, id: \.self) { code in
                    Text(Self.regionName(code)).tag(code)
                }
            }
            .pickerStyle(.navigationLink)

            Picker("Preferred Quality", selection: $settings.preferredQuality) {
                ForEach(Self.qualities, id: \.self) { quality in
                    Text(quality == "auto" ? "Auto" : quality).tag(quality)
                }
            }
        }
    }

    private var sponsorBlockSection: some View {
        Section {
            Toggle("Skip Segments", isOn: $settings.sponsorBlockEnabled)
            if settings.sponsorBlockEnabled {
                ForEach(SponsorBlockCategory.all, id: \.self) { category in
                    Toggle(SponsorBlockCategory.title(for: category), isOn: categoryBinding(category))
                }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Automatically skips crowd-sourced segments such as sponsors and intros.")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                importing = true
            } label: {
                Label("Import Subscriptions & Playlists", systemImage: "square.and.arrow.down")
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.json, .commaSeparatedText, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("Import", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        } header: {
            Text("Import")
        } footer: {
            Text("""
            Supported files, detected automatically:
            • NewPipe: Settings › Backup and restore › Export subscriptions (.json)
            • LibreTube / Piped backup (.json): subscriptions, playlists, history
            • FreeTube profiles (.db)
            • YouTube Takeout subscriptions (.csv)
            • Text file with channel or video links (.txt)
            """)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let urls):
            var messages: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let parsed = try Importer.parse(data, filename: url.lastPathComponent)
                    messages.append(library.apply(parsed))
                } catch {
                    messages.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importMessage = messages.joined(separator: "\n\n")
        }
    }

    private var historySection: some View {
        Section("History") {
            Button("Clear Watch History", role: .destructive) {
                confirmingClearHistory = true
            }
            .disabled(library.history.isEmpty)
            .confirmationDialog(
                "Clear watch history?",
                isPresented: $confirmingClearHistory,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) { library.clearHistory() }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Link("LibreTube on GitHub", destination: URL(string: "https://github.com/libre-tube/LibreTube")!)
        }
    }

    // MARK: Helpers

    /// Fetched instances, plus the current one if it is not in the public list.
    private var instanceOptions: [InstanceOption] {
        var options = instances.options
        if !options.contains(where: { $0.url == settings.instanceURL }) {
            let current = settings.instanceURL
            options.insert(
                InstanceOption(name: current.host() ?? current.absoluteString, url: current, locations: "Custom"),
                at: 0
            )
        }
        return options
    }

    private var customInstanceURL: URL? {
        let text = customInstance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }

    private func applyCustomInstance() {
        guard let url = customInstanceURL else { return }
        settings.instanceURL = url
        customInstance = ""
    }

    private func categoryBinding(_ category: String) -> Binding<Bool> {
        Binding(
            get: { settings.sponsorBlockCategories.contains(category) },
            set: { enabled in
                if enabled {
                    settings.sponsorBlockCategories.insert(category)
                } else {
                    settings.sponsorBlockCategories.remove(category)
                }
            }
        )
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
