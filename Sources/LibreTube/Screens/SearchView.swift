import SwiftUI
import LibreTubeCore

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, videos, channels, playlists

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .videos: "Videos"
        case .channels: "Channels"
        case .playlists: "Playlists"
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var filter: SearchFilter = .all
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var results: [ContentItem] = []
    @Published private(set) var nextpage: String?
    /// `nil` until the first search is submitted.
    @Published private(set) var phase: LoadPhase?
    @Published private(set) var submittedQuery = ""

    private var isLoadingMore = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Debounced suggestions for the current query text.
    func updateSuggestions() async {
        let text = trimmedQuery
        guard !text.isEmpty, text != submittedQuery else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let result = try await AppSettings.shared.api.suggestions(query: text)
            if text == trimmedQuery { suggestions = result }
        } catch {
            suggestions = []
        }
    }

    func submit(_ suggestion: String? = nil) async {
        if let suggestion { query = suggestion }
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        submittedQuery = text
        suggestions = []
        SearchHistory.shared.add(text)
        await search()
    }

    /// Back to the idle screen (recent searches), e.g. after the search field is cleared.
    func reset() {
        submittedQuery = ""
        results = []
        nextpage = nil
        phase = nil
    }

    func search() async {
        let text = submittedQuery
        let filterValue = self.filter.rawValue
        guard !text.isEmpty else { return }
        phase = .loading
        results = []
        nextpage = nil
        do {
            let result = try await AppSettings.shared.api.search(query: text, filter: filterValue)
            // Ignore responses for a query or filter that is no longer current.
            guard text == submittedQuery, filterValue == self.filter.rawValue else { return }
            results = result.items.uniqued()
            nextpage = result.nextpage
            phase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard let page = nextpage, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let text = submittedQuery
        let filterValue = self.filter.rawValue
        do {
            let result = try await AppSettings.shared.api.searchNextPage(query: text, filter: filterValue, nextpage: page)
            guard text == submittedQuery, filterValue == self.filter.rawValue else { return }
            results.appendUnique(result.items)
            nextpage = result.nextpage
        } catch {
            // Leave `nextpage` in place; the sentinel retries when it reappears.
        }
    }
}

struct SearchView: View {
    @StateObject private var model = SearchViewModel()
    @ObservedObject private var history = SearchHistory.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $model.query, prompt: "Search videos, channels, playlists")
            .searchSuggestions {
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(history.queries.prefix(8), id: \.self) { query in
                        Button {
                            Task { await model.submit(query) }
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                        }
                        .foregroundStyle(.primary)
                    }
                }
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await model.submit(suggestion) }
                    } label: {
                        Label(suggestion, systemImage: "magnifyingglass")
                    }
                    .foregroundStyle(.primary)
                }
            }
            .onSubmit(of: .search) {
                Task { await model.submit() }
            }
            .task(id: model.query) {
                await model.updateSuggestions()
            }
            .onChange(of: model.query) { _, query in
                if query.isEmpty { model.reset() }
            }
            .onChange(of: model.filter) {
                Task { await model.search() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let phase = model.phase {
            VStack(spacing: 0) {
                Picker("Filter", selection: $model.filter) {
                    ForEach(SearchFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                PhaseView(phase: phase, retry: { [model] in await model.search() }) {
                    if model.results.isEmpty {
                        ContentUnavailableView.search(text: model.submittedQuery)
                    } else {
                        results
                    }
                }
            }
        } else if !history.queries.isEmpty {
            recentSearches
        } else {
            ContentUnavailableView(
                "Search",
                systemImage: "magnifyingglass",
                description: Text("Find videos, channels and playlists.")
            )
        }
    }

    /// The last `SearchHistory.limit` searches; tap to search again, swipe to remove.
    private var recentSearches: some View {
        List {
            Section {
                ForEach(history.queries, id: \.self) { query in
                    Button {
                        Task { await model.submit(query) }
                    } label: {
                        Label(query, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            history.remove(query)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear") { history.clear() }
                        .font(.subheadline)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }

    private var results: some View {
        List {
            ForEach(model.results.hidingShorts(in: .search)) { item in
                if let route = Route(item) {
                    NavigationLink(value: route) {
                        ContentRow(item: item)
                    }
                }
            }
            LoadMoreView(token: model.nextpage) { [model] in await model.loadMore() }
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }
}
