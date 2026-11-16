import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches YouTube's current web player (base.js): iframe_api → player id → base.js. Caches by player id.
public enum YouTubePlayerScript {
    struct Loaded: Sendable {
        let playerId: String
        let script: String
        let signatureTimestamp: Int
    }

    private static let cache = LockedValue<Loaded?>(nil)

    static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

    public static func current(session: URLSession) async throws -> (playerId: String, script: String, signatureTimestamp: Int) {
        let playerId = try await currentPlayerId(session: session)
        if let cached = cache.value, cached.playerId == playerId {
            return (cached.playerId, cached.script, cached.signatureTimestamp)
        }
        let url = URL(string: "https://www.youtube.com/s/player/\(playerId)/player_ias.vflset/en_US/base.js")!
        let script = try await fetchText(url, session: session)
        guard let sts = firstMatch(#"signatureTimestamp[:=](\d+)"#, in: script).flatMap(Int.init)
            ?? firstMatch(#"\bsts:(\d+)"#, in: script).flatMap(Int.init) else {
            throw SabrStreamError.playerScript("signatureTimestamp not found in player \(playerId)")
        }
        let loaded = Loaded(playerId: playerId, script: script, signatureTimestamp: sts)
        cache.value = loaded
        return (playerId, script, sts)
    }

    static func currentPlayerId(session: URLSession) async throws -> String {
        let api = try await fetchText(URL(string: "https://www.youtube.com/iframe_api")!, session: session)
        guard let id = firstMatch(#"player\\?/([0-9a-zA-Z_-]{8})\\?/"#, in: api) else {
            throw SabrStreamError.playerScript("player id not found in iframe_api")
        }
        return id
    }

    static func fetchText(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SabrStreamError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SabrStreamError.playerScript("not UTF-8") }
        return text
    }

    /// First capture group of `pattern` in `text`.
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Small lock-protected box for static mutable state under strict concurrency.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
