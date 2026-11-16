import Foundation

/// Mirrors `api/obj/Comment.kt`.
public struct Comment: Codable, Hashable, Identifiable, Sendable {
    public var author: String
    public var commentId: String
    public var commentText: String?
    public var commentedTime: String
    public var commentorUrl: String
    /// Pass this as `nextpage` to `PipedAPI.commentsNextPage` to load replies.
    public var repliesPage: String?
    public var hearted: Bool
    public var likeCount: Int
    public var pinned: Bool
    public var thumbnail: String
    public var verified: Bool
    public var replyCount: Int
    public var creatorReplied: Bool
    public var channelOwner: Bool

    public var id: String { commentId }

    public init(
        author: String = "", commentId: String = "", commentText: String? = nil,
        commentedTime: String = "", commentorUrl: String = "", repliesPage: String? = nil,
        hearted: Bool = false, likeCount: Int = 0, pinned: Bool = false, thumbnail: String = "",
        verified: Bool = false, replyCount: Int = 0, creatorReplied: Bool = false, channelOwner: Bool = false
    ) {
        self.author = author
        self.commentId = commentId
        self.commentText = commentText
        self.commentedTime = commentedTime
        self.commentorUrl = commentorUrl
        self.repliesPage = repliesPage
        self.hearted = hearted
        self.likeCount = likeCount
        self.pinned = pinned
        self.thumbnail = thumbnail
        self.verified = verified
        self.replyCount = replyCount
        self.creatorReplied = creatorReplied
        self.channelOwner = channelOwner
    }

    enum CodingKeys: String, CodingKey {
        case author, commentId, commentText, commentedTime, commentorUrl, repliesPage, hearted,
             likeCount, pinned, thumbnail, verified, replyCount, creatorReplied, channelOwner
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = c.string(.author, default: "")
        commentId = c.string(.commentId) ?? UUID().uuidString
        commentText = c.string(.commentText)
        commentedTime = c.string(.commentedTime, default: "")
        commentorUrl = c.string(.commentorUrl, default: "")
        repliesPage = c.string(.repliesPage)
        hearted = c.bool(.hearted, default: false)
        likeCount = c.int(.likeCount, default: 0)
        pinned = c.bool(.pinned, default: false)
        thumbnail = c.string(.thumbnail, default: "")
        verified = c.bool(.verified, default: false)
        replyCount = c.int(.replyCount, default: 0)
        creatorReplied = c.bool(.creatorReplied, default: false)
        channelOwner = c.bool(.channelOwner, default: false)
    }
}

/// Mirrors `api/obj/CommentsPage.kt`.
public struct CommentsPage: Codable, Hashable, Identifiable, Sendable {
    public var comments: [Comment]
    public var disabled: Bool
    public var nextpage: String?
    public var commentCount: Int

    public var id: String { nextpage ?? "first" }

    public init(comments: [Comment] = [], disabled: Bool = false, nextpage: String? = nil, commentCount: Int = 0) {
        self.comments = comments
        self.disabled = disabled
        self.nextpage = nextpage
        self.commentCount = commentCount
    }

    enum CodingKeys: String, CodingKey { case comments, disabled, nextpage, commentCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = c.array(.comments)
        disabled = c.bool(.disabled, default: false)
        nextpage = c.string(.nextpage)
        commentCount = c.int(.commentCount, default: 0)
    }
}
