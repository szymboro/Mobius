import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where video streams are resolved from.
public enum StreamSource: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Ask YouTube directly from this device (like LibreTube's NewPipeExtractor mode on Android).
    /// Stream URLs are bound to the device's own IP, which avoids datacenter bot blocks.
    case onDevice
    /// Ask the configured Piped instance (`/streams/{id}`).
    case piped

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice: "On device"
        case .piped: "Piped server"
        }
    }
}

public enum ExtractorError: Error, Sendable, LocalizedError {
    case unplayable(status: String, reason: String?)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unplayable(let status, let reason):
            "YouTube refused playback (\(status))\(reason.map { ": \($0)" } ?? "")"
        case .malformedResponse:
            "Unexpected response from YouTube"
        }
    }
}

/// Minimal on-device YouTube stream extractor using the InnerTube `player` endpoint
/// with the iOS app client, which returns unciphered URLs and (usually) an HLS manifest.
///
/// Client constants mirror NewPipeExtractor's `ClientsConstants.java`
/// (libre-tube/NewPipeExtractor) — update them from there when YouTube starts rejecting requests.
public enum YouTubeExtractor {
    struct Client: Sendable {
        let id: String
        let name: String
        let version: String
        let userAgent: String
        let extra: [String: String]
        var androidSdkVersion: Int?
    }

    /// Returns HLS for regular videos, but not for livestreams.
    static let ios = Client(
        id: "5", name: "IOS", version: "21.03.2",
        userAgent: "com.google.ios.youtube/21.03.2 (iPhone16,2; U; CPU iOS 18_7_2 like Mac OS X;)",
        extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iOS", "osVersion": "18.7.2.22H124"]
    )

    /// Returns HLS for livestreams (the iOS client only offers segmented/SABR formats for those).
    static let android = Client(
        id: "3", name: "ANDROID", version: "21.03.36",
        userAgent: "com.google.android.youtube/21.03.36 (Linux; U; Android 15) gzip",
        extra: ["osName": "Android", "osVersion": "15"],
        androidSdkVersion: 35
    )

    /// visionOS app client: what LibreTube Android (via NewPipeExtractor) uses for SABR playback.
    static let visionOS = Client(
        id: "101", name: "VISIONOS", version: "1.02",
        userAgent: "com.google.visionos.youtube/1.02 (RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; en_US)",
        extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice14,1", "osName": "visionOS", "osVersion": "25.6.0.23O471"]
    )

    static let playerURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false")!

