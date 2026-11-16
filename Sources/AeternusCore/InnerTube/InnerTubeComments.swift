import Foundation

/// Parses `next` continuation responses for comments and replies.
///
/// Current format: `commentThreadRenderer.commentViewModel.commentViewModel` (or a bare `commentViewModel`
/// for replies) only holds keys; the content lives in `frameworkUpdates.entityBatchUpdate.mutations`
/// as `commentEntityPayload` (keyed by entity key, with `properties.commentId`) and
/// `engagementToolbarStateEntityPayload` (heart state). The legacy `commentRenderer` is handled too.
enum InnerTubeCommentsParser {
    static func page(_ json: [String: Any]) -> CommentsPage {
        let root = JNode(json)
        let entities = Entities(root["frameworkUpdates", "entityBatchUpdate", "mutations"])

        var comments: [Comment] = []
        var nextpage: String?
        var commentCount = 0

        let commands = root["onResponseReceivedEndpoints"].array + root["onResponseReceivedActions"].array
        for command in commands {
            let action = [command["reloadContinuationItemsCommand"], command["appendContinuationItemsAction"]]
                .first { $0.exists } ?? .empty
            for item in action["continuationItems"].array {
                if item["commentsHeaderRenderer"].exists {
                    let header = item["commentsHeaderRenderer"]
                    commentCount = InnerTubeText.count(header["countText"].text ?? header["commentsCount"].text) ?? commentCount
                } else if item["commentThreadRenderer"].exists {
                    if let comment = thread(item["commentThreadRenderer"], entities: entities) { comments.append(comment) }
                } else if item["commentViewModel"].exists {
                    if let comment = viewModel(item["commentViewModel"], entities: entities) { comments.append(comment) }
                } else if item["commentRenderer"].exists {
                    if let comment = legacy(item["commentRenderer"]) { comments.append(comment) }
                } else if item["continuationItemRenderer"].exists {
                    nextpage = nextpage ?? InnerTubeItems.token(item["continuationItemRenderer"])
                }
            }
        }
        var seen = Set<String>()
        comments = comments.filter { seen.insert($0.commentId).inserted }
        return CommentsPage(comments: comments, disabled: false, nextpage: nextpage, commentCount: commentCount)
    }

    struct Entities {
        var byKey: [String: JNode] = [:]
        var byCommentId: [String: JNode] = [:]

        init(_ mutations: JNode) {
            for mutation in mutations.array {
                let payload = mutation["payload"]
                guard let type = payload.keys.first else { continue }
                let value = payload[type]
                if let key = mutation["entityKey"].string ?? value["key"].string { byKey[key] = value }
                if type == "commentEntityPayload", let id = value["properties", "commentId"].string {
                    byCommentId[id] = value
                }
            }
        }
    }

    static func thread(_ node: JNode, entities: Entities) -> Comment? {
        let repliesRenderer = node["replies", "commentRepliesRenderer"]
        let repliesToken = InnerTubeItems.token(repliesRenderer["contents"].first("continuationItemRenderer"))
        let creatorReplied = repliesRenderer["viewRepliesCreatorThumbnail"].exists
        var comment: Comment?
        if node["commentViewModel"].exists {
            let vm = node["commentViewModel"]["commentViewModel"].exists ? node["commentViewModel"]["commentViewModel"] : node["commentViewModel"]
            comment = viewModel(vm, entities: entities)
        } else if node["comment", "commentRenderer"].exists {
            comment = legacy(node["comment", "commentRenderer"])
        }
        guard var comment else { return nil }
        if let repliesToken { comment.repliesPage = repliesToken }
        if creatorReplied { comment.creatorReplied = true }
        if comment.replyCount == 0, let text = repliesRenderer["viewReplies"].first("text").text {
            comment.replyCount = InnerTubeText.count(text) ?? 0
        }
        return comment
    }

    static func viewModel(_ node: JNode, entities: Entities) -> Comment? {
        let vm = node["commentViewModel"].exists ? node["commentViewModel"] : node
        let commentId = vm["commentId"].string
        guard let entity = vm["commentKey"].string.flatMap({ entities.byKey[$0] })
            ?? commentId.flatMap({ entities.byCommentId[$0] }) else { return nil }
        let properties = entity["properties"]
        let author = entity["author"]
        let toolbar = entity["toolbar"]
        let toolbarState = (vm["toolbarStateKey"].string ?? properties["toolbarStateKey"].string)
            .flatMap { entities.byKey[$0] } ?? .empty

        let channelId = author["channelId"].string
        let likeText = toolbar["likeCountNotliked"].string ?? toolbar["likeCountLiked"].string
        return Comment(
            author: author["displayName"].string ?? properties["authorButtonA11y"].string ?? "",
            commentId: commentId ?? properties["commentId"].string ?? UUID().uuidString,
            commentText: InnerTubeText.html(properties["content"].text),
            commentedTime: properties["publishedTime"].string ?? "",
            commentorUrl: channelId.map { "/channel/\($0)" } ?? "",
            hearted: toolbarState["heartState"].string == "TOOLBAR_HEART_STATE_HEARTED",
            likeCount: InnerTubeText.count(likeText) ?? 0,
            pinned: vm["pinnedText"].exists,
            thumbnail: InnerTubeText.normalizeURL(author["avatarThumbnailUrl"].string)
                ?? InnerTubeText.bestImage(entity["avatar"].first("image")) ?? "",
            verified: author["isVerified"].bool == true || author["isArtist"].bool == true,
            replyCount: InnerTubeText.count(toolbar["replyCount"].string) ?? 0,
            creatorReplied: false,
            channelOwner: author["isCreator"].bool == true
        )
    }

    static func legacy(_ node: JNode) -> Comment? {
        guard let id = node["commentId"].string else { return nil }
        let channelId = node["authorEndpoint", "browseEndpoint", "browseId"].string
        return Comment(
            author: node["authorText"].text ?? "",
            commentId: id,
            commentText: InnerTubeText.html(node["contentText"].text),
            commentedTime: node["publishedTimeText"].text ?? "",
            commentorUrl: channelId.map { "/channel/\($0)" } ?? "",
            hearted: node["actionButtons"].first("creatorHeart")["creatorHeartRenderer"]["isHearted"].bool ?? false,
            likeCount: InnerTubeText.count(node["voteCount"].text) ?? 0,
            pinned: node["pinnedCommentBadge"].exists,
            thumbnail: InnerTubeText.bestImage(node["authorThumbnail"]) ?? "",
            verified: node["authorCommentBadge"].exists,
            replyCount: node["replyCount"].int ?? 0,
            channelOwner: node["authorIsChannelOwner"].bool ?? false
        )
    }
}
