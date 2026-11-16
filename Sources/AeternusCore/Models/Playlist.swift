import Foundation

/// Mirrors `api/obj/Playlist.kt`.
public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var name: String?
    public var description: String?
    public var thumbnailUrl: String?
    public var bannerUrl: String?
    public var nextpage: String?
    public var uploader: String?
    public var uploaderUrl: String?
    public var uploaderAvatar: String?
    public var videos: Int
    public var relatedStreams: [StreamItem]

    /// Piped does not return the playlist id; this is a best-effort identifier.
    public var id: String { "\(uploaderUrl ?? "")|\(name ?? "")|\(thumbnailUrl ?? "")" }

    public init(
        name: String? = nil, description: String? = nil, thumbnailUrl: String? = nil,
        bannerUrl: String? = nil, nextpage: String? = nil, uploader: String? = nil,
        uploaderUrl: String? = nil, uploaderAvatar: String? = nil, videos: Int = 0,
        relatedStreams: [StreamItem] = []
    ) {
        self.name = name
        self.description = description
        self.thumbnailUrl = thumbnailUrl
        self.bannerUrl = bannerUrl
        self.nextpage = nextpage
        self.uploader = uploader
        self.uploaderUrl = uploaderUrl
        self.uploaderAvatar = uploaderAvatar
        self.videos = videos
        self.relatedStreams = relatedStreams
    }

    enum CodingKeys: String, CodingKey {
        case name, description, thumbnailUrl, bannerUrl, nextpage, uploader, uploaderUrl, uploaderAvatar, videos, relatedStreams
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.string(.name)
        description = c.string(.description)
        thumbnailUrl = c.string(.thumbnailUrl)
        bannerUrl = c.string(.bannerUrl)
        nextpage = c.string(.nextpage)
        uploader = c.string(.uploader)
        uploaderUrl = c.string(.uploaderUrl)
        uploaderAvatar = c.string(.uploaderAvatar)
        videos = c.int(.videos, default: 0)
        relatedStreams = c.array(.relatedStreams)
    }
}