    public static func streams(videoId: String, session: URLSession = .shared) async throws -> Streams {
        var streams = try parse(try await player(videoId: videoId, client: ios, session: session), videoId: videoId)
        if streams.hls == nil,
           let json = try? await player(videoId: videoId, client: android, session: session),
           let hls = (json["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String {
            streams.hls = hls
        }
        return streams
    }

    static func player(videoId: String, client: Client, session: URLSession) async throws -> [String: Any] {
        let locale = Locale.current
        var clientInfo: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": locale.language.languageCode?.identifier ?? "en",
            "gl": locale.region?.identifier ?? "US",
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        for (key, value) in client.extra { clientInfo[key] = value }
        if let sdk = client.androidSdkVersion { clientInfo["androidSdkVersion"] = sdk }
        let body: [String: Any] = [
            "context": ["client": clientInfo],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        var request = URLRequest(url: playerURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.id, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PipedError.http(http.statusCode, String(data: data, encoding: .utf8).map { String($0.prefix(200)) })
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.malformedResponse
        }
        return json
    }

    static func parse(_ json: [String: Any], videoId: String) throws -> Streams {
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "UNKNOWN"
        guard status == "OK" else {
            throw ExtractorError.unplayable(status: status, reason: playability?["reason"] as? String)
        }

        let details = json["videoDetails"] as? [String: Any] ?? [:]
        let streaming = json["streamingData"] as? [String: Any] ?? [:]

        let thumbnails = (details["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let thumbnail = thumbnails.max { int($0["width"]) < int($1["width"]) }?["url"] as? String
            ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"

        var videoStreams: [PipedStream] = []
        var audioStreams: [PipedStream] = []
        // `formats` are muxed (audio + video), `adaptiveFormats` are single-track.
        for (formats, muxed) in [(streaming["formats"], true), (streaming["adaptiveFormats"], false)] {
            for format in formats as? [[String: Any]] ?? [] {
                guard let url = format["url"] as? String else { continue } // ciphered: unsupported
                let mime = format["mimeType"] as? String ?? ""
                let baseMime = String(mime.prefix { $0 != ";" })
                let codec = mime.range(of: "codecs=\"").map { range in
                    String(mime[range.upperBound...].prefix { $0 != "\"" })
                }
                let isAudio = baseMime.hasPrefix("audio/")
                let stream = PipedStream(
                    url: url,
                    format: containerName(baseMime),
                    quality: isAudio ? "\(int(format["bitrate"]) / 1000) kbps" : format["qualityLabel"] as? String,
                    mimeType: baseMime,
                    codec: codec,
                    videoOnly: isAudio ? nil : !muxed,
                    bitrate: int(format["bitrate"]),
                    initStart: range(format["initRange"])?.start,
                    initEnd: range(format["initRange"])?.end,
                    indexStart: range(format["indexRange"])?.start,
                    indexEnd: range(format["indexRange"])?.end,
                    width: format["width"] as? Int,
                    height: format["height"] as? Int,
                    fps: format["fps"] as? Int,
                    durationMs: Int(format["approxDurationMs"] as? String ?? ""),
                    audioTrackName: (format["audioTrack"] as? [String: Any])?["displayName"] as? String,
                    audioTrackId: (format["audioTrack"] as? [String: Any])?["id"] as? String,
                    contentLength: Int(format["contentLength"] as? String ?? "") ?? -1,
                    audioTrackType: audioTrackType(format["audioTrack"]),
                    itag: format["itag"] as? Int
                )
                if isAudio { audioStreams.append(stream) } else { videoStreams.append(stream) }
            }
        }

        let channelId = details["channelId"] as? String
        let isLive = details["isLiveContent"] as? Bool ?? false
        return Streams(
            title: details["title"] as? String ?? "",
            description: details["shortDescription"] as? String ?? "",
            uploader: details["author"] as? String ?? "",
            uploaderUrl: channelId.map { "/channel/\($0)" },
            thumbnailUrl: thumbnail,
            hls: streaming["hlsManifestUrl"] as? String,
            duration: Int(details["lengthSeconds"] as? String ?? "") ?? 0,
            views: Int(details["viewCount"] as? String ?? "") ?? 0,
            audioStreams: audioStreams,
            videoStreams: videoStreams,
            livestream: isLive && (details["isLive"] as? Bool ?? false)
        )
    }

    private static func range(_ value: Any?) -> (start: Int, end: Int)? {
        guard let dict = value as? [String: Any] else { return nil }
        let start = int(dict["start"]), end = int(dict["end"])
        return end > start ? (start, end) : nil
    }

    /// nil for single-track videos; "ORIGINAL" / "DUBBED" when YouTube offers several audio languages.
    private static func audioTrackType(_ value: Any?) -> String? {
        guard let track = value as? [String: Any] else { return nil }
        return (track["audioIsDefault"] as? Bool ?? false) ? "ORIGINAL" : "DUBBED"
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func containerName(_ mime: String) -> String {
        switch mime {
        case "video/mp4": "MPEG_4"
        case "audio/mp4": "M4A"
        case "video/webm", "audio/webm": "WEBM"
        default: mime
        }
    }
}

// MARK: - SABR

/// InnerTube clients `sabrManifest` can use, tried in `YouTubeExtractor.sabrPlayerClients` order.
public enum SabrPlayerClient: String, Sendable, CaseIterable {
    /// visionOS app client, as LibreTube Android (NewPipeExtractor `getVisionOsPlayerResponse`) uses for SABR.
    /// Streams without attestation; the streaming PO token is sent when available.
    case visionOS = "VISIONOS"
    /// Desktop web client: player request with a video-bound PO token + signatureTimestamp, `n` deciphered
    /// with the player JS, SABR requests carrying the visitorData-bound PO token (NewPipe/yt-dlp style).
    case web = "WEB"
}

/// Normal videos are only fully streamable over SABR. This mirrors NewPipeExtractor's player requests
/// (`YoutubeStreamHelper`) plus the SABR fields LibreTube Android reads (`serverAbrStreamingUrl`,
/// `videoPlaybackUstreamerConfig`).
extension YouTubeExtractor {
    private static let sabrProvider = LockedValue<(any PoTokenProvider)?>(nil)
    private static let sabrRunner = LockedValue<(any PlayerScriptRunner)?>(nil)
    private static let sabrClientOrder = LockedValue<[SabrPlayerClient]>([.visionOS, .web])
    private static let webSessionCache = LockedValue<(visitorData: String, clientVersion: String, fetched: Date)?>(nil)

    /// Set by the app at launch.
    public static var poTokenProvider: (any PoTokenProvider)? {
        get { sabrProvider.value }
        set { sabrProvider.value = newValue }
    }

    public static var playerScriptRunner: (any PlayerScriptRunner)? {
        get { sabrRunner.value }
        set { sabrRunner.value = newValue }
    }

    /// Clients `sabrManifest` tries, in order; the first one that returns a SABR stream wins.
    public static var sabrPlayerClients: [SabrPlayerClient] {
        get { sabrClientOrder.value }
        set { sabrClientOrder.value = newValue }
    }

    /// Used when the current version can't be scraped from `sw.js_data`.
    static let webFallbackVersion = "2.20261113.00.00"
    static let webPlayerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    /// Player request → SabrManifest, trying `sabrPlayerClients` in order.
    /// Throws if no provider/runner is set or YouTube refuses.
    public static func sabrManifest(videoId: String, session: URLSession = .shared) async throws -> SabrManifest {
        guard let provider = poTokenProvider else { throw SabrStreamError.missingPoTokenProvider }
        guard let runner = playerScriptRunner else { throw SabrStreamError.missingPlayerScriptRunner }
        let web = try await webSession(session: session)

        var lastError: (any Error)?
        for client in sabrPlayerClients {
            PlaybackLog.shared.add("trying SABR client \(client)", "extractor")
            do {
                switch client {
                case .visionOS:
                    // The token only matters if YouTube starts asking for attestation: don't fail, or wait long, without it.
                    let started = Date()
                    let streamToken = await poTokenWithTimeout(provider, identifier: web.visitorData, seconds: 8) ?? ""
                    PlaybackLog.shared.add(
                        streamToken.isEmpty ? "no PO token after \(String(format: "%.1f", Date().timeIntervalSince(started)))s, continuing without"
                            : "PO token ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s", "extractor")
                    let json = try await visionOSPlayer(videoId: videoId, visitorData: web.visitorData, session: session)
                    return try makeSabrManifest(
                        json: json, videoId: videoId, serverURL: nil, poToken: streamToken,
                        visitorData: web.visitorData, clientName: visionOS.name, clientVersion: visionOS.version)
                case .web:
                    return try await webSabrManifest(
                        videoId: videoId, web: web, provider: provider, runner: runner, session: session)
                }
            } catch {
                PlaybackLog.shared.add("SABR client \(client) failed: \(error.localizedDescription)", "extractor")
                lastError = error
            }
        }
        throw lastError ?? SabrStreamError.noSabrStream("no SABR client configured")
    }

    /// Returns nil when the provider fails or takes longer than `seconds`.
    static func poTokenWithTimeout(_ provider: any PoTokenProvider, identifier: String, seconds: Double) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do { return try await provider.poToken(for: identifier) } catch {
                    PlaybackLog.shared.add("PO token error: \(error.localizedDescription)", "extractor")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func webSabrManifest(
        videoId: String, web: (visitorData: String, clientVersion: String), provider: any PoTokenProvider,
        runner: any PlayerScriptRunner, session: URLSession
    ) async throws -> SabrManifest {
        async let player = YouTubePlayerScript.current(session: session)
        // Player request token is bound to the video, the streaming token to the session (visitorData),
        // matching NewPipe's `PoTokenResult(playerRequestPoToken, streamingDataPoToken)`.
        async let playerToken = provider.poToken(for: videoId)
        async let streamingToken = provider.poToken(for: web.visitorData)
        let script = try await player
        let (requestToken, streamToken) = try await (playerToken, streamingToken)

        var lastError: (any Error)?
        for _ in 0..<3 {
            let json = try await webPlayer(
                videoId: videoId, visitorData: web.visitorData, clientVersion: web.clientVersion,
                signatureTimestamp: script.signatureTimestamp, poToken: requestToken, session: session
            )
            do {
                let raw = try makeSabrManifest(
                    json: json, videoId: videoId, serverURL: nil, poToken: streamToken,
                    visitorData: web.visitorData, clientName: "WEB", clientVersion: web.clientVersion)
                let serverURL = try await decipherN(
                    in: raw.serverURL.absoluteString, runner: runner, playerId: script.playerId,
                    playerScript: script.script)
                return SabrManifest(
                    videoId: raw.videoId, serverURL: serverURL, ustreamerConfig: raw.ustreamerConfig,
                    poToken: raw.poToken, visitorData: raw.visitorData, clientVersion: raw.clientVersion,
                    formats: raw.formats, durationMs: raw.durationMs, clientName: raw.clientName)
            } catch let error as SabrStreamError {
                // WEB sometimes answers without SABR data; retry like NewPipe does.
                lastError = error
            }
        }
        throw lastError ?? SabrStreamError.noSabrStream("missing serverAbrStreamingUrl")
    }

    static func visionOSPlayer(videoId: String, visitorData: String, session: URLSession) async throws -> [String: Any] {
        var clientInfo: [String: Any] = [
            "clientName": visionOS.name, "clientVersion": visionOS.version, "hl": "en",
            "gl": Locale.current.region?.identifier ?? "US", "visitorData": visitorData,
        ]
        for (key, value) in visionOS.extra { clientInfo[key] = value }
        let body: [String: Any] = [
            "context": ["client": clientInfo], "videoId": videoId, "cpn": randomCPN(),
            "contentCheckOk": true, "racyCheckOk": true,
        ]
        var request = URLRequest(url: URL(string: "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&id=\(videoId)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(visionOS.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(visionOS.id, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(visionOS.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PipedError.http(http.statusCode, String(data: data, encoding: .utf8).map { String($0.prefix(200)) })
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.malformedResponse
        }
        return json
    }

    /// Builds a manifest from a player response. `serverURL` overrides the response's URL (e.g. after deciphering `n`).
    static func makeSabrManifest(
        json: [String: Any], videoId: String, serverURL: URL?, poToken: String, visitorData: String,
        clientName: String, clientVersion: String
    ) throws -> SabrManifest {
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "UNKNOWN"
        guard status == "OK" else {
            throw ExtractorError.unplayable(status: status, reason: playability?["reason"] as? String)
        }
        let streaming = json["streamingData"] as? [String: Any] ?? [:]
        let mediaConfig = ((json["playerConfig"] as? [String: Any])?["mediaCommonConfig"] as? [String: Any])?[
            "mediaUstreamerRequestConfig"] as? [String: Any]
        guard let serverString = streaming["serverAbrStreamingUrl"] as? String,
              let url = serverURL ?? URL(string: serverString),
              let configString = mediaConfig?["videoPlaybackUstreamerConfig"] as? String,
              let config = Data(base64URLEncoded: configString) else {
            throw SabrStreamError.noSabrStream("missing serverAbrStreamingUrl or videoPlaybackUstreamerConfig")
        }
        let formats = sabrFormats(streaming["adaptiveFormats"] as? [[String: Any]] ?? [])
        guard !formats.isEmpty else { throw SabrStreamError.noSabrStream("no adaptive formats") }
        let lengthMs = (Int((json["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String ?? "") ?? 0) * 1000
        return SabrManifest(
            videoId: videoId, serverURL: url, ustreamerConfig: config, poToken: poToken,
            visitorData: visitorData, clientVersion: clientVersion, formats: formats,
            durationMs: formats.map(\.approxDurationMs).max().flatMap { $0 > 0 ? $0 : nil } ?? lengthMs,
            clientName: clientName
        )
    }

    /// Current WEB client version (scraped from `sw.js_data`) and a fresh visitorData from InnerTube.
    /// Cached for an hour. The visitorData embedded in `sw.js_data` carries extra payload and doesn't work
    /// as a PO token binding, so it comes from `/visitor_id` (the same value a player response reports).
    static func webSession(session: URLSession) async throws -> (visitorData: String, clientVersion: String) {
        if let cached = webSessionCache.value, Date().timeIntervalSince(cached.fetched) < 3600 {
            return (cached.visitorData, cached.clientVersion)
        }
        var clientVersion: String?
        var request = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        request.setValue(YouTubePlayerScript.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: request),
           var text = String(data: data, encoding: .utf8) {
            if text.hasPrefix(")]}'") { text.removeFirst(4) }
            if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                var strings: [String] = []
                collectStrings(json, into: &strings)
                clientVersion = strings.first { $0.range(of: #"^2\.\d{8}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil }
            }
        }
        let version = clientVersion ?? webFallbackVersion
        guard let visitorData = try await innertubeVisitorData(clientVersion: version, session: session) else {
            throw ExtractorError.malformedResponse
        }
        webSessionCache.value = (visitorData, version, Date())
        return (visitorData, version)
    }

    private static func collectStrings(_ value: Any, into strings: inout [String]) {
        if let s = value as? String { strings.append(s) }
        else if let array = value as? [Any] { for v in array { collectStrings(v, into: &strings) } }
        else if let dict = value as? [String: Any] { for v in dict.values { collectStrings(v, into: &strings) } }
    }

    private static func innertubeVisitorData(clientVersion: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en", "gl": "US"]],
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubePlayerScript.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["responseContext"] as? [String: Any])?["visitorData"] as? String
    }

    static func webPlayer(
        videoId: String, visitorData: String, clientVersion: String, signatureTimestamp: Int, poToken: String,
        session: URLSession
    ) async throws -> [String: Any] {
        let watchURL = "https://www.youtube.com/watch?v=\(videoId)"
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "hl": "en",
                    "gl": Locale.current.region?.identifier ?? "US",
                    "visitorData": visitorData,
                    "platform": "DESKTOP",
                    "originalUrl": watchURL,
                    "userAgent": YouTubePlayerScript.browserUserAgent,
                    "utcOffsetMinutes": 0,
                ],
                "request": ["useSsl": true, "internalExperimentFlags": [] as [Any]],
                "user": ["lockedSafetyMode": false],
            ],
            "videoId": videoId,
            "cpn": randomCPN(),
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": [
                    "signatureTimestamp": signatureTimestamp,
                    "referer": watchURL,
                    "html5Preference": "HTML5_PREF_WANTS",
                ],
            ],
            "serviceIntegrityDimensions": ["poToken": poToken],
        ]
        var request = URLRequest(url: webPlayerURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubePlayerScript.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(watchURL, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PipedError.http(http.statusCode, String(data: data, encoding: .utf8).map { String($0.prefix(200)) })
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.malformedResponse
        }
        return json
    }

    private static func randomCPN() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    /// Replaces the throttling parameter `n` in `urlString` with the player's transformed value.
    static func decipherN(
        in urlString: String, runner: any PlayerScriptRunner, playerId: String, playerScript: String
    ) async throws -> URL {
        guard var components = URLComponents(string: urlString) else { throw ExtractorError.malformedResponse }
        var items = components.percentEncodedQueryItems ?? []
        if let index = items.firstIndex(where: { $0.name == "n" }), let n = items[index].value?.removingPercentEncoding {
            let result = try await runner.decipher(n: n, signature: nil, playerId: playerId, playerScript: playerScript)
            guard let newN = result.n, newN != n else {
                throw SabrStreamError.playerScript("n transform failed")
            }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+")
            items[index].value = newN.addingPercentEncoding(withAllowedCharacters: allowed)
            components.percentEncodedQueryItems = items
        }
        guard let url = components.url else { throw ExtractorError.malformedResponse }
        return url
    }

    static func sabrFormats(_ adaptive: [[String: Any]]) -> [SabrFormat] {
        adaptive.compactMap { format in
            guard let itag = format["itag"] as? Int, let lastModified = format["lastModified"] as? String,
                  format["drmFamilies"] == nil else { return nil }
            let mime = format["mimeType"] as? String ?? ""
            let baseMime = String(mime.prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces)
            let codecs = mime.range(of: "codecs=\"").map { String(mime[$0.upperBound...].prefix { $0 != "\"" }) } ?? ""
            let track = format["audioTrack"] as? [String: Any]
            return SabrFormat(
                itag: itag,
                lastModified: lastModified,
                xtags: format["xtags"] as? String,
                mimeType: baseMime,
                codecs: codecs,
                bitrate: int(format["bitrate"]),
                width: format["width"] as? Int,
                height: format["height"] as? Int,
                fps: format["fps"] as? Int,
                isAudio: baseMime.hasPrefix("audio/"),
                audioTrackId: track?["id"] as? String,
                isDefaultAudio: track.map { $0["audioIsDefault"] as? Bool ?? false } ?? true,
                approxDurationMs: int(format["approxDurationMs"])
            )
        }
    }
}
