import Foundation

/// Maps InnerTube video renderers (new `lockupViewModel` and legacy `videoRenderer`,
/// `gridVideoRenderer`, `compactVideoRenderer`, `richItemRenderer`) to `StreamItem`s.
enum InnerTubeItems {
    struct Uploader: Sendable {
        var name: String?
        var url: String?
        var avatar: String?
        var verified: Bool?
    }

    static let videoRendererKeys: Set<String> = ["videoRenderer", "gridVideoRenderer", "compactVideoRenderer"]

    /// Walks `node` collecting videos and the first continuation token, without descending into
    /// matched renderers. Unknown renderers (shelves, ads, shorts lockups) are walked or ignored.
    static func collect(_ node: JNode, fallbackUploader: Uploader? = nil) -> (items: [StreamItem], continuation: String?) {
        var items: [StreamItem] = []
        var continuation: String?
        walk(node, depth: 0, items: &items, continuation: &continuation, fallback: fallbackUploader)
        var seen = Set<String>()
        items = items.filter { seen.insert($0.videoId).inserted }
        return (items, continuation)
    }

    private static func walk(
        _ node: JNode, depth: Int, items: inout [StreamItem], continuation: inout String?, fallback: Uploader?
    ) {
        guard depth < 30 else { return }
        if let dict = node.dict {
            for (key, value) in dict {
                let child = JNode(value)
                switch key {
                case "lockupViewModel":
                    if let item = lockup(child, fallback: fallback) { items.append(item) }
                case _ where videoRendererKeys.contains(key):
                    if let item = videoRenderer(child, fallback: fallback) { items.append(item) }
                case "continuationItemRenderer":
                    if continuation == nil { continuation = token(child) }
                case "reelShelfRenderer", "shortsLockupViewModel", "adSlotRenderer", "menu", "menuButton",
                     "header", "engagementPanels":
                    continue
                default:
                    if child.dict != nil || child.raw is [Any] {
                        walk(child, depth: depth + 1, items: &items, continuation: &continuation, fallback: fallback)
                    }
                }
            }
        } else {
            for child in node.array {
                walk(child, depth: depth + 1, items: &items, continuation: &continuation, fallback: fallback)
            }
        }
    }

    /// Continuation token from a `continuationItemRenderer` (scroll or "Show more" button shape).
    static func token(_ renderer: JNode) -> String? {
        renderer["continuationEndpoint", "continuationCommand", "token"].string
            ?? renderer.first("continuationCommand")["token"].string
            ?? renderer["continuationEndpoint"].first("token").string
    }

    // MARK: lockupViewModel

    static func lockup(_ node: JNode, fallback: Uploader?) -> StreamItem? {
        let type = node["contentType"].string ?? "LOCKUP_CONTENT_TYPE_VIDEO"
        guard type == "LOCKUP_CONTENT_TYPE_VIDEO", let videoId = node["contentId"].string, !videoId.isEmpty else {
            return nil
        }
        let meta = node["metadata", "lockupMetadataViewModel"]
        let image = node["contentImage", "thumbnailViewModel"]

        var durationText: String?
        var isLive = false
        var isShort = false
        for badge in image.all("thumbnailBadgeViewModel") + image.all("thumbnailOverlayBadgeViewModel") {
            let text = badge["text"].string ?? badge.first("text").string
            if let text, InnerTubeText.duration(text) != nil {
                durationText = durationText ?? text
            } else if let text, text.uppercased() == "LIVE" || badge["badgeStyle"].string?.contains("LIVE") == true {
                isLive = true
            } else if text?.uppercased() == "SHORTS" {
                isShort = true
            }
        }

        var uploader = Uploader()
        var views: Int?
        var dateText: String?
        let rows = meta["metadata", "contentMetadataViewModel", "metadataRows"].array
        for (rowIndex, row) in rows.enumerated() {
            for part in row["metadataParts"].array {
                guard let text = part["text"].text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { continue }
                let label = part["accessibilityLabel"].string ?? ""
                let icon = part["leadingIcon"]["name"].string ?? ""
                if InnerTubeText.isViewsText(text) || InnerTubeText.isViewsText(label) || icon.contains("PLAY_ARROW") {
                    views = views ?? InnerTubeText.count(InnerTubeText.isViewsText(label) ? label : text)
                    if text.lowercased().contains("watching") { isLive = true }
                } else if InnerTubeText.isDateText(text) {
                    dateText = dateText ?? text
                } else if uploader.name == nil, rowIndex == 0, rows.count > 1 {
                    uploader.name = text
                    let badges = part["text"]["attachmentRuns"].all("imageName").compactMap(\.string)
                    if badges.contains(where: { $0.contains("CHECK") || $0.contains("AUDIO_BADGE") }) {
                        uploader.verified = true
                    }
                }
            }
        }
        let avatarNode = meta["image"]
        uploader.avatar = InnerTubeText.bestImage(avatarNode.first("avatarViewModel")["image"])
            ?? InnerTubeText.bestImage(avatarNode.first("image"))
        if let browseId = channelBrowseId(meta) ?? channelBrowseId(avatarNode) {
            uploader.url = "/channel/\(browseId)"
        }

        let duration = durationText.flatMap(InnerTubeText.duration)
        return StreamItem(
            url: "/watch?v=\(videoId)",
            title: meta["title"].text,
            thumbnail: InnerTubeText.bestImage(image["image"]) ?? defaultThumbnail(videoId),
            uploaderName: uploader.name ?? fallback?.name,
            uploaderUrl: uploader.url ?? fallback?.url,
            uploaderAvatar: uploader.avatar ?? fallback?.avatar,
            uploadedDate: dateText,
            duration: isLive ? -1 : duration,
            views: views,
            uploaderVerified: uploader.verified ?? fallback?.verified,
            isShort: isShort
        )
    }

