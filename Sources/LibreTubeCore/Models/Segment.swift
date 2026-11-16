import Foundation

/// A SponsorBlock segment. See https://wiki.sponsor.ajay.app/w/API_Docs#GET_/api/skipSegments
/// Mirrors `api/obj/Segment.kt`.
public struct Segment: Codable, Hashable, Identifiable, Sendable {
    public static let typeFull = "full"

    public var uuid: String
    public var actionType: String
    public var category: String
    public var description: String?
    public var locked: Int
    /// `[start, end]` in seconds.
    public var segment: [Double]
    public var userID: String?
    public var videoDuration: Double
    public var votes: Int

    public var id: String { uuid }
    public var start: Double { segment.first ?? 0 }
    public var end: Double { segment.count > 1 ? segment[1] : start }

    public init(
        uuid: String = UUID().uuidString, actionType: String = "skip", category: String,
        description: String? = nil, locked: Int = 0, segment: [Double], userID: String? = nil,
        videoDuration: Double = 0, votes: Int = 0
    ) {
        self.uuid = uuid
        self.actionType = actionType
        self.category = category
        self.description = description
        self.locked = locked
        self.segment = segment
        self.userID = userID
        self.videoDuration = videoDuration
        self.votes = votes
    }

    enum CodingKeys: String, CodingKey {
        case uuid = "UUID"
        case actionType, category, description, locked, segment, userID, videoDuration, votes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.string(.uuid) ?? UUID().uuidString
        actionType = c.string(.actionType, default: "skip")
        category = c.string(.category, default: "")
        description = c.string(.description)
        locked = c.int(.locked, default: 0)
        segment = c.array(.segment)
        userID = c.string(.userID)
        videoDuration = c.double(.videoDuration, default: 0)
        votes = c.int(.votes, default: 0)
    }
}
