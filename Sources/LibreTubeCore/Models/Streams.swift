import Foundation

/// Full video details from `/streams/{videoId}`. Mirrors `api/obj/Streams.kt`.
public struct Streams: Codable, Hashable, Identifiable, Sendable {
    public static let categoryMusic = "Music"

    public var title: String
    public var description: String
    /// ISO-8601 upload date string as sent by Piped (`uploadDate`).
    public var uploadDate: String?
    /// Upload time in epoch milliseconds, if provided.
    public var uploaded: Int?
    public var uploader: String
    public var uploaderUrl: String?
    public var uploaderAvatar: String?
    public var thumbnailUrl: String
    public var category: String
    public var license: String
    public var visibility: String
    public var tags: [String]
    public var metaInfo: [MetaInfo]
    public var hls: String?
    public var dash: String?
    public var uploaderVerified: Bool
    /// Seconds.
    public var duration: Int
    public var views: Int
    public var likes: Int
    public var dislikes: Int
    public var audioStreams: [PipedStream]
    public var videoStreams: [PipedStream]
    public var relatedStreams: [StreamItem]
    public var subtitles: [Subtitle]
    public var livestream: Bool
    public var proxyUrl: String?
    public var chapters: [ChapterSegment]
    public var uploaderSubscriberCount: Int
    public var previewFrames: [PreviewFrames]
    public var isShort: Bool

    /// Best-effort identifier (Piped does not echo the video id back).
    public var id: String {
        if !thumbnailUrl.isEmpty, let vid = Streams.videoIdFromThumbnail(thumbnailUrl) { return vid }
        return "\(uploaderUrl ?? uploader)|\(title)"
    }

    public var isLive: Bool { livestream || duration <= 0 }

    /// Parsed `uploadDate`, falling back to `uploaded` millis.
    public var uploadTimestamp: Date? {
        if let uploadDate, let date = Streams.parseISODate(uploadDate) { return date }
        if let uploaded, uploaded > 0 { return Date(timeIntervalSince1970: TimeInterval(uploaded) / 1000) }
        return nil
    }

    public var uploaderChannelId: String? { uploaderUrl?.channelIdFromURL }

    public init(
        title: String = "",
        description: String = "",
        uploadDate: String? = nil,
        uploaded: Int? = nil,
        uploader: String = "",
        uploaderUrl: String? = nil,
        uploaderAvatar: String? = nil,
        thumbnailUrl: String = "",
        category: String = "",
        license: String = "YouTube licence",
        visibility: String = "public",
        tags: [String] = [],
        metaInfo: [MetaInfo] = [],
        hls: String? = nil,
        dash: String? = nil,
        uploaderVerified: Bool = false,
        duration: Int = 0,
        views: Int = 0,
        likes: Int = 0,
        dislikes: Int = 0,
        audioStreams: [PipedStream] = [],
        videoStreams: [PipedStream] = [],
        relatedStreams: [StreamItem] = [],
        subtitles: [Subtitle] = [],
        livestream: Bool = false,
        proxyUrl: String? = nil,
        chapters: [ChapterSegment] = [],
        uploaderSubscriberCount: Int = 0,
        previewFrames: [PreviewFrames] = [],
        isShort: Bool = false
    ) {
        self.title = title
        self.description = description
        self.uploadDate = uploadDate
        self.uploaded = uploaded
        self.uploader = uploader
        self.uploaderUrl = uploaderUrl
        self.uploaderAvatar = uploaderAvatar
        self.thumbnailUrl = thumbnailUrl
        self.category = category
        self.license = license
        self.visibility = visibility
        self.tags = tags
        self.metaInfo = metaInfo
        self.hls = hls
        self.dash = dash
        self.uploaderVerified = uploaderVerified
        self.duration = duration
        self.views = views
        self.likes = likes
        self.dislikes = dislikes
        self.audioStreams = audioStreams
        self.videoStreams = videoStreams
        self.relatedStreams = relatedStreams
        self.subtitles = subtitles
        self.livestream = livestream
        self.proxyUrl = proxyUrl
        self.chapters = chapters
        self.uploaderSubscriberCount = uploaderSubscriberCount
        self.previewFrames = previewFrames
        self.isShort = isShort
    }

