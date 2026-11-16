import Foundation

/// Mirrors `api/obj/Channel.kt`.
public struct Channel: Codable, Hashable, Identifiable, Sendable {
    public var id: String?
    public var name: String?
    public var avatarUrl: String?
    public var bannerUrl: String?
    public var description: String?
    public var nextpage: String?
    public var subscriberCount: Int
    public var verified: Bool
    public var relatedStreams: [StreamItem]
    public var tabs: [ChannelTab]

    /// Canonical "/channel/ID" url, convenient for building a `Subscription`.
    public var url: String { "/channel/\(id ?? "")" }

    public init(
        id: String? = nil, name: String? = nil, avatarUrl: String? = nil, bannerUrl: String? = nil,
        description: String? = nil, nextpage: String? = nil, subscriberCount: Int = 0,
        verified: Bool = false, relatedStreams: [StreamItem] = [], tabs: [ChannelTab] = []
    ) {
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
        self.bannerUrl = bannerUrl
        self.description = description
        self.nextpage = nextpage
        self.subscriberCount = subscriberCount
        self.verified = verified
        self.relatedStreams = relatedStreams
        self.tabs = tabs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, avatarUrl, bannerUrl, description, nextpage, subscriberCount, verified, relatedStreams, tabs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        avatarUrl = c.string(.avatarUrl)
        bannerUrl = c.string(.bannerUrl)
        description = c.string(.description)
        nextpage = c.string(.nextpage)
        subscriberCount = c.int(.subscriberCount, default: 0)
        verified = c.bool(.verified, default: false)
        relatedStreams = c.array(.relatedStreams)
        tabs = c.array(.tabs)
    }

    /// A local subscription for this channel.
    public func toSubscription() -> Subscription {
        Subscription(url: url, name: name, avatar: avatarUrl, verified: verified)
    }
}

/// Mirrors `api/obj/ChannelTab.kt`.
public struct ChannelTab: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var data: String

    public var id: String { name }

    public init(name: String = "", data: String = "") {
        self.name = name
        self.data = data
    }

    enum CodingKeys: String, CodingKey { case name, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.string(.name, default: "")
        data = c.string(.data, default: "")
    }
}
