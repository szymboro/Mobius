import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Watch-page metadata from InnerTube `next` that the iOS player endpoint doesn't return.
public struct VideoDetails: Hashable, Sendable {
    public var videoId: String
    public var title: String?
    public var uploaderName: String?
    public var uploaderUrl: String?
    public var uploaderAvatar: String?
    public var uploaderVerified: Bool
    public var uploaderSubscriberCount: Int?
    /// As displayed, e.g. "4.56M subscribers".
    public var uploaderSubscriberText: String?
    public var likes: Int?
    public var views: Int?
    /// As displayed, e.g. "Oct 24, 2009" or "Premiered Oct 24, 2009".
    public var uploadDateText: String?
    /// `uploadDateText` parsed (UTC midnight), when it holds an absolute date.
    public var uploadDate: Date?
    /// e.g. "17 years ago".
    public var relativeDateText: String?
    public var related: [StreamItem]
    /// Pass to `YouTubeInnerTube.commentsNextPage` to get the first comments page.
    public var commentsContinuation: String?

    public init(
        videoId: String, title: String? = nil, uploaderName: String? = nil, uploaderUrl: String? = nil,
        uploaderAvatar: String? = nil, uploaderVerified: Bool = false, uploaderSubscriberCount: Int? = nil,
        uploaderSubscriberText: String? = nil, likes: Int? = nil, views: Int? = nil, uploadDateText: String? = nil,
        uploadDate: Date? = nil, relativeDateText: String? = nil, related: [StreamItem] = [],
        commentsContinuation: String? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.uploaderName = uploaderName
        self.uploaderUrl = uploaderUrl
        self.uploaderAvatar = uploaderAvatar
        self.uploaderVerified = uploaderVerified
        self.uploaderSubscriberCount = uploaderSubscriberCount
        self.uploaderSubscriberText = uploaderSubscriberText
        self.likes = likes
        self.views = views
        self.uploadDateText = uploadDateText
        self.uploadDate = uploadDate
        self.relativeDateText = relativeDateText
        self.related = related
        self.commentsContinuation = commentsContinuation
    }
}

/// On-device YouTube metadata through InnerTube's WEB client (`browse`, `next`). No tokens needed.
/// Fills in what the decayed Piped instances and the iOS player endpoint leave out: channel videos,
/// uploader avatars, likes, related videos and comments with avatars.
public enum YouTubeInnerTube {
    /// Used when the current version can't be scraped (see `YouTubeExtractor.webSession`).
    static let fallbackClientVersion = "2.20261112.10.00"
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
    /// Channel "Videos" tab.
    static let videosTabParams = "EgZ2aWRlb3PyBgQKAjoA"

    // MARK: Public API

    public static func channel(id: String, session: URLSession = .shared) async throws -> Channel {
        let browseId = try await resolveChannelId(id, session: session)
        let json = try await post("browse", ["browseId": browseId, "params": videosTabParams], session: session)
        var channel = InnerTubeChannelParser.channel(json, requestedId: browseId)
        guard channel.name != nil || !channel.relatedStreams.isEmpty else {
            throw ExtractorError.malformedResponse
        }
        channelHeaders.update { $0[channel.id ?? browseId] = channel.uploader }
        if channel.id == nil { channel.id = browseId }
        return channel
    }

    public static func channelNextPage(id: String, nextpage: String, session: URLSession = .shared) async throws -> Channel {
        let json = try await post("browse", ["continuation": nextpage], session: session)
        let root = JNode(json)
        let fallback = channelHeaders.value[id]
            ?? InnerTubeItems.Uploader(url: id.hasPrefix("UC") ? "/channel/\(id)" : nil)
        let actions = JNode([root["onResponseReceivedActions"].raw, root["onResponseReceivedEndpoints"].raw]
            .compactMap { $0 })
        let (items, continuation) = InnerTubeItems.collect(actions, fallbackUploader: fallback)
        return Channel(id: id.hasPrefix("UC") ? id : nil, nextpage: continuation, relatedStreams: items)
    }

    public static func next(videoId: String, session: URLSession = .shared) async throws -> VideoDetails {
        let json = try await post("next", ["videoId": videoId], session: session)
        let details = InnerTubeNextParser.details(json, videoId: videoId)
        if let token = details.commentsContinuation {
            commentTokens.update { $0[videoId] = (token, Date()) }
        }
        return details
    }

    /// First comments page ("Top comments").
    public static func comments(videoId: String, session: URLSession = .shared) async throws -> CommentsPage {
        var token: String?
        if let cached = commentTokens.value[videoId], Date().timeIntervalSince(cached.fetched) < 1800 {
            token = cached.token
        } else {
            let json = try await post("next", ["videoId": videoId], session: session)
            let details = InnerTubeNextParser.details(json, videoId: videoId)
            token = details.commentsContinuation
            if token == nil {
                return CommentsPage(disabled: true)
            }
        }
        guard let token else { return CommentsPage(disabled: true) }
        return try await commentsNextPage(videoId: videoId, nextpage: token, session: session)
    }

