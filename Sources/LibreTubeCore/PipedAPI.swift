import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PipedError: Error, Sendable {
    /// Non-2xx HTTP status, with the server's error message if one could be extracted.
    case http(Int, String?)
    case decoding(String)
    case invalidURL
}

extension PipedError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if let message, !message.isEmpty { return "Server error \(code): \(message)" }
            return "Server error \(code)"
        case .decoding(let details):
            return "Could not read server response: \(details)"
        case .invalidURL:
            return "Invalid URL"
        }
    }
}

/// Client for the Piped API (https://docs.piped.video/docs/api-documentation/).
public actor PipedAPI {
    public static let defaultInstanceURL = URL(string: "https://api.piped.private.coffee")!
    public static let instancesURL = URL(string: "https://piped-instances.kavin.rocks/")!
    public static let sponsorBlockURL = URL(string: "https://sponsor.ajay.app")!

    public nonisolated let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        // Normalise: drop trailing slashes so path joining is predictable.
        var string = baseURL.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        self.baseURL = URL(string: string) ?? baseURL
        self.session = session
    }

    // MARK: - Endpoints

    public func trending(region: String) async throws -> [StreamItem] {
        try await getArray(StreamItem.self, path: "trending", query: ["region": region])
    }

    public func streams(videoId: String) async throws -> Streams {
        try await get(Streams.self, path: "streams/\(Self.encodePath(videoId))")
    }

    /// `filter`: "all", "videos", "channels", "playlists" (also any Piped filter such as "music_songs").
    public func search(query: String, filter: String) async throws -> SearchResult {
        try await get(SearchResult.self, path: "search", query: ["q": query, "filter": filter])
    }

    public func searchNextPage(query: String, filter: String, nextpage: String) async throws -> SearchResult {
        try await get(
            SearchResult.self, path: "nextpage/search",
            query: ["nextpage": nextpage, "q": query, "filter": filter]
        )
    }

    /// Search suggestions. Uses `/opensearch/suggestions` (`[query, [suggestions]]`)
    /// and falls back to `/suggestions` (`[suggestions]`).
    public func suggestions(query: String) async throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            let data = try await fetch(try makeURL(path: "opensearch/suggestions", query: ["query": query]))
            if let parsed = Self.parseSuggestions(data) { return parsed }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // fall through to the legacy endpoint
        }
        let data = try await fetch(try makeURL(path: "suggestions", query: ["query": query]))
        guard let parsed = Self.parseSuggestions(data) else {
            throw PipedError.decoding("Unexpected suggestions format")
        }
        return parsed
    }

    public func channel(id: String) async throws -> Channel {
        try await get(Channel.self, path: "channel/\(Self.encodePath(id))")
    }

    public func channelNextPage(id: String, nextpage: String) async throws -> Channel {
        try await get(Channel.self, path: "nextpage/channel/\(Self.encodePath(id))", query: ["nextpage": nextpage])
    }

    public func playlist(id: String) async throws -> Playlist {
        try await get(Playlist.self, path: "playlists/\(Self.encodePath(id))")
    }

    public func playlistNextPage(id: String, nextpage: String) async throws -> Playlist {
        try await get(Playlist.self, path: "nextpage/playlists/\(Self.encodePath(id))", query: ["nextpage": nextpage])
    }

    public func comments(videoId: String) async throws -> CommentsPage {
        try await get(CommentsPage.self, path: "comments/\(Self.encodePath(videoId))")
    }

    /// Also used to load replies: pass a comment's `repliesPage` as `nextpage`.
    public func commentsNextPage(videoId: String, nextpage: String) async throws -> CommentsPage {
        try await get(CommentsPage.self, path: "nextpage/comments/\(Self.encodePath(videoId))", query: ["nextpage": nextpage])
    }

    /// Subscription feed for local subscriptions. POSTs the channel id list as a JSON array
    /// to `/feed/unauthenticated`, newest first.
    public func feed(channelIds: [String]) async throws -> [StreamItem] {
        let ids = channelIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        var request = URLRequest(url: try makeURL(path: "feed/unauthenticated"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ids)
        let data = try await perform(request)
        let items = try Self.decodeArray(StreamItem.self, from: data)
        return items.sorted { $0.uploaded > $1.uploaded }
    }

    /// SponsorBlock segments for a video. Returns an empty list when none exist (HTTP 404).
    public func sponsorSegments(videoId: String, categories: [String]) async throws -> [Segment] {
        guard !categories.isEmpty else { return [] }
        let categoriesJSON = String(decoding: try JSONEncoder().encode(categories), as: UTF8.self)
        let url = try Self.buildURL(
            base: Self.sponsorBlockURL, path: "api/skipSegments",
            query: ["videoID": videoId, "categories": categoriesJSON]
        )
        do {
            let data = try await fetch(url)
            return try Self.decodeArray(Segment.self, from: data)
        } catch PipedError.http(404, _) {
            return []
        }
    }

    /// Public Piped instance list.
    /// Falls back to `fallbackInstances` when the list service is unreachable.
    public static func instances() async throws -> [PipedInstance] {
        do {
            var request = URLRequest(url: instancesURL)
            request.timeoutInterval = 10
            let data = try await performRequest(request, session: .shared)
            let list = try decodeArray(PipedInstance.self, from: data).filter { !$0.apiUrl.isEmpty }
            return list.isEmpty ? fallbackInstances : list
        } catch {
            return fallbackInstances
        }
    }

    /// Snapshot of the public instance list (TeamPiped/documentation), used when
    /// piped-instances.kavin.rocks is down.
    public static let fallbackInstances: [PipedInstance] = [
        ("private.coffee", "https://api.piped.private.coffee", "Austria"),
        ("kavin.rocks", "https://pipedapi.kavin.rocks", "India, Netherlands"),
        ("adminforge.de", "https://pipedapi.adminforge.de", "Germany"),
        ("ducks.party", "https://pipedapi.ducks.party", "Netherlands"),
        ("leptons.xyz", "https://pipedapi.leptons.xyz", "Austria"),
        ("reallyaweso.me", "https://pipedapi.reallyaweso.me", "Germany"),
        ("orangenet.cc", "https://pipedapi.orangenet.cc", "Slovenia"),
        ("piped.yt", "https://api.piped.yt", "Germany"),
        ("drgns.space", "https://pipedapi.drgns.space", "United States"),
        ("owo.si", "https://pipedapi.owo.si", "Slovenia"),
        ("codespace.cz", "https://piped-api.codespace.cz", "Czech Republic"),
        ("privacy.com.de", "https://piped-api.privacy.com.de", "Germany"),
    ].map { PipedInstance(name: $0.0, apiUrl: $0.1, locations: $0.2) }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await fetch(try makeURL(path: path, query: query))
        return try Self.decode(type, from: data)
    }

    private func getArray<T: Decodable>(_ type: T.Type, path: String, query: [String: String] = [:]) async throws -> [T] {
        let data = try await fetch(try makeURL(path: path, query: query))
        return try Self.decodeArray(type, from: data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        try await perform(URLRequest(url: url))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await Self.performRequest(request, session: session)
    }

    private func makeURL(path: String, query: [String: String] = [:]) throws -> URL {
        try Self.buildURL(base: baseURL, path: path, query: query)
    }

    static func buildURL(base: URL, path: String, query: [String: String]) throws -> URL {
        var string = base.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        string += "/" + path
        if !query.isEmpty {
            let encoded = query
                .sorted { $0.key < $1.key }
                .map { "\(encodeQuery($0.key))=\(encodeQuery($0.value))" }
                .joined(separator: "&")
            string += "?" + encoded
        }
        guard let url = URL(string: string) else { throw PipedError.invalidURL }
        return url
    }

    private static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encodeQuery(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? s
    }

    static func encodePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? s
    }

    static func performRequest(_ request: URLRequest, session: URLSession) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if request.timeoutInterval > 30 { request.timeoutInterval = 30 }
        let (data, response) = try await dataTask(request, session: session)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw PipedError.http(http.statusCode, errorMessage(from: data))
        }
        return data
    }

    /// Bridges `dataTask` to async so this also works on Linux Foundation.
    private static func dataTask(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func errorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail", "title"] {
                if let s = obj[key] as? String, !s.isEmpty { return s }
            }
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PipedError.decoding(String(describing: error))
        }
    }

    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        do {
            return try LenientJSON.decodeArray(type, from: data)
        } catch {
            throw PipedError.decoding(String(describing: error))
        }
    }

    /// Accepts both `[query, [suggestions...]]` (OpenSearch) and `[suggestions...]`.
    static func parseSuggestions(_ data: Data) -> [String]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        if array.count >= 2, let list = array[1] as? [Any] {
            return list.compactMap { $0 as? String }
        }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }
}

/// Holds a URLSessionTask so it can be cancelled from a task cancellation handler.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
