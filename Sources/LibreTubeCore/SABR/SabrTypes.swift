import Foundation

/// Injected by the app (WKWebView BotGuard). Core never imports WebKit.
public protocol PoTokenProvider: Sendable {
    /// BotGuard PO token minted for `identifier` (a videoId or visitorData), base64url-encoded.
    func poToken(for identifier: String) async throws -> String
}

/// Injected by the app (JavaScriptCore). Runs YouTube's player JS.
public protocol PlayerScriptRunner: Sendable {
    /// Returns the transformed `n` and/or signature, using the player's URL builder.
    /// `playerScript` is the full base.js text; implementations cache the compiled context per player id.
    func decipher(n: String?, signature: String?, playerId: String, playerScript: String) async throws -> (n: String?, signature: String?)
}

public struct SabrFormat: Sendable, Hashable, Codable {
    public let itag: Int
    public let lastModified: String     // "lastModified" from adaptiveFormats (string of digits)
    public let xtags: String?
    public let mimeType: String         // e.g. "video/mp4"
    public let codecs: String           // e.g. "avc1.640028"
    public let bitrate: Int
    public let width: Int?, height: Int?, fps: Int?
    public let isAudio: Bool
    public let audioTrackId: String?, isDefaultAudio: Bool
    public let approxDurationMs: Int

    public init(
        itag: Int, lastModified: String, xtags: String?, mimeType: String, codecs: String, bitrate: Int,
        width: Int?, height: Int?, fps: Int?, isAudio: Bool, audioTrackId: String?, isDefaultAudio: Bool,
        approxDurationMs: Int
    ) {
        self.itag = itag
        self.lastModified = lastModified
        self.xtags = xtags
        self.mimeType = mimeType
        self.codecs = codecs
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.fps = fps
        self.isAudio = isAudio
        self.audioTrackId = audioTrackId
        self.isDefaultAudio = isDefaultAudio
        self.approxDurationMs = approxDurationMs
    }
}

public struct SabrManifest: Sendable {
    public let videoId: String
    public let serverURL: URL                  // n already deciphered
    public let ustreamerConfig: Data           // base64url-decoded videoPlaybackUstreamerConfig
    public let poToken: String
    public let visitorData: String
    public let clientVersion: String           // WEB client version used for the player request
    public let formats: [SabrFormat]
    public let durationMs: Int
    /// InnerTube client the player request was made with ("WEB" or "VISIONOS"); SABR requests must
    /// identify as the same client. Additive to the contract.
    public let clientName: String

    public init(
        videoId: String, serverURL: URL, ustreamerConfig: Data, poToken: String, visitorData: String,
        clientVersion: String, formats: [SabrFormat], durationMs: Int, clientName: String = "WEB"
    ) {
        self.clientName = clientName
        self.videoId = videoId
        self.serverURL = serverURL
        self.ustreamerConfig = ustreamerConfig
        self.poToken = poToken
        self.visitorData = visitorData
        self.clientVersion = clientVersion
        self.formats = formats
        self.durationMs = durationMs
    }
}

/// Exact segment layout of one format, needed up front to write HLS playlists.
public struct SabrSegmentIndex: Sendable {
    public let format: SabrFormat
    public let initSegment: Data               // ftyp+moov (fMP4 init)
    public let segmentDurations: [Double]      // seconds; segment numbers are 1...count

    public init(format: SabrFormat, initSegment: Data, segmentDurations: [Double]) {
        self.format = format
        self.initSegment = initSegment
        self.segmentDurations = segmentDurations
    }
}

public enum SabrStreamError: Error, Sendable, LocalizedError {
    case missingPoTokenProvider
    case missingPlayerScriptRunner
    case noSabrStream(String)
    case playerScript(String)
    case http(Int)
    case protocolError(String)
    case server(type: String, code: Int)
    case reloadRequired
    case attestationRequired
    case unsupportedFormat(Int)
    case segmentUnavailable(itag: Int, segment: Int)

    public var errorDescription: String? {
        switch self {
        case .missingPoTokenProvider: "No PO token provider configured"
        case .missingPlayerScriptRunner: "No player script runner configured"
        case .noSabrStream(let reason): "YouTube returned no SABR stream: \(reason)"
        case .playerScript(let reason): "Could not load YouTube's player script: \(reason)"
        case .http(let code): "SABR request failed (HTTP \(code))"
        case .protocolError(let reason): "Malformed SABR response: \(reason)"
        case .server(let type, let code): "SABR server error \(type) (\(code))"
        case .reloadRequired: "The stream expired, reload the video"
        case .attestationRequired: "YouTube rejected the PO token (attestation required)"
        case .unsupportedFormat(let itag): "Format \(itag) can't be streamed over SABR"
        case .segmentUnavailable(let itag, let segment): "Segment \(segment) of format \(itag) is unavailable"
        }
    }
}

extension Data {
    /// Decodes base64url or standard base64, with or without padding.
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.replacingOccurrences(of: "%3D", with: "=").replacingOccurrences(of: "=", with: "")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
