import Foundation
#if canImport(Combine)
import Combine
#endif

/// Video lengths for items whose source has none (YouTube RSS, the main subscription source).
/// Missing lengths are looked up in the background from each channel's InnerTube "Videos" tab,
/// which lists the latest uploads with durations, and cached on disk across launches.
@MainActor
public final class VideoDurations: ObservableObject {
    public static let shared = VideoDurations()

    /// Video id → length in seconds.
    @Published public private(set) var seconds: [String: Int]

    /// Channels looked up recently, so a reload doesn't fetch them again right away.
    private var lookedUp: [String: Date] = [:]
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL?

    private static let maxEntries = 20_000
    private static let retryAfter: TimeInterval = 30 * 60

    init() {
        fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("video-durations.json")
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            seconds = stored
        } else {
            seconds = [:]
        }
    }

    public func duration(for videoId: String) -> Int? { seconds[videoId] }

    /// `items` with cached lengths filled in where they have none.
    public func applying(to items: [StreamItem]) -> [StreamItem] {
        items.map { item in
            guard item.duration == nil, let cached = seconds[item.videoId] else { return item }
            var item = item
            item.duration = cached
            return item
        }
    }

    /// Remembers the lengths these items already carry.
    public func record(_ items: [StreamItem]) {
        var new: [String: Int] = [:]
        for item in items {
            guard let duration = item.duration, duration > 0, !item.videoId.isEmpty,
                  seconds[item.videoId] != duration else { continue }
            new[item.videoId] = duration
        }
        merge(new)
    }

    /// Looks up lengths for items that have none, a few channels at a time.
    public func fill(_ items: [StreamItem]) async {
        let now = Date()
        let channels = Set(items.compactMap { item -> String? in
            guard item.duration == nil, seconds[item.videoId] == nil, !item.isShort,
                  let channelId = item.uploaderChannelId, !channelId.isEmpty else { return nil }
            if let last = lookedUp[channelId], now.timeIntervalSince(last) < Self.retryAfter { return nil }
            return channelId
        })
        guard !channels.isEmpty else { return }
        for id in channels { lookedUp[id] = now }

        await withTaskGroup(of: [StreamItem].self) { group in
            var pending = channels.makeIterator()
            for _ in 0..<4 {
                if let id = pending.next() { group.addTask { await Self.latestVideos(channelId: id) } }
            }
            // Publish in batches so every thumbnail isn't redrawn per channel.
            var batch: [StreamItem] = []
            var finished = 0
            while let videos = await group.next() {
                batch += videos
                finished += 1
                if finished % 6 == 0 {
                    record(batch)
                    batch = []
                }
                if let id = pending.next() { group.addTask { await Self.latestVideos(channelId: id) } }
            }
            record(batch)
        }
    }

    private nonisolated static func latestVideos(channelId: String) async -> [StreamItem] {
        (try? await YouTubeInnerTube.channel(id: channelId).relatedStreams) ?? []
    }

    private func merge(_ new: [String: Int]) {
        guard !new.isEmpty else { return }
        var all = seconds.merging(new) { _, latest in latest }
        if all.count > Self.maxEntries {
            // No age is stored; drop arbitrary old entries, keeping the ones just added.
            for key in all.keys where new[key] == nil {
                all.removeValue(forKey: key)
                if all.count <= Self.maxEntries * 3 / 4 { break }
            }
        }
        seconds = all
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let url = self.fileURL,
                  let data = try? JSONEncoder().encode(self.seconds) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
