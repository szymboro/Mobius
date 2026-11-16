import Foundation

/// Builds the subscription feed from several sources, since none is reliable on its own:
/// - Piped's unauthenticated feed is often stale for channels nobody on the instance follows.
/// - YouTube's per-channel RSS has exact dates but is frequently down (HTTP 404 for every channel).
/// - InnerTube's channel "Videos" tab is always current, but only gives relative dates ("2 days ago").
/// Each channel is read from RSS, falling back to InnerTube; the result is merged with Piped's feed.
enum SubscriptionFeed {
    static func load(channelIds: [String], api: PipedAPI) async throws -> [StreamItem] {
        async let pipedResult: Result<[StreamItem], Error> = {
            do { return .success(try await api.feed(channelIds: channelIds)) } catch { return .failure(error) }
        }()
        async let direct = latestFromYouTube(channelIds: channelIds)
        let (piped, fresh) = await (pipedResult, direct)
        try Task.checkCancellation()

        var merged: [String: StreamItem] = [:]
        for item in fresh where !item.videoId.isEmpty { merged[item.videoId] = item }
        switch piped {
        case .success(let items):
            for var item in items where !item.videoId.isEmpty {
                if let direct = merged[item.videoId] {
                    // Piped has durations; keep YouTube's date unless it's only an estimate.
                    if direct.uploaded > 0, direct.uploadedDate == nil || item.uploaded <= 0 {
                        item.uploaded = direct.uploaded
                    }
                    if let views = direct.views, views > (item.views ?? 0) { item.views = views }
                    item.isShort = item.isShort || direct.isShort
                    if item.uploaderAvatar?.isEmpty ?? true { item.uploaderAvatar = direct.uploaderAvatar }
                }
                merged[item.videoId] = item
            }
        case .failure(let error):
            if merged.isEmpty { throw error }
        }
        return Array(merged.values)
    }

    /// Latest uploads of every channel straight from YouTube, at most 8 channels at a time.
    static func latestFromYouTube(channelIds: [String]) async -> [StreamItem] {
        let rssDown = Flag()
        return await withTaskGroup(of: [StreamItem].self) { group in
            var pending = channelIds.makeIterator()
            for _ in 0..<8 {
                if let id = pending.next() { group.addTask { await latest(channelId: id, rssDown: rssDown) } }
            }
            var items: [StreamItem] = []
            while let batch = await group.next() {
                items += batch
                if let id = pending.next() { group.addTask { await latest(channelId: id, rssDown: rssDown) } }
            }
            return items
        }
    }

    private static func latest(channelId: String, rssDown: Flag) async -> [StreamItem] {
        if !rssDown.isSet {
            let items = await YouTubeRSS.channel(channelId, session: .shared)
            if !items.isEmpty { return items }
            // After a few misses assume RSS is down and skip it for the remaining channels.
            rssDown.recordMiss()
        }
        guard let channel = try? await YouTubeInnerTube.channel(id: channelId) else { return [] }
        let now = Date()
        return channel.relatedStreams.enumerated().map { index, item in
            var item = item
            if item.uploaderUrl == nil { item.uploaderUrl = "/channel/\(channelId)" }
            if item.uploaderName == nil { item.uploaderName = channel.name }
            if item.uploaderAvatar == nil { item.uploaderAvatar = channel.avatarUrl }
            if item.uploaded <= 0, let date = relativeDate(item.uploadedDate, now: now) {
                // The tab is newest-first; nudge equal estimates so that order survives sorting.
                item.uploaded = Int(date.timeIntervalSince1970 * 1000) - index
            }
            return item
        }
    }

    /// "3 days ago", "Streamed 2 hours ago", "1 year ago" → approximate date.
    static func relativeDate(_ text: String?, now: Date) -> Date? {
        guard let text else { return nil }
        let words = text.lowercased().split(separator: " ")
        guard let agoIndex = words.firstIndex(of: "ago"), agoIndex >= 2,
              let count = Double(words[agoIndex - 2]) else { return nil }
        let unit = words[agoIndex - 1]
        let seconds: Double
        switch true {
        case unit.hasPrefix("second"): seconds = 1
        case unit.hasPrefix("minute"): seconds = 60
        case unit.hasPrefix("hour"): seconds = 3600
        case unit.hasPrefix("day"): seconds = 86400
        case unit.hasPrefix("week"): seconds = 7 * 86400
        case unit.hasPrefix("month"): seconds = 30 * 86400
        case unit.hasPrefix("year"): seconds = 365 * 86400
        default: return nil
        }
        return now.addingTimeInterval(-count * seconds)
    }

    /// Counts RSS misses across concurrent channel loads.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var misses = 0
        var isSet: Bool { lock.withLock { misses >= 4 } }
        func recordMiss() { lock.withLock { misses += 1 } }
    }
}