    enum CodingKeys: String, CodingKey {
        case title, description, uploadDate, uploaded, uploader, uploaderUrl, uploaderAvatar,
             thumbnailUrl, category, license, visibility, tags, metaInfo, hls, dash,
             uploaderVerified, duration, views, likes, dislikes, audioStreams, videoStreams,
             relatedStreams, subtitles, livestream, proxyUrl, chapters, uploaderSubscriberCount,
             previewFrames, isShort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title, default: "")
        description = c.string(.description, default: "")
        uploadDate = c.string(.uploadDate)
        uploaded = c.int(.uploaded)
        uploader = c.string(.uploader, default: "")
        uploaderUrl = c.string(.uploaderUrl)
        uploaderAvatar = c.string(.uploaderAvatar)
        thumbnailUrl = c.string(.thumbnailUrl, default: "")
        category = c.string(.category, default: "")
        license = c.string(.license, default: "YouTube licence")
        visibility = c.string(.visibility, default: "public")
        tags = c.array(.tags)
        metaInfo = c.array(.metaInfo)
        hls = c.string(.hls)
        dash = c.string(.dash)
        uploaderVerified = c.bool(.uploaderVerified, default: false)
        duration = c.int(.duration, default: 0)
        views = c.int(.views, default: 0)
        likes = c.int(.likes, default: 0)
        dislikes = c.int(.dislikes, default: 0)
        audioStreams = c.array(.audioStreams)
        videoStreams = c.array(.videoStreams)
        relatedStreams = c.array(.relatedStreams)
        subtitles = c.array(.subtitles)
        livestream = c.bool(.livestream, default: false)
        proxyUrl = c.string(.proxyUrl)
        chapters = c.array(.chapters)
        uploaderSubscriberCount = c.int(.uploaderSubscriberCount, default: 0)
        previewFrames = c.array(.previewFrames)
        isShort = c.bool(.isShort, default: false)
    }

    /// Converts to a list item for the given video id (for history, playlists, queues).
    public func toStreamItem(videoId: String) -> StreamItem {
        StreamItem(
            url: "/watch?v=\(videoId)",
            type: StreamItem.typeStream,
            title: title,
            thumbnail: thumbnailUrl,
            uploaderName: uploader,
            uploaderUrl: uploaderUrl,
            uploaderAvatar: uploaderAvatar,
            uploadedDate: uploadDate,
            duration: duration,
            views: views,
            uploaderVerified: uploaderVerified,
            uploaded: uploaded ?? uploadTimestamp.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
            shortDescription: description,
            isShort: isShort
        )
    }

    static func parseISODate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: string) { return d }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: String(string.prefix(10)))
    }

    static func videoIdFromThumbnail(_ url: String) -> String? {
        // e.g. https://i.ytimg.com/vi/VIDEOID/maxresdefault.jpg (possibly proxied, keeps /vi/ID/)
        for marker in ["/vi/", "/vi_webp/"] {
            if let range = url.range(of: marker) {
                let rest = url[range.upperBound...]
                let id = rest.prefix { $0 != "/" && $0 != "?" }
                if !id.isEmpty { return String(id) }
            }
        }
        return nil
    }
}

/// An audio or video stream. Mirrors `api/obj/PipedStream.kt`.
public struct PipedStream: Codable, Hashable, Identifiable, Sendable {
    public var url: String?
    public var format: String?
    public var quality: String?
    public var mimeType: String?
    public var codec: String?
    public var videoOnly: Bool?
    public var bitrate: Int?
    public var initStart: Int?
    public var initEnd: Int?
    public var indexStart: Int?
    public var indexEnd: Int?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var durationMs: Int?
    public var audioTrackName: String?
    public var audioTrackId: String?
    public var contentLength: Int
    public var audioTrackType: String?
    public var audioTrackLocale: String?
    public var itag: Int?
    public var lastModified: Int?
    public var isDrc: Bool?
    public var xtags: String?

    public var id: String {
        url ?? "\(itag ?? -1)|\(quality ?? "")|\(format ?? "")|\(audioTrackId ?? "")"
    }

    /// Numeric height parsed from `height` or the quality label ("1080p60" -> 1080).
    public var resolution: Int? {
        if let height, height > 0 { return height }
        guard let quality else { return nil }
        let digits = quality.prefix { $0.isNumber }
        return Int(digits)
    }

    public init(
        url: String? = nil, format: String? = nil, quality: String? = nil, mimeType: String? = nil,
        codec: String? = nil, videoOnly: Bool? = nil, bitrate: Int? = nil, initStart: Int? = nil,
        initEnd: Int? = nil, indexStart: Int? = nil, indexEnd: Int? = nil, width: Int? = nil,
        height: Int? = nil, fps: Int? = nil, durationMs: Int? = nil, audioTrackName: String? = nil,
        audioTrackId: String? = nil, contentLength: Int = -1, audioTrackType: String? = nil,
        audioTrackLocale: String? = nil, itag: Int? = nil, lastModified: Int? = nil,
        isDrc: Bool? = nil, xtags: String? = nil
    ) {
        self.url = url
        self.format = format
        self.quality = quality
        self.mimeType = mimeType
        self.codec = codec
        self.videoOnly = videoOnly
        self.bitrate = bitrate
        self.initStart = initStart
        self.initEnd = initEnd
        self.indexStart = indexStart
        self.indexEnd = indexEnd
        self.width = width
        self.height = height
        self.fps = fps
        self.durationMs = durationMs
        self.audioTrackName = audioTrackName
        self.audioTrackId = audioTrackId
        self.contentLength = contentLength
        self.audioTrackType = audioTrackType
        self.audioTrackLocale = audioTrackLocale
        self.itag = itag
        self.lastModified = lastModified
        self.isDrc = isDrc
        self.xtags = xtags
    }

