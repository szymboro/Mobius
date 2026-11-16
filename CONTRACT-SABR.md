# SABR playback: module contract

Normal (non-live) YouTube videos are now only fully streamable over SABR, YouTube's
POST + UMP protocol, with a BotGuard PO token. This is what YouTube's own player and
LibreTube Android do; see `app/src/main/java/com/github/libretube/player/parser/` and
`app/src/main/proto/video_streaming/`. Livestreams keep using HLS from the ANDROID client.

Pipeline:
`WEB player request (visitorData, PO token, signatureTimestamp)` → `serverAbrStreamingUrl` + `videoPlaybackUstreamerConfig` + `adaptiveFormats`
→ decipher `n` in the SABR URL → `SabrSession` POSTs `VideoPlaybackAbrRequest`s → UMP media segments
→ app-side local HTTP server exposes them as fMP4 HLS → AVPlayer.

## Core (`Sources/LibreTubeCore/SABR/`, Foundation only, must build on Linux)

```swift
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

public enum YouTubePlayerScript {      // fetches iframe_api → player id → base.js; caches by player id
    public static func current(session: URLSession) async throws -> (playerId: String, script: String, signatureTimestamp: Int)
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
}

extension YouTubeExtractor {
    public static var poTokenProvider: (any PoTokenProvider)? { get set }   // set by the app at launch
    public static var playerScriptRunner: (any PlayerScriptRunner)? { get set }
    /// WEB-client player request → SabrManifest. Throws if no provider/runner is set or YouTube refuses.
    public static func sabrManifest(videoId: String, session: URLSession = .shared) async throws -> SabrManifest
}

/// Exact segment layout of one format, needed up front to write HLS playlists.
public struct SabrSegmentIndex: Sendable {
    public let format: SabrFormat
    public let initSegment: Data               // ftyp+moov (fMP4 init)
    public let segmentDurations: [Double]      // seconds; segment numbers are 1...count
}

public actor SabrSession {
    public init(manifest: SabrManifest, session: URLSession = .shared)
    /// Fetches the init segment and the full segment list (duration of every segment).
    public func index(for format: SabrFormat) async throws -> SabrSegmentIndex
    /// Media segment `number` (1-based, matching segmentDurations) as a complete fMP4 fragment (moof+mdat).
    /// May fetch neighbours in the same request and cache them. Must be safe for concurrent calls.
    public func segment(_ number: Int, of format: SabrFormat) async throws -> Data
}
```

## App (`Sources/LibreTube/SABR/`, iOS only)
- `BotGuardPoTokenProvider: PoTokenProvider`: a WKWebView port of Android's `api/poToken/PoTokenWebView.kt`,
  `PoTokenGenerator.kt` and `assets/po_token.html`. A working JS reference that runs in headless Chromium is in
  `$SCRATCH/potoken/gen.html`, which includes the challenge parsing that Android does in Kotlin. Caches the
  integrity token until it expires (TTL minus 10 minutes).
- `JSCPlayerScriptRunner: PlayerScriptRunner`: JavaScriptCore. Proven approach in `$SCRATCH/potoken-scripts/decipher.js`.
  It strips the IIFE wrapper, evaluates with stubs, finds the URL builder with
  `/(\w*)=function\(.*?\)\{[^}]*?set\("alr","yes"\);\w&&/`, calls `builder(url, sp, s)`, `set("n", n)`, invokes the
  first prototype method that isn't constructor/set/get/clone, then `get("n")`. The signature comes back
  URL-encoded, so `decodeURIComponent` it.
- `SabrHLSServer`: localhost HTTP server (Network.framework `NWListener`). Serves
  `/master.m3u8`, `/<itag>.m3u8`, `/<itag>/init.mp4` and `/<itag>/<n>.m4s` (via `SabrSession.segment`), with HLS
  version 7, `EXT-X-MAP` and real per-segment `EXTINF` durations from `SabrSegmentIndex`. Uses H.264 video
  variants only (no VP9/AV1, which AVPlayer can't play) plus the default AAC audio track.
- Player integration: PlayerViewModel tries `streams.hls` first, then SABR through `SabrHLSServer`, then the old LocalHLS.

`$SCRATCH` = /tmp/claude-1000/-home-szymonb-Development-LibreTube/7249df7f-927d-4b14-a2b5-754d95fb3c04/scratchpad
