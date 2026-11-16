import MobiusCore
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
    @State private var showingLog = false
    @State private var exportFile: ExportFile?

    var body: some View {
        Form {
            Section {
                SettingsLogoHeader(version: appVersion)
            }
            .listRowBackground(Color.clear)
            streamSourceSection
            instanceSection
            contentSection
            sponsorBlockSection
            deArrowSection
            dislikeSection
            importSection
            historySection
            aboutSection
        }
        .navigationTitle("Settings")
        .task {
            if instances.options.isEmpty { await instances.load() }
        }
        // Presented from the Form (not from inside a row) so the picker's result isn't lost
        // when the row is re-rendered.
        .sheet(isPresented: $importing) {
            DocumentPicker(contentTypes: Self.importTypes) { urls in
                importing = false
                handleImport(urls)
            } onCancel: {
                importing = false
                PlaybackLog.shared.add("import: picker cancelled", "import")
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingLog) { PlaybackLogView() }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Import & Export", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private static let importTypes: [UTType] = [.json, .commaSeparatedText, .plainText, .text, .data, .item]

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
            NavigationLink("Home Sections") { HomeSectionsSettingsView() }
            NavigationLink { ShortsSettingsView() } label: {
                LabeledContent("Shorts", value: settings.hideShorts ? "Hidden" : "Shown")
            }

            Picker("Live Now Region", selection: $settings.region) {
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

            Toggle("Autoplay Next Video", isOn: $settings.autoplay)
            Toggle("Audio Only", isOn: $settings.audioOnly)
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

    private var deArrowSection: some View {
        Section {
            Toggle("Replace Titles", isOn: $settings.deArrowTitles)
            Toggle("Replace Thumbnails", isOn: $settings.deArrowThumbnails)
            Link(destination: URL(string: "https://dearrow.ajay.app")!) {
                Label("About DeArrow", systemImage: "info.circle")
            }
        } header: {
            Text("DeArrow")
        } footer: {
            Text("""
            Swaps clickbait titles and thumbnails for ones submitted and voted on by the community \
            (from the makers of SponsorBlock). Videos nobody has fixed keep their original. Each \
            lookup only sends a short hash prefix of the video ID, so DeArrow can't tell exactly \
            which video you're viewing.
            """)
        }
    }

    private var dislikeSection: some View {
        Section {
            Toggle("Show Dislikes", isOn: $settings.returnYouTubeDislike)
            Link(destination: URL(string: "https://returnyoutubedislike.com")!) {
                Label("About Return YouTube Dislike", systemImage: "info.circle")
            }
        } header: {
            Text("Return YouTube Dislike")
        } footer: {
            Text("""
            Shows a dislike count under the video title. YouTube hid dislikes in 2021, so the \
            number is an estimate from archived data and from people using the extension. The \
            ID of each video you open is sent to returnyoutubedislikeapi.com.
            """)
        }
    }

    private var importSection: some View {
        Section {
            Button {
                PlaybackLog.shared.add("import: opening file picker", "import")
                importing = true
            } label: {
                Label("Import Subscriptions & Playlists", systemImage: "square.and.arrow.down")
            }
            Button {
                export("subscriptions") { try Exporter.newPipeSubscriptions(library.subscriptions) }
            } label: {
                Label("Export Subscriptions (.json)", systemImage: "square.and.arrow.up")
            }
            .disabled(library.subscriptions.isEmpty)
            Button {
                export("backup") {
                    try Exporter.backup(subscriptions: library.subscriptions,
                                        playlists: library.localPlaylists, history: library.history)
                }
            } label: {
                Label("Export Full Backup (.json)", systemImage: "externaldrive")
            }
        } header: {
            Text("Import & Export")
        } footer: {
            Text("""
            Supported files, detected automatically:
            • NewPipe: Settings › Backup and restore › Export subscriptions (.json)
            • LibreTube / Piped backup (.json): subscriptions, playlists, history
            • FreeTube profiles (.db)
            • YouTube Takeout subscriptions (.csv)
            • Text file with channel or video links (.txt)

            Export Subscriptions writes NewPipe's format, which NewPipe, LibreTube, FreeTube and \
            Mobius can import. Export Full Backup also includes playlists, watch history and resume \
            positions; import it here to restore everything.

            Using LiveContainer? If choosing a file does nothing, enable "Fix File Picker" in Mobius's settings inside LiveContainer.
            """)
        }
    }

    /// Writes an export to a temporary file and offers it in the share sheet ("Save to Files").
    private func export(_ kind: String, _ make: () throws -> Data) {
        let date = Date.now.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobius-\(kind)-\(date).json")
        do {
            try make().write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ urls: [URL]) {
        let log = PlaybackLog.shared
        log.add("import: picked \(urls.count) file(s): \(urls.map(\.lastPathComponent).joined(separator: ", "))", "import")
        guard !urls.isEmpty else {
            importMessage = "No file was received from the file picker."
            return
        }
        var messages: [String] = []
        for url in urls {
            // Copies (asCopy) live in our tmp dir; security scope is only needed for originals.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let parsed = try Importer.parse(data, filename: url.lastPathComponent)
                let summary = library.apply(parsed)
                Task { await library.fillMissingChannelInfo() }
                log.add("import: \(url.lastPathComponent) (\(data.count) B): \(summary)", "import")
                messages.append(summary)
            } catch {
                log.add("import: \(url.lastPathComponent) failed: \(error.localizedDescription)", "import")
                messages.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Let the sheet finish dismissing before the alert is presented.
        let message = messages.joined(separator: "\n\n")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            importMessage = message
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
            Button {
                showingLog = true
            } label: {
                Label("Diagnostics Log", systemImage: "ladybug")
            }
            Link("Mobius on GitHub", destination: URL(string: "https://github.com/szymboro/Mobius")!)
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

/// Turns the Home tab's sections on and off.
struct HomeSectionsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(HomeSection.allCases) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { settings.isHomeSectionEnabled(section) },
                        set: { settings.setHomeSection(section, enabled: $0) }
                    ))
                }
            } footer: {
                Text("YouTube no longer has a Trending page; the only list it still offers there is live streams, shown as Live Now.")
            }
        }
        .navigationTitle("Home Sections")
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, e.g. to save an export with "Save to Files".
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Hides Shorts everywhere or on chosen screens, optionally treating short videos as Shorts.
struct ShortsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Hide Shorts", isOn: $settings.hideShorts)
            } footer: {
                Text("Removes Shorts from video lists. Channels and playlists in search results stay.")
            }

            if settings.hideShorts {
                Section {
                    Toggle("Everywhere", isOn: Binding(
                        get: { settings.hideShortsIn == Set(ShortsPlace.allCases) },
                        set: { settings.hideShortsIn = $0 ? Set(ShortsPlace.allCases) : [] }
                    ))
                    ForEach(ShortsPlace.allCases) { place in
                        Toggle(place.title, isOn: Binding(
                            get: { settings.hideShortsIn.contains(place) },
                            set: { on in
                                if on { settings.hideShortsIn.insert(place) } else { settings.hideShortsIn.remove(place) }
                            }
                        ))
                    }
                } header: {
                    Text("Hide In")
                }

                Section {
                    Picker("Also Hide Videos Up To", selection: $settings.shortsMaxDuration) {
                        ForEach(AppSettings.shortsDurationOptions, id: \.self) { seconds in
                            Text(Self.durationTitle(seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Length")
                } footer: {
                    Text("""
                    Videos YouTube marks as Shorts are always hidden. Not every source marks them \
                    (e.g. the subscription feed), so you can also hide any video this short or shorter.
                    """)
                }
            }
        }
        .navigationTitle("Shorts")
    }

    private static func durationTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Off (marked Shorts only)"
        case ..<60: "\(seconds) seconds"
        case let s where s % 60 == 0: s == 60 ? "1 minute" : "\(s / 60) minutes"
        default: "\(seconds / 60):\(String(format: "%02d", seconds % 60)) minutes"
        }
    }
}

/// UIKit document picker in copy mode: the chosen files are copied into the app's tmp folder,
/// so reading them needs no security-scoped access (which is unreliable inside LiveContainer).
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