    /// Next comments page, or replies when `nextpage` is a comment's `repliesPage`.
    public static func commentsNextPage(videoId: String, nextpage: String, session: URLSession = .shared) async throws -> CommentsPage {
        let json = try await post("next", ["continuation": nextpage], session: session)
        return InnerTubeCommentsParser.page(json)
    }

    // MARK: Channel id resolution

    /// "UC…" ids pass through; handles ("@name"), custom ("/c/") and legacy user names are resolved
    /// with `navigation/resolve_url`.
    static func resolveChannelId(_ id: String, session: URLSession) async throws -> String {
        let id = id.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("UC"), id.count == 24 { return id }
        let candidates: [String]
        if id.hasPrefix("@") {
            candidates = ["https://www.youtube.com/\(id)"]
        } else {
            candidates = ["https://www.youtube.com/c/\(id)", "https://www.youtube.com/user/\(id)",
                          "https://www.youtube.com/@\(id)"]
        }
        var lastError: (any Error)?
        for url in candidates {
            do {
                let json = try await post("navigation/resolve_url", ["url": url], session: session)
                if let browseId = JNode(json).first("browseEndpoint")["browseId"].string, browseId.hasPrefix("UC") {
                    return browseId
                }
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        if id.hasPrefix("UC") { return id }
        throw lastError ?? ExtractorError.malformedResponse
    }

    // MARK: Transport

    private static let clientCache = InnerTubeLock<(version: String, visitorData: String?, fetched: Date)?>(nil)
    private static let channelHeaders = InnerTubeLock<[String: InnerTubeItems.Uploader]>([:])
    private static let commentTokens = InnerTubeLock<[String: (token: String, fetched: Date)]>([:])

    /// Current WEB client version, reusing the extractor's scraped `sw.js_data` session when it works.
    static func client(session: URLSession) async -> (version: String, visitorData: String?) {
        if let cached = clientCache.value {
            let age = Date().timeIntervalSince(cached.fetched)
            // A failed scrape is retried after 10 minutes, a good one after an hour.
            if age < (cached.visitorData == nil ? 600 : 3600) { return (cached.version, cached.visitorData) }
        }
        let result: (version: String, visitorData: String?)
        if let web = try? await YouTubeExtractor.webSession(session: session) {
            result = (web.clientVersion, web.visitorData)
        } else {
            result = (fallbackClientVersion, nil)
        }
        clientCache.value = (result.version, result.visitorData, Date())
        return result
    }

    static func post(_ endpoint: String, _ body: [String: Any], session: URLSession) async throws -> [String: Any] {
        let client = await client(session: session)
        var clientContext: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": client.version,
            "hl": "en",
            "gl": Locale.current.region?.identifier ?? "US",
        ]
        if let visitorData = client.visitorData { clientContext["visitorData"] = visitorData }
        var payload = body
        payload["context"] = ["client": clientContext]

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let visitorData = client.visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        let data = try await PipedAPI.performRequest(request, session: session)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.malformedResponse
        }
        return json
    }
}

/// Minimal lock-protected box (kept local so this file doesn't depend on SABR internals).
final class InnerTubeLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }
}

// MARK: - Channel

enum InnerTubeChannelParser {
    static func channel(_ json: [String: Any], requestedId: String) -> Channel {
        let root = JNode(json)
        let meta = root["metadata", "channelMetadataRenderer"]
        let pageHeader = root["header"].first("pageHeaderViewModel")
        let legacyHeader = root["header"]["c4TabbedHeaderRenderer"]

        let id = meta["externalId"].string ?? legacyHeader["channelId"].string ?? requestedId
        let name = meta["title"].string ?? pageHeader["title"].text ?? legacyHeader["title"].text
        let avatar = InnerTubeText.bestImage(pageHeader["image"].first("avatarViewModel")["image"])
            ?? InnerTubeText.bestImage(meta["avatar"])
            ?? InnerTubeText.bestImage(legacyHeader["avatar"])
        let banner = InnerTubeText.bestImage(pageHeader["banner"].first("image"))
            ?? InnerTubeText.bestImage(legacyHeader["banner"])

        var subscriberText: String?
        for row in pageHeader.first("contentMetadataViewModel")["metadataRows"].array {
            for part in row["metadataParts"].array {
                if let text = part["text"].text, text.lowercased().contains("subscriber") { subscriberText = text }
            }
        }
        subscriberText = subscriberText ?? legacyHeader["subscriberCountText"].text

        let titleBadges = pageHeader["title"].all("imageName").compactMap(\.string)
        let legacyBadges = legacyHeader["badges"].all("style").compactMap(\.string)
        let verified = titleBadges.contains { $0.contains("CHECK") || $0.contains("AUDIO_BADGE") || $0.contains("VERIFIED") }
            || legacyBadges.contains { $0.contains("VERIFIED") }

        let description = meta["description"].string
            ?? pageHeader["description"].first("description").text

        let uploader = InnerTubeItems.Uploader(name: name, url: "/channel/\(id)", avatar: avatar, verified: verified)

        // Selected tab content (Videos), falling back to every tab.
        let tabs = root["contents", "twoColumnBrowseResultsRenderer", "tabs"].array
        let selected = tabs.first { $0["tabRenderer", "selected"].bool == true }?["tabRenderer", "content"]
        let content = selected ?? root["contents"]
        let (items, continuation) = InnerTubeItems.collect(content, fallbackUploader: uploader)

        return Channel(
            id: id, name: name, avatarUrl: avatar, bannerUrl: banner,
            description: InnerTubeText.html(description), nextpage: continuation,
            subscriberCount: InnerTubeText.count(subscriberText) ?? 0, verified: verified,
            relatedStreams: items
        )
    }
}

