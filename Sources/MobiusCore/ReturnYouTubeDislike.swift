import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dislike counts from the Return YouTube Dislike API (https://returnyoutubedislike.com), which
/// estimates them from archived data and from its extension's users since YouTube hid them.
public enum ReturnYouTubeDislike {
    public struct Votes: Decodable, Sendable {
        public var likes: Int
        public var dislikes: Int
        /// 1...5, like YouTube's old star rating.
        public var rating: Double
        public var viewCount: Int
    }

    public static func votes(videoId: String, session: URLSession = .shared) async throws -> Votes {
        var components = URLComponents(string: "https://returnyoutubedislikeapi.com/votes")!
        components.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Votes.self, from: data)
    }
}
