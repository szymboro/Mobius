import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Combine)
import Combine
#endif

/// Crowd-sourced titles and thumbnails from DeArrow (https://dearrow.ajay.app), replacing
/// clickbait. Lookups use the first 4 hex characters of the video id's SHA-256, so the server
/// only learns a bucket of videos, not which one is being viewed.
@MainActor
public final class DeArrow: ObservableObject {
    public static let shared = DeArrow()

    public struct Branding: Sendable, Equatable {
        public var title: String?
        /// Second into the video to take the thumbnail from.
        public var thumbnailTime: Double?
    }

    /// Videos that have a replacement title or thumbnail.
    @Published public private(set) var brandings: [String: Branding] = [:]
    private var checked: [String: Date] = [:]
    private static let recheckAfter: TimeInterval = 60 * 60

    /// Replacement title, when DeArrow titles are on and one exists.
    public func title(for videoId: String) -> String? {
        guard Settings.shared.deArrowTitles else { return nil }
        return brandings[videoId]?.title
    }

    /// Replacement thumbnail, when DeArrow thumbnails are on and one exists.
    public func thumbnailURL(for videoId: String) -> URL? {
        guard Settings.shared.deArrowThumbnails, let time = brandings[videoId]?.thumbnailTime else { return nil }
        var components = URLComponents(string: "https://dearrow-thumb.ajay.app/api/v1/getThumbnail")!
        components.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "time", value: String(time)),
        ]
        return components.url
    }

    /// Fetches the branding for a video once (per hour) when DeArrow is on.
    public func load(videoId: String) async {
        let settings = Settings.shared
        guard settings.deArrowTitles || settings.deArrowThumbnails, !videoId.isEmpty else { return }
        if let last = checked[videoId], Date().timeIntervalSince(last) < Self.recheckAfter { return }
        checked[videoId] = Date()
        guard let branding = try? await Self.fetch(videoId: videoId) else {
            checked[videoId] = nil // retry next time it's shown
            return
        }
        if branding.title != nil || branding.thumbnailTime != nil, brandings[videoId] != branding {
            brandings[videoId] = branding
        }
    }

    // MARK: API

    private struct Response: Decodable {
        struct Title: Decodable { var title: String; var original: Bool; var votes: Int; var locked: Bool }
        struct Thumbnail: Decodable { var timestamp: Double?; var original: Bool; var votes: Int; var locked: Bool }
        var titles: [Title]
        var thumbnails: [Thumbnail]
    }

    private nonisolated static func fetch(videoId: String) async throws -> Branding {
        let url: URL
        if let prefix = hashPrefix(videoId) {
            url = URL(string: "https://sponsor.ajay.app/api/branding/\(prefix)")!
        } else {
            var components = URLComponents(string: "https://sponsor.ajay.app/api/branding")!
            components.queryItems = [URLQueryItem(name: "videoID", value: videoId)]
            url = components.url!
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return Branding() } // nothing submitted
        guard status == 200 else { throw URLError(.badServerResponse) }

        let entry: Response?
        if hashPrefix(videoId) != nil {
            entry = try JSONDecoder().decode([String: Response].self, from: data)[videoId]
        } else {
            entry = try JSONDecoder().decode(Response.self, from: data)
        }
        guard let entry else { return Branding() }

        // Like the extension: the best-voted acceptable submission wins; "original" means
        // the community prefers what YouTube already shows.
        var branding = Branding()
        if let best = entry.titles.first(where: { $0.locked || $0.votes >= 0 }), !best.original {
            branding.title = clean(best.title)
        }
        if let best = entry.thumbnails.first(where: { $0.locked || $0.votes >= 0 }), !best.original {
            branding.thumbnailTime = best.timestamp
        }
        return branding
    }

    /// Submitters put ">" before a word to keep it from being auto-formatted; it isn't shown.
    private nonisolated static func clean(_ title: String) -> String? {
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.hasPrefix(">") && word.count > 1 ? word.dropFirst() : word
        }
        let result = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private nonisolated static func hashPrefix(_ videoId: String) -> String? {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(videoId.utf8))
        return digest.prefix(2).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}
