import Foundation
#if canImport(Combine)
import Combine
#endif

/// Local library (subscriptions, watch history, local playlists), persisted as JSON
/// in Application Support. Writes are debounced (0.5s) and flushed on demand.
@MainActor
public final class LibraryStore: ObservableObject {
    public static let shared = LibraryStore()

    /// Maximum number of history entries kept.
    public static let historyLimit = 500

    @Published public private(set) var subscriptions: [Subscription] = []
    @Published public private(set) var history: [WatchHistoryEntry] = []
    @Published public private(set) var localPlaylists: [LocalPlaylist] = []

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var subscriptions: [Subscription]
        var history: [WatchHistoryEntry]
        var localPlaylists: [LocalPlaylist]

        init(subscriptions: [Subscription], history: [WatchHistoryEntry], localPlaylists: [LocalPlaylist]) {
            self.subscriptions = subscriptions
            self.history = history
            self.localPlaylists = localPlaylists
        }

        enum CodingKeys: String, CodingKey { case subscriptions, history, localPlaylists }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subscriptions = c.array(.subscriptions)
            history = c.array(.history)
            localPlaylists = c.array(.localPlaylists)
        }
    }

    /// - Parameter fileURL: override the storage location (e.g. for tests/previews).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? LibraryStore.defaultFileURL()
        load()
    }

    // MARK: - Subscriptions

    public func isSubscribed(channelId: String) -> Bool {
        let id = channelId.channelIdFromURL
        return subscriptions.contains { $0.channelId == id }
    }

    public func subscribe(_ s: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.channelId == s.channelId }) {
            subscriptions[index] = s
        } else {
            subscriptions.append(s)
            subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        scheduleSave()
    }

    public func unsubscribe(channelId: String) {
        let id = channelId.channelIdFromURL
        subscriptions.removeAll { $0.channelId == id }
        scheduleSave()
    }

    private var isFillingChannelInfo = false

    /// Imports from NewPipe, Takeout or URL lists carry no avatars (and sometimes no names).
    /// Looks those channels up (InnerTube, Piped as fallback) and stores what's missing.
    public func fillMissingChannelInfo() async {
        guard !isFillingChannelInfo else { return }
        let missing = subscriptions
            .filter { ($0.avatar?.isEmpty ?? true) || $0.name.isEmpty }
            .map(\.channelId)
            .filter { !$0.isEmpty }
        guard !missing.isEmpty else { return }
        isFillingChannelInfo = true
        defer { isFillingChannelInfo = false }

        let api = Settings.shared.api
        let lookup: @Sendable (String) async -> (String, Channel?) = { id in
            if let channel = try? await YouTubeInnerTube.channel(id: id), channel.avatarUrl != nil {
                return (id, channel)
            }
            return (id, try? await api.channel(id: id))
        }
        await withTaskGroup(of: (String, Channel?).self) { group in
            var pending = missing.makeIterator()
            for _ in 0..<6 {
                if let id = pending.next() { group.addTask { await lookup(id) } }
            }
            while let (id, result) = await group.next() {
                if let next = pending.next() { group.addTask { await lookup(next) } }
                guard let channel = result,
                      let index = subscriptions.firstIndex(where: { $0.channelId == id }) else { continue }
                var sub = subscriptions[index]
                if sub.avatar?.isEmpty ?? true, let avatar = channel.avatarUrl, !avatar.isEmpty { sub.avatar = avatar }
                if sub.name.isEmpty, let name = channel.name, !name.isEmpty { sub.name = name }
                if channel.verified { sub.verified = true }
                if sub != subscriptions[index] {
                    subscriptions[index] = sub
                    scheduleSave()
                }
            }
        }
        subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scheduleSave()
    }

    /// Channel ids of all subscriptions (for `PipedAPI.feed`).
    public var subscribedChannelIds: [String] {
        subscriptions.map(\.channelId)
    }

    // MARK: - History

    /// Inserts or updates (by `videoId`) the entry and moves it to the top.
    public func recordWatch(_ e: WatchHistoryEntry) {
        guard !e.videoId.isEmpty else { return }
        var entry = e
        if let index = history.firstIndex(where: { $0.videoId == e.videoId }) {
            let existing = history.remove(at: index)
            // Keep metadata we already had if the new entry lacks it.
            if entry.title.isEmpty { entry.title = existing.title }
            if entry.uploader.isEmpty { entry.uploader = existing.uploader }
            if entry.uploaderUrl == nil { entry.uploaderUrl = existing.uploaderUrl }
            if entry.thumbnail == nil { entry.thumbnail = existing.thumbnail }
            if entry.duration <= 0 { entry.duration = existing.duration }
        }
        history.insert(entry, at: 0)
        if history.count > LibraryStore.historyLimit {
            history.removeLast(history.count - LibraryStore.historyLimit)
        }
        scheduleSave()
    }

    /// Last saved playback position for a video, if any.
    public func position(videoId: String) -> Double? {
        history.first { $0.videoId == videoId }?.position
    }

    public func removeFromHistory(videoId: String) {
        history.removeAll { $0.videoId == videoId }
        scheduleSave()
    }

    public func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    // MARK: - Local playlists

    @discardableResult
    public func createPlaylist(name: String) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name)
        localPlaylists.append(playlist)
        scheduleSave()
        return playlist
    }

    public func deletePlaylist(id: UUID) {
        localPlaylists.removeAll { $0.id == id }
        scheduleSave()
    }

    public func renamePlaylist(id: UUID, to name: String) {
        guard let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        localPlaylists[index].name = name
        scheduleSave()
    }

    public func add(_ item: StreamItem, toPlaylist id: UUID) {
        guard let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        guard !localPlaylists[index].videos.contains(where: { $0.videoId == item.videoId }) else { return }
        localPlaylists[index].videos.append(item)
        scheduleSave()
    }

    public func remove(videoId: String, fromPlaylist id: UUID) {
        guard let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        localPlaylists[index].videos.removeAll { $0.videoId == videoId }
        scheduleSave()
    }

    public func playlist(id: UUID) -> LocalPlaylist? {
        localPlaylists.first { $0.id == id }
    }

    // MARK: - Persistence

    /// Writes pending changes immediately (call when the app moves to the background).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        writeNow()
    }

    /// Merges imported data: subscriptions are de-duplicated, playlists are added
    /// (an existing playlist with the same name gets the new videos), history is merged by videoId.
    @discardableResult
    public func apply(_ result: ImportResult) -> String {
        var added = 0
        for sub in result.subscriptions where !sub.channelId.isEmpty {
            if let index = subscriptions.firstIndex(where: { $0.channelId == sub.channelId }) {
                if subscriptions[index].name.isEmpty { subscriptions[index] = sub }
            } else {
                subscriptions.append(sub)
                added += 1
            }
        }
        subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        for playlist in result.playlists {
            if let index = localPlaylists.firstIndex(where: { $0.name == playlist.name }) {
                let existing = Set(localPlaylists[index].videos.map(\.id))
                localPlaylists[index].videos += playlist.videos.filter { !existing.contains($0.id) }
            } else {
                localPlaylists.append(playlist)
            }
        }

        if !result.history.isEmpty {
            let known = Set(history.map(\.videoId))
            history += result.history.filter { !known.contains($0.videoId) }
            history.sort { $0.watchedAt > $1.watchedAt }
            if history.count > LibraryStore.historyLimit {
                history.removeLast(history.count - LibraryStore.historyLimit)
            }
        }
        scheduleSave()

        var parts = ["\(added) new subscriptions"]
        if !result.playlists.isEmpty { parts.append("\(result.playlists.count) playlists") }
        if !result.history.isEmpty { parts.append("\(result.history.count) history entries") }
        return "Imported from \(result.format): " + parts.joined(separator: ", ")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    private func writeNow() {
        let snapshot = Snapshot(subscriptions: subscriptions, history: history, localPlaylists: localPlaylists)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("LibraryStore: failed to save library: \(error)")
            #endif
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        subscriptions = snapshot.subscriptions
        history = Array(snapshot.history.prefix(LibraryStore.historyLimit))
        localPlaylists = snapshot.localPlaylists
    }

    private nonisolated static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("LibreTube", isDirectory: true)
            .appendingPathComponent("library.json")
    }
}