    /// First `browseEndpoint.browseId` that is a channel id ("UC…").
    static func channelBrowseId(_ node: JNode) -> String? {
        node.all("browseEndpoint").compactMap { $0["browseId"].string }.first { $0.hasPrefix("UC") }
    }

    // MARK: Legacy renderers

    static func videoRenderer(_ node: JNode, fallback: Uploader?) -> StreamItem? {
        guard let videoId = node["videoId"].string, !videoId.isEmpty else { return nil }
        let byline = [node["ownerText"], node["longBylineText"], node["shortBylineText"]].first { $0.exists } ?? .empty
        let ownerRun = byline["runs", 0]
        let channelId = ownerRun["navigationEndpoint", "browseEndpoint", "browseId"].string ?? channelBrowseId(byline)
        let avatar = InnerTubeText.bestImage(node["channelThumbnailSupportedRenderers", "channelThumbnailWithLinkRenderer", "thumbnail"])
            ?? InnerTubeText.bestImage(node["channelThumbnail"])
            ?? InnerTubeText.bestImage(node.first("avatarViewModel")["image"])
        let badges = node["ownerBadges"].all("style").compactMap(\.string)
        let verified = badges.isEmpty ? nil : badges.contains { $0.contains("VERIFIED") }

        let overlays = node["thumbnailOverlays"]
        let lengthText = node["lengthText"].text
            ?? overlays.first("thumbnailOverlayTimeStatusRenderer")["text"].text
        let overlayStyle = overlays.first("thumbnailOverlayTimeStatusRenderer")["style"].string ?? ""
        let liveBadge = node["badges"].all("label").compactMap(\.string).contains { $0.uppercased().contains("LIVE") }
        let isLive = overlayStyle == "LIVE" || liveBadge
        let isShort = overlayStyle == "SHORTS"

        let viewText = node["viewCountText"].text ?? node["shortViewCountText"].text
        return StreamItem(
            url: "/watch?v=\(videoId)",
            title: node["title"].text ?? node["headline"].text,
            thumbnail: InnerTubeText.bestImage(node["thumbnail"]) ?? defaultThumbnail(videoId),
            uploaderName: ownerRun["text"].string ?? byline.text ?? fallback?.name,
            uploaderUrl: channelId.map { "/channel/\($0)" } ?? fallback?.url,
            uploaderAvatar: avatar ?? fallback?.avatar,
            uploadedDate: node["publishedTimeText"].text,
            duration: isLive ? -1 : InnerTubeText.duration(lengthText),
            views: InnerTubeText.count(viewText),
            uploaderVerified: verified ?? fallback?.verified,
            shortDescription: node["descriptionSnippet"].text,
            isShort: isShort
        )
    }

    static func defaultThumbnail(_ videoId: String) -> String {
        "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }
}