extension Channel {
    var uploader: InnerTubeItems.Uploader {
        InnerTubeItems.Uploader(name: name, url: id.map { "/channel/\($0)" }, avatar: avatarUrl, verified: verified)
    }
}

// MARK: - Watch page

enum InnerTubeNextParser {
    static func details(_ json: [String: Any], videoId: String) -> VideoDetails {
        let root = JNode(json)
        let watch = root["contents", "twoColumnWatchNextResults"]
        let results = watch["results", "results", "contents"]
        let primary = results.first("videoPrimaryInfoRenderer")
        let secondary = results.first("videoSecondaryInfoRenderer")
        let owner = secondary.first("videoOwnerRenderer")

        var details = VideoDetails(videoId: videoId)
        details.title = primary["title"].text
        let ownerRun = owner["title", "runs", 0]
        details.uploaderName = ownerRun["text"].string ?? owner["title"].text
        if let channelId = ownerRun["navigationEndpoint", "browseEndpoint", "browseId"].string
            ?? owner["navigationEndpoint", "browseEndpoint", "browseId"].string {
            details.uploaderUrl = "/channel/\(channelId)"
        }
        details.uploaderAvatar = InnerTubeText.bestImage(owner["thumbnail"])
            ?? InnerTubeText.bestImage(owner.first("avatarViewModel")["image"])
        let badgeStyles = owner["badges"].all("style").compactMap(\.string)
        details.uploaderVerified = badgeStyles.contains { $0.contains("VERIFIED") }
        details.uploaderSubscriberText = owner["subscriberCountText"].text
        details.uploaderSubscriberCount = InnerTubeText.count(details.uploaderSubscriberText)

        details.likes = likes(primary) ?? likes(root["playerOverlays"])
        let viewRenderer = primary["viewCount", "videoViewCountRenderer"]
        details.views = viewRenderer["originalViewCount"].int ?? InnerTubeText.count(viewRenderer["viewCount"].text)
        details.uploadDateText = primary["dateText"].text
        details.uploadDate = InnerTubeText.absoluteDate(details.uploadDateText)
        details.relativeDateText = primary["relativeDateText"].text

        let secondaryResults = watch["secondaryResults", "secondaryResults", "results"]
        details.related = InnerTubeItems.collect(secondaryResults).items
        details.commentsContinuation = commentsToken(root)
        return details
    }

    /// Exact count from the like button's accessibility text ("along with 19,507,780 other people"),
    /// else its compact title ("19M").
    static func likes(_ node: JNode) -> Int? {
        let button = node.first("segmentedLikeDislikeButtonViewModel")["likeButtonViewModel"]
        let scope = button.exists ? button : node.first("likeButtonViewModel")
        guard scope.exists else { return nil }
        let viewModel = scope.first("buttonViewModel")
        if let a11y = viewModel["accessibilityText"].string,
           let range = a11y.range(of: #"\d[\d,.]*"#, options: .regularExpression) {
            let digits = a11y[range].filter(\.isNumber)
            if let value = Int(digits) { return value }
        }
        if let title = viewModel["title"].string, title.first?.isNumber == true {
            return InnerTubeText.count(title)
        }
        // Legacy toggleButtonRenderer.
        if let text = scope.first("defaultText").text, text.first?.isNumber == true {
            return InnerTubeText.count(text)
        }
        return nil
    }

    static func commentsToken(_ root: JNode) -> String? {
        let contents = root["contents", "twoColumnWatchNextResults", "results", "results", "contents"]
        for section in contents.array {
            let item = section["itemSectionRenderer"]
            let id = (item["sectionIdentifier"].string ?? "") + (item["targetId"].string ?? "")
            guard id.contains("comment") else { continue }
            if let token = InnerTubeItems.token(item.first("continuationItemRenderer")) { return token }
        }
        for panel in root["engagementPanels"].array {
            let renderer = panel["engagementPanelSectionListRenderer"]
            guard (renderer["panelIdentifier"].string ?? "").contains("comment") else { continue }
            if let token = InnerTubeItems.token(renderer["content"].first("continuationItemRenderer")) { return token }
        }
        return nil
    }
}
