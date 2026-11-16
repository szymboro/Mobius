import Foundation
import AeternusCore
import Network

/// A localhost HTTP/1.1 server that exposes a `SabrSession` to AVPlayer as fMP4 HLS.
///
/// Routes:
/// - `/master.m3u8`: H.264 video variants plus an `EXT-X-MEDIA` audio group (default AAC track).
///   Lists only the variants of `selectedQuality` when one is set, else every variant up to 1080p.
///   Query strings are ignored, so callers can cache-bust with `/master.m3u8?q=720`.
/// - `/<itag>.m3u8`: VOD media playlist (the audio one doubles as the audio-only entry point) with exact per-segment durations (built on first request)
/// - `/<itag>/init.mp4`: fMP4 init segment
/// - `/<itag>/<n>.m4s`: media segment `n` (1-based)
///
/// Bound to 127.0.0.1 on an ephemeral port. Thread-safety: all listener/connection state lives
/// on `queue`; SABR work happens in Swift concurrency and hops back to `queue` to reply.
final class SabrHLSServer: @unchecked Sendable {
    enum ServerError: Error, LocalizedError {
        case noPlayableFormats
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPlayableFormats: "YouTube offered no H.264/AAC formats over SABR."
            case .listenerFailed(let detail): "Couldn't start the local streaming server: \(detail)"
            }
        }
    }

    let manifest: SabrManifest
    let session: SabrSession
    /// Every H.264 variant (one per quality and frame rate), best first.
    let videoFormats: [SabrFormat]
    /// Distinct qualities (short side in pixels, as in "720p") of `videoFormats`, best first.
    let availableQualities: [Int]
    let audioFormat: SabrFormat
    private let formatsByItag: [Int: SabrFormat]
    private let indexes: SabrIndexStore

    private let queue = DispatchQueue(label: "Aeternus.SabrHLSServer", qos: .userInitiated)
    // queue-confined
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var currentPort: UInt16?
    private var stopped = true
    /// nil = Auto (adaptive up to `autoMaxQuality`).
    private var selectedQualityOnQueue: Int?
    private var audioOnlyOnQueue = false

    /// Auto lists every variant up to this quality; higher ones need an explicit choice.
    static let autoMaxQuality = 1080

    /// - Parameter selectedQuality: initial quality restriction (nil = Auto); see `selectedQuality`.
    init(manifest: SabrManifest, selectedQuality: Int? = nil, session: URLSession = .shared) throws {
        self.manifest = manifest
        self.session = SabrSession(manifest: manifest, session: session)
        self.indexes = SabrIndexStore(session: self.session)

        guard let audio = Self.pickAudio(manifest.formats) else { throw ServerError.noPlayableFormats }
        let videos = Self.pickVideos(manifest.formats)
        guard !videos.isEmpty else { throw ServerError.noPlayableFormats }
        audioFormat = audio
        videoFormats = videos
        var qualities: [Int] = []
        for video in videos where !qualities.contains(Self.quality(of: video)) {
            qualities.append(Self.quality(of: video))
        }
        availableQualities = qualities
        selectedQualityOnQueue = selectedQuality
        var byItag: [Int: SabrFormat] = [:]
        for format in videos + [audio] { byItag[format.itag] = format }
        formatsByItag = byItag
    }

    deinit {
        // Handlers only capture `self` weakly, so this runs once the owner lets go.
        let listener = self.listener
        let connections = self.connections.values
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    var masterURL: URL? {
        queue.sync { currentPort.map { URL(string: "http://127.0.0.1:\($0)/master.m3u8")! } }
    }

    var isRunning: Bool { queue.sync { !stopped } }

    /// Restricts `/master.m3u8` to this quality's variants (nil = Auto). Takes effect for the next
    /// master playlist request, so the caller must load a fresh AVPlayerItem afterwards.
    var selectedQuality: Int? {
        get { queue.sync { selectedQualityOnQueue } }
        set { queue.sync { selectedQualityOnQueue = newValue } }
    }

    /// Audio-only playback loads `audioPlaylistURL` instead of the master playlist; with only the
    /// audio format requested, `SabrSession` asks YouTube for audio alone. Also skips prefetching
    /// the first video index.
    var audioOnly: Bool {
        get { queue.sync { audioOnlyOnQueue } }
        set { queue.sync { audioOnlyOnQueue = newValue } }
    }

    /// The audio media playlist, playable on its own (no video is ever requested).
    var audioPlaylistURL: URL? {
        queue.sync { currentPort.map { URL(string: "http://127.0.0.1:\($0)/\(audioFormat.itag).m3u8")! } }
    }

    // MARK: Lifecycle

    /// Starts listening (on `preferredPort` if given and free, else an ephemeral port) and
    /// returns the master playlist URL. Also starts fetching the indexes AVPlayer will ask for first.
    @discardableResult
    func start(preferredPort: UInt16? = nil) async throws -> URL {
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { self.startListener(preferredPort: preferredPort, continuation: continuation) }
        }
        prefetch()
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
    }

    private func startListener(preferredPort: UInt16?, continuation: CheckedContinuation<UInt16, Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        if !stopped, let currentPort {
            continuation.resume(returning: currentPort)
            return
        }
        do {
            let listener = try Self.makeListener(port: preferredPort)
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue, once.claim() else { return }
                    self.currentPort = port
                    self.stopped = false
                    continuation.resume(returning: port)
                case .failed(let error), .waiting(let error):
                    // `.waiting` (e.g. port in use) before ready is as good as a failure here.
                    if case .waiting = state, once.isClaimed { return }
                    listener?.cancel()
                    if once.claim() {
                        if self.listener === listener { self.listener = nil }
                        if preferredPort != nil {
                            // Port taken: fall back to an ephemeral one.
                            self.startListener(preferredPort: nil, continuation: continuation)
                        } else {
                            continuation.resume(throwing: ServerError.listenerFailed(error.localizedDescription))
                        }
                    } else {
                        self.stopOnQueue()
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: ServerError.listenerFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] nwConnection in
                guard let self else { nwConnection.cancel(); return }
                self.accept(nwConnection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            if preferredPort != nil {
                startListener(preferredPort: nil, continuation: continuation)
            } else {
                continuation.resume(throwing: ServerError.listenerFailed(error.localizedDescription))
            }
        }
    }

    private static func makeListener(port: UInt16?) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let nwPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        return try NWListener(using: parameters)
    }

    /// Stops listening and drops every connection. Safe to call from any thread, repeatedly.
    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ nwConnection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { nwConnection.cancel(); return }
        let connection = HTTPConnection(connection: nwConnection, queue: queue) { [weak self] request, reply in
            self?.handle(request, reply: reply)
        }
        let id = ObjectIdentifier(connection)
        connection.onClose = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = connection
        connection.start()
    }

    private func prefetch() {
        let indexes = self.indexes
        let first = [audioFormat] + queue.sync {
            audioOnlyOnQueue ? [] : Array(listedVideos(selected: selectedQualityOnQueue).prefix(1))
        }
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for format in first {
                    group.addTask { _ = try? await indexes.index(for: format) }
                }
            }
        }
    }

    // MARK: Routing

    private func handle(_ request: HTTPRequest, reply rawReply: @escaping @Sendable (HTTPResponse) -> Void) {
        let started = Date()
        let label = "\(request.method) \(request.path)\(request.headers["range"].map { " [\($0)]" } ?? "")"
        let reply: @Sendable (HTTPResponse) -> Void = { response in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            var line = "\(label) -> \(response.status) \(response.body.count) B in \(ms) ms"
            if response.status >= 400 { line += ": " + String(decoding: response.body.prefix(300), as: UTF8.self) }
            PlaybackLog.shared.add(line, "server")
            rawReply(response)
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            reply(.text(405, "Method Not Allowed"))
            return
        }
        let path = request.path
        if path == "/master.m3u8" {
            let videos = listedVideos(selected: selectedQualityOnQueue)
            reply(.init(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(masterPlaylist(videos: videos).utf8)))
            return
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let indexes = self.indexes
        let session = self.session

        if parts.count == 1, parts[0].hasSuffix(".m3u8"),
           let itag = Int(parts[0].dropLast(5)), let format = formatsByItag[itag] {
            respondAsync(reply) {
                let index = try await indexes.index(for: format)
                return .init(status: 200, contentType: "application/vnd.apple.mpegurl",
                             body: Data(Self.mediaPlaylist(index).utf8))
            }
            return
        }
        if parts.count == 2, let itag = Int(parts[0]), let format = formatsByItag[itag] {
            let contentType = format.isAudio ? "audio/mp4" : "video/mp4"
            if parts[1] == "init.mp4" {
                respondAsync(reply) {
                    let index = try await indexes.index(for: format)
                    return .init(status: 200, contentType: contentType, body: index.initSegment)
                }
                return
            }
            if parts[1].hasSuffix(".m4s"), let number = Int(parts[1].dropLast(4)), number >= 1 {
                respondAsync(reply) {
                    let index = try await indexes.index(for: format)
                    guard number <= index.segmentDurations.count else { return .text(404, "No such segment") }
                    let data = try await session.segment(number, of: format)
                    return .init(status: 200, contentType: contentType, body: data)
                }
                return
            }
        }
        reply(.text(404, "Not Found"))
    }

    private func respondAsync(_ reply: @escaping @Sendable (HTTPResponse) -> Void,
                              _ work: @escaping @Sendable () async throws -> HTTPResponse) {
        Task.detached(priority: .userInitiated) {
            do {
                reply(try await work())
            } catch {
                reply(.text(502, "SABR error: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Playlists

    /// The variants `/master.m3u8` lists, in order (AVPlayer starts with the first one).
    private func listedVideos(selected: Int?) -> [SabrFormat] {
        if let selected {
            let matching = videoFormats.filter { Self.quality(of: $0) == selected }
            if !matching.isEmpty { return matching }
        }
        // Auto: best first so playback starts there; AVPlayer adapts downwards on slow connections.
        // SabrSession handles switching between video formats mid-session.
        let auto = videoFormats.filter { Self.quality(of: $0) <= Self.autoMaxQuality }
        return auto.isEmpty ? Array(videoFormats.suffix(1)) : auto
    }

    func masterPlaylist(videos: [SabrFormat]) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let audioName = audioFormat.audioTrackId.map { String($0.prefix { $0 != "." }) } ?? "Default"
        lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(audioName)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioFormat.itag).m3u8\"")
        for video in videos {
            var attributes = [
                "BANDWIDTH=\(max(video.bitrate, 1) + max(audioFormat.bitrate, 0))",
                "CODECS=\"\(video.codecs),\(audioFormat.codecs)\"",
            ]
            if let width = video.width, let height = video.height {
                attributes.append("RESOLUTION=\(width)x\(height)")
            }
            if let fps = video.fps, fps > 0 {
                attributes.append("FRAME-RATE=\(String(format: "%.3f", Double(fps)))")
            }
            attributes.append("AUDIO=\"audio\"")
            lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
            lines.append("\(video.itag).m3u8")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func mediaPlaylist(_ index: SabrSegmentIndex) -> String {
        let target = Int((index.segmentDurations.max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-MEDIA-SEQUENCE:1",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(index.format.itag)/init.mp4\"",
        ]
        for (offset, duration) in index.segmentDurations.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.6f", duration)),")
            lines.append("\(index.format.itag)/\(offset + 1).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Format selection

    static func isPlayableVideo(_ format: SabrFormat) -> Bool {
        !format.isAudio && format.mimeType == "video/mp4" && format.codecs.hasPrefix("avc1")
    }

    static func isPlayableAudio(_ format: SabrFormat) -> Bool {
        format.isAudio && format.mimeType == "audio/mp4" && format.codecs.hasPrefix("mp4a")
    }

    /// The default (original-language) AAC track, preferring plain over DRC/xtag variants,
    /// then the highest bitrate.
    static func pickAudio(_ formats: [SabrFormat]) -> SabrFormat? {
        formats.filter(isPlayableAudio).max { lhs, rhs in
            func rank(_ f: SabrFormat) -> (Int, Int, Int) {
                ((f.isDefaultAudio || f.audioTrackId == nil) ? 1 : 0, f.xtags == nil ? 1 : 0, f.bitrate)
            }
            return rank(lhs) < rank(rhs)
        }
    }

    /// "720p" quality of a format: the short side, so portrait videos are labelled like YouTube does.
    static func quality(of format: SabrFormat) -> Int {
        if let width = format.width, let height = format.height, width > 0, height > 0 {
            return min(width, height)
        }
        return format.height ?? 0
    }

    /// Every H.264 variant, one per (height, fps), best first.
    static func pickVideos(_ formats: [SabrFormat]) -> [SabrFormat] {
        var best: [String: SabrFormat] = [:]
        for format in formats where isPlayableVideo(format) {
            let key = "\(format.height ?? 0)p\(format.fps ?? 0)"
            if let existing = best[key], existing.bitrate >= format.bitrate { continue }
            best[key] = format
        }
        return best.values.sorted {
            (quality(of: $0), $0.fps ?? 0, $0.bitrate) > (quality(of: $1), $1.fps ?? 0, $1.bitrate)
        }
    }
}

/// Set-once flag for callbacks that all run on the server queue.
private final class OnceFlag: @unchecked Sendable {
    private var done = false
    var isClaimed: Bool { done }
    func claim() -> Bool {
        guard !done else { return false }
        done = true
        return true
    }
}

/// Fetches each format's `SabrSegmentIndex` once, sharing in-flight requests.
actor SabrIndexStore {
    private let session: SabrSession
    private var tasks: [Int: Task<SabrSegmentIndex, Error>] = [:]

    init(session: SabrSession) {
        self.session = session
    }

    func index(for format: SabrFormat) async throws -> SabrSegmentIndex {
        if let task = tasks[format.itag] {
            return try await task.value
        }
        let session = self.session
        let task = Task { try await session.index(for: format) }
        tasks[format.itag] = task
        do {
            return try await task.value
        } catch {
            // Let the next request retry.
            tasks[format.itag] = nil
            throw error
        }
    }
}

// MARK: - HTTP

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]   // lower-cased names
    let keepAlive: Bool
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        .init(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }
}

/// One keep-alive TCP connection; requests are handled one at a time, in order.
/// All state is confined to the server queue.
final class HTTPConnection: @unchecked Sendable {
    typealias Handler = (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    private static let maxHeaderBytes = 32 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: Handler
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var busy = false
    private var receiving = false
    private var peerClosed = false
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.process()
            case .failed, .cancelled: self.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }

    private func receive() {
        guard !receiving, !closed, !peerClosed else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiving = false
            if let data, !data.isEmpty { self.buffer.append(data) }
            if isComplete || error != nil { self.peerClosed = true }
            self.process()
        }
    }

    /// Parses and dispatches the next buffered request, or reads more.
    private func process() {
        guard !closed, !busy else { return }
        switch parseRequest() {
        case .incomplete:
            if peerClosed { cancel() } else { receive() }
        case .invalid(let status):
            busy = true
            send(.text(status, HTTPResponse.reason(status)), for: nil, keepAlive: false)
        case .request(let request):
            busy = true
            handler(request) { [weak self] response in
                guard let self else { return }
                self.queue.async { self.send(response, for: request, keepAlive: request.keepAlive) }
            }
        }
    }

    private enum ParseResult {
        case incomplete
        case invalid(Int)
        case request(HTTPRequest)
    }

    private func parseRequest() -> ParseResult {
        guard let end = buffer.range(of: Self.headerTerminator) else {
            return buffer.count > Self.maxHeaderBytes ? .invalid(431) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(400)
        }
        var lines = head.components(separatedBy: "\r\n")
        // Tolerate stray CRLFs between pipelined requests.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count == 3 else { return .invalid(400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Discard any request body (we only serve GET/HEAD); wait until it has fully arrived.
        let bodyLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let total = buffer.distance(from: buffer.startIndex, to: end.upperBound) + max(bodyLength, 0)
        guard buffer.count >= total else { return .incomplete }
        buffer = Data(buffer.dropFirst(total))

        let version = String(requestLine[2]).uppercased()
        let connectionHeader = headers["connection"]?.lowercased() ?? ""
        let keepAlive = version == "HTTP/1.0"
            ? connectionHeader.contains("keep-alive")
            : !connectionHeader.contains("close")

        var target = String(requestLine[1])
        if let schemeRange = target.range(of: "://"), let slash = target[schemeRange.upperBound...].firstIndex(of: "/") {
            target = String(target[slash...])   // absolute-form
        }
        if let query = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            target = String(target[..<query])
        }
        let path = target.removingPercentEncoding ?? target
        return .request(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path,
                                    headers: headers, keepAlive: keepAlive))
    }

    private func send(_ response: HTTPResponse, for request: HTTPRequest?, keepAlive: Bool) {
        guard !closed else { return }
        var status = response.status
        var body = response.body
        var extraHeaders: [String] = []

        if status == 200, let range = request?.headers["range"] {
            switch Self.byteRange(range, length: body.count) {
            case .none:
                break   // unparsable or multi-range: serve the whole thing
            case .some(.unsatisfiable):
                status = 416
                extraHeaders.append("Content-Range: bytes */\(body.count)")
                body = Data()
            case .some(.range(let bounds)):
                status = 206
                extraHeaders.append("Content-Range: bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(body.count)")
                body = body.subdata(in: (body.startIndex + bounds.lowerBound)..<(body.startIndex + bounds.upperBound + 1))
            }
        }

        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        head += "Content-Type: \(status == 416 ? "text/plain" : response.contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Cache-Control: no-cache\r\n"
        for header in extraHeaders { head += header + "\r\n" }
        head += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        head += "\r\n"

        let isHead = request?.method == "HEAD"
        let payload = isHead ? Data(head.utf8) : Data(head.utf8) + body
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.busy = false
            if error != nil || !keepAlive {
                self.cancel()
            } else {
                self.process()
            }
        })
    }

    private enum RangeResult {
        case range(ClosedRange<Int>)
        case unsatisfiable
    }

    /// Single `bytes=` range; nil means "ignore the header".
    private static func byteRange(_ header: String, length: Int) -> RangeResult? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endText = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffix = Int(endText) else { return nil }
            guard suffix > 0, length > 0 else { return .unsatisfiable }
            return .range(max(length - suffix, 0)...(length - 1))
        }
        guard let start = Int(startText), start >= 0 else { return nil }
        guard start < length else { return .unsatisfiable }
        var end = length - 1
        if !endText.isEmpty {
            guard let parsed = Int(endText), parsed >= start else { return nil }
            end = min(parsed, length - 1)
        }
        return .range(start...end)
    }
}