    enum CodingKeys: String, CodingKey {
        case url, format, quality, mimeType, codec, videoOnly, bitrate, initStart, initEnd,
             indexStart, indexEnd, width, height, fps, durationMs, audioTrackName, audioTrackId,
             contentLength, audioTrackType, audioTrackLocale, itag, lastModified, isDrc, xtags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url)
        format = c.string(.format)
        quality = c.string(.quality)
        mimeType = c.string(.mimeType)
        codec = c.string(.codec)
        videoOnly = c.bool(.videoOnly)
        bitrate = c.int(.bitrate)
        initStart = c.int(.initStart)
        initEnd = c.int(.initEnd)
        indexStart = c.int(.indexStart)
        indexEnd = c.int(.indexEnd)
        width = c.int(.width)
        height = c.int(.height)
        fps = c.int(.fps)
        durationMs = c.int(.durationMs)
        audioTrackName = c.string(.audioTrackName)
        audioTrackId = c.string(.audioTrackId)
        contentLength = c.int(.contentLength, default: -1)
        audioTrackType = c.string(.audioTrackType)
        audioTrackLocale = c.string(.audioTrackLocale)
        itag = c.int(.itag)
        lastModified = c.int(.lastModified)
        isDrc = c.bool(.isDrc)
        xtags = c.string(.xtags)
    }
}

/// Mirrors `api/obj/Subtitle.kt`.
public struct Subtitle: Codable, Hashable, Identifiable, Sendable {
    public var url: String?
    public var mimeType: String?
    public var name: String?
    public var code: String?
    public var autoGenerated: Bool?

    public var id: String { url ?? "\(code ?? "")|\(name ?? "")|\(autoGenerated ?? false)" }

    public init(url: String? = nil, mimeType: String? = nil, name: String? = nil, code: String? = nil, autoGenerated: Bool? = nil) {
        self.url = url
        self.mimeType = mimeType
        self.name = name
        self.code = code
        self.autoGenerated = autoGenerated
    }

    enum CodingKeys: String, CodingKey { case url, mimeType, name, code, autoGenerated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url)
        mimeType = c.string(.mimeType)
        name = c.string(.name)
        code = c.string(.code)
        autoGenerated = c.bool(.autoGenerated)
    }
}

/// Mirrors `api/obj/ChapterSegment.kt`.
public struct ChapterSegment: Codable, Hashable, Identifiable, Sendable {
    public static let highlightLength = 10

    public var title: String
    public var image: String
    /// Start offset in seconds.
    public var start: Int

    public var id: String { "\(start)|\(title)" }

    public init(title: String = "", image: String = "", start: Int = 0) {
        self.title = title
        self.image = image
        self.start = start
    }

    enum CodingKeys: String, CodingKey { case title, image, start }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title, default: "")
        image = c.string(.image, default: "")
        start = c.int(.start, default: 0)
    }
}

/// Mirrors `api/obj/MetaInfo.kt`.
public struct MetaInfo: Codable, Hashable, Identifiable, Sendable {
    public var title: String
    public var description: String
    public var urls: [String]
    public var urlTexts: [String]

    public var id: String { title + "|" + description }

    public init(title: String = "", description: String = "", urls: [String] = [], urlTexts: [String] = []) {
        self.title = title
        self.description = description
        self.urls = urls
        self.urlTexts = urlTexts
    }

    enum CodingKeys: String, CodingKey { case title, description, urls, urlTexts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title, default: "")
        description = c.string(.description, default: "")
        urls = c.array(.urls)
        urlTexts = c.array(.urlTexts)
    }
}

/// Mirrors `api/obj/PreviewFrames.kt`.
public struct PreviewFrames: Codable, Hashable, Identifiable, Sendable {
    public var urls: [String]
    public var frameWidth: Int
    public var frameHeight: Int
    public var totalCount: Int
    public var durationPerFrame: Int
    public var framesPerPageX: Int
    public var framesPerPageY: Int

    public var id: String { "\(frameWidth)x\(frameHeight)|\(urls.first ?? "")" }

    public init(urls: [String] = [], frameWidth: Int = 0, frameHeight: Int = 0, totalCount: Int = 0,
                durationPerFrame: Int = 0, framesPerPageX: Int = 0, framesPerPageY: Int = 0) {
        self.urls = urls
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.totalCount = totalCount
        self.durationPerFrame = durationPerFrame
        self.framesPerPageX = framesPerPageX
        self.framesPerPageY = framesPerPageY
    }

    enum CodingKeys: String, CodingKey {
        case urls, frameWidth, frameHeight, totalCount, durationPerFrame, framesPerPageX, framesPerPageY
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urls = c.array(.urls)
        frameWidth = c.int(.frameWidth, default: 0)
        frameHeight = c.int(.frameHeight, default: 0)
        totalCount = c.int(.totalCount, default: 0)
        durationPerFrame = c.int(.durationPerFrame, default: 0)
        framesPerPageX = c.int(.framesPerPageX, default: 0)
        framesPerPageY = c.int(.framesPerPageY, default: 0)
    }
}
