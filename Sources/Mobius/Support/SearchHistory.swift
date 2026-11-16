import Foundation

/// Recently submitted search queries, newest first, kept in `UserDefaults`.
@MainActor
final class SearchHistory: ObservableObject {
    static let shared = SearchHistory()
    static let limit = 20
    private static let key = "searchHistory"

    @Published private(set) var queries: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        queries = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Moves `query` to the top (case-insensitive de-duplication) and trims to `limit`.
    func add(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        queries.insert(text, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
        save()
    }

    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        save()
    }

    func clear() {
        queries = []
        save()
    }

    private func save() {
        defaults.set(queries, forKey: Self.key)
    }
}
