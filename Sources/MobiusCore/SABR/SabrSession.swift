import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SABR/UMP streaming client: a Swift port of LibreTube Android's `SabrClient.kt`, with protocol details
/// cross-checked against yt-dlp's `_streaming/sabr/stream.py`.
///
/// The per-format API hides SABR's stateful, batched nature: every request goes through one serial queue
/// (the server state — playback cookie, SABR contexts, redirects, backoff — is sequential), both the current
/// audio and video formats are always selected, and formats other than the requested one are reported as
/// fully buffered so the server only sends media for the format being asked for. Segments that arrive in the
/// same response (the server's readahead) are cached for later calls.
public actor SabrSession {
    private struct FormatKey: Hashable {
        let itag: Int
        let xtags: String

        init(itag: Int, xtags: String?) {
            self.itag = itag
            self.xtags = xtags ?? ""
        }
    }

    private struct FormatState {
        /// FormatId echoed back to the server (from FORMAT_INITIALIZATION_METADATA).
        var itag: Int
        var lastModified: UInt64
        var xtags: String?
        var isAudio: Bool
        var endSegmentNumber: Int?
        var endTimeMs: Int?
        /// Raw init segment as sent by the server (ftyp+moov, usually followed by sidx).
        var initRaw: Data?
        var index: SabrSegmentIndex?
        /// Start time (ms) of each media segment, 1-based (index 0 = segment 1).
        var startTimesMs: [Int] = []
        var segments: [Int: Data] = [:]
    }

    private struct PartialSegment {
        let key: FormatKey
        let isInit: Bool
        let sequenceNumber: Int
        let contentLength: Int?
        var data = Data()
    }

    private struct Target {
        let format: SabrFormat
        let segment: Int // 0 = init
    }

    private let manifest: SabrManifest
    private let urlSession: URLSession

    private var serverURL: URL
    private var requestNumber = 0
    private var poToken: Data
    private var regeneratedPoToken = false
    private var lastProtectionStatus = 0
    private var playbackCookie: Data?
    private var backoffMs = 0
    private var sabrContexts: [Int: Data] = [:]
    private var sabrContextsToSend: Set<Int> = []

    private var states: [FormatKey: FormatState] = [:]
    private var partials: [Int: PartialSegment] = [:]
    private var selectedAudio: SabrFormat?
    private var selectedVideo: SabrFormat?
    private var lastRequestDate: Date?
    private var lastSeekDate: Date?
    private var lastTarget: [FormatKey: Int] = [:]

    private var inflight: (id: Int, task: Task<Void, Error>)?
    private var nextTaskId = 0
    private var fatalError: (any Error)?

    /// Cached media segments kept per format (around the most recently requested segment).
    private let maxCachedSegments = 48
    private static let maxAttempts = 8
    private static let transientCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
    ]
    private static let debug = ProcessInfo.processInfo.environment["LIBRETUBE_SABR_DEBUG"] != nil
    private var partLog: [String] = []

    private func log(_ message: @autoclosure () -> String) {
        let text = message()
        PlaybackLog.shared.add(text, "sabr")
        if Self.debug { print("[sabr] \(text)") }
    }

    public init(manifest: SabrManifest, session: URLSession = .shared) {
        self.manifest = manifest
        self.urlSession = session
        self.serverURL = manifest.serverURL
        self.poToken = Data(base64URLEncoded: manifest.poToken) ?? Data()
    }

    // MARK: - Public API

    /// Fetches the init segment and the full segment list (duration of every segment).
    public func index(for format: SabrFormat) async throws -> SabrSegmentIndex {
        let key = Self.key(format)
        var attempts = 0
        while true {
            if let fatalError { throw fatalError }
            if let index = states[key]?.index { return index }
            if let state = states[key], state.initRaw != nil {
                let index = try buildIndex(key: key, format: format)
                return index
            }
            try await run(Target(format: format, segment: 0), attempts: &attempts)
        }
    }

    /// Media segment `number` (1-based, matching segmentDurations) as a complete fMP4 fragment (moof+mdat).
    /// May fetch neighbours in the same request and cache them. Must be safe for concurrent calls.
    public func segment(_ number: Int, of format: SabrFormat) async throws -> Data {
        let index = try await index(for: format)
        guard (1...index.segmentDurations.count).contains(number) else {
            throw SabrStreamError.segmentUnavailable(itag: format.itag, segment: number)
        }
        let key = Self.key(format)
        if let previous = lastTarget[key], number != previous + 1, number != previous {
            lastSeekDate = Date()
        }
        lastTarget[key] = number
        var attempts = 0
        while true {
            if let fatalError { throw fatalError }
            if let data = states[key]?.segments[number] {
                evict(key: key, around: number)
                return data
            }
            try await run(Target(format: format, segment: number), attempts: &attempts)
        }
    }

    // MARK: - Request queue

    /// Runs one SABR request for `target`, or waits for the request already in flight.
    private func run(_ target: Target, attempts: inout Int) async throws {
        if let inflight {
            _ = try? await inflight.task.value
            return
        }
        attempts += 1
        if attempts > Self.maxAttempts {
            // ATTESTATION_PENDING with no media: YouTube stopped serving because the PO token isn't accepted
            // (it allows roughly the first minute without one).
            if lastProtectionStatus == 2 { throw SabrStreamError.attestationRequired }
            throw SabrStreamError.segmentUnavailable(itag: target.format.itag, segment: target.segment)
        }
        nextTaskId += 1
        let id = nextTaskId
        let task = Task {
            defer { self.finish(id) }
            try await self.request(target)
        }
        inflight = (id, task)
        try await task.value
    }

    private func finish(_ id: Int) {
        if inflight?.id == id { inflight = nil }
    }

    // MARK: - SABR request

    private func request(_ target: Target) async throws {
        if backoffMs > 0 {
            let wait = backoffMs
            backoffMs = 0
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
        }

        let format = target.format
        if format.isAudio { selectedAudio = format } else { selectedVideo = format }
        if selectedAudio == nil, selectedVideo != nil {
            // Always select an audio format with a video one: otherwise the server picks one itself and
            // treats its segments as delivered for the whole audio track.
            selectedAudio = Self.defaultAudio(in: manifest.formats)
        }
        let targetKey = Self.key(format)
        let playerTimeMs: Int
        if target.segment >= 1, let starts = states[targetKey]?.startTimesMs, target.segment <= starts.count {
            playerTimeMs = starts[target.segment - 1]
        } else {
            playerTimeMs = 0
        }

        let body = buildRequest(targetKey: targetKey, playerTimeMs: playerTimeMs)
        requestNumber += 1
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        var items = components.percentEncodedQueryItems ?? []
        items.removeAll { $0.name == "rn" }
        items.append(URLQueryItem(name: "rn", value: String(requestNumber)))
        components.percentEncodedQueryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            manifest.clientName == "VISIONOS" ? YouTubeExtractor.visionOS.userAgent : YouTubePlayerScript.browserUserAgent,
            forHTTPHeaderField: "User-Agent")

        lastRequestDate = Date()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where Self.transientCodes.contains(error.code) {
            log("rn=\(requestNumber) transient \(error.code.rawValue), retrying")
            return // retried by the caller (bounded by maxAttempts)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if (500..<600).contains(http.statusCode) { return } // transient: retried by the caller
            throw SabrStreamError.http(http.statusCode)
        }

        var reader = UMPReader(data)
        partials.removeAll()
        partLog.removeAll()
        defer {
            log("rn=\(requestNumber) pot=\(poToken.count) target=\(format.itag)#\(target.segment) t=\(playerTimeMs) -> \(data.count) B: "
                + partLog.joined(separator: " "))
        }
        while let part = reader.readPart() {
            try await process(part)
        }
        if reader.remaining > 0 { partLog.append("leftover=\(reader.remaining)") }
    }

    private func buildRequest(targetKey: FormatKey, playerTimeMs: Int) -> Data {
        let now = Date()
        func ms(since date: Date?) -> Int { date.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0 }
        let height = max(selectedVideo?.height ?? 0, 360)
        let width = max(selectedVideo?.width ?? 0, 640)
        // As in LuanRT/googlevideo's SabrStreamingAdapter: each request is about exactly one format.
        let targetIsAudio = selectedAudio.map { Self.key($0) == targetKey } ?? false
        let otherActive: SabrFormat? = targetIsAudio ? selectedVideo : selectedAudio

        var w = ProtoWriter()
        // 1: ClientAbrState
        w.message(1) { s in
            s.int(13, ms(since: lastSeekDate)) // time_since_last_manual_format_selection_ms
            s.int(16, height) // last_manual_selected_resolution
            s.int(18, width) // client_viewport_width
            s.int(19, height) // client_viewport_height
            s.int(21, height) // sticky_resolution
            s.bool(22, false) // client_viewport_is_flexible
            s.int(28, playerTimeMs) // player_time_ms
            s.int(29, ms(since: lastSeekDate)) // time_since_last_seek
            s.int(34, 1) // visibility
            s.float(35, 1) // playback_rate
            s.int(36, ms(since: lastRequestDate)) // elapsed_wall_time_ms
            s.int(39, ms(since: lastSeekDate)) // time_since_last_action_ms
            s.int(40, targetIsAudio || selectedVideo == nil ? 1 : 2) // enabled_track_types_bitfield: 1 = audio only, 2 = video only
            if let track = selectedAudio?.audioTrackId { s.string(69, track) }
        }
        // 2: initialization format ids: the other active format (discarded below) and the target
        // once it is initialized. Listing every format ever seen made the server refuse to serve
        // a second video format (empty responses after a quality switch).
        let initialized = states.filter { $0.value.endSegmentNumber != nil || $0.value.initRaw != nil }
        let otherKey = otherActive.map { Self.key($0) }
        var initIds: [FormatKey] = []
        if let otherKey, initialized[otherKey] != nil { initIds.append(otherKey) }
        if initialized[targetKey] != nil { initIds.append(targetKey) }
        for key in initIds {
            guard let state = initialized[key] else { continue }
            w.message(2) { Self.writeFormatId(&$0, itag: state.itag, lastModified: state.lastModified, xtags: state.xtags) }
        }
        // 3: buffered ranges. The other active format is marked buffered "into oblivion"
        // so the server only sends media for the target format.
        let huge = (1 << 53) - 1
        for (key, state) in initialized where key == otherKey {
            w.message(3) { r in
                r.message(1) { Self.writeFormatId(&$0, itag: state.itag, lastModified: state.lastModified, xtags: state.xtags) }
                r.int(2, 0)
                r.int(3, huge)
                r.int(4, 0)
                r.int(5, huge)
                r.message(6) { t in
                    t.int(1, 0)
                    t.int(2, huge)
                    t.int(3, 1000)
                }
            }
        }
        // 4: player_time_ms, 5: ustreamer config
        w.int(4, playerTimeMs)
        w.bytes(5, manifest.ustreamerConfig)
        // 16/17: selected audio/video format ids
        if let audio = selectedAudio {
            w.message(16) { Self.writeFormatId(&$0, itag: audio.itag, lastModified: UInt64(audio.lastModified) ?? 0, xtags: audio.xtags) }
        }
        if let video = selectedVideo {
            w.message(17) { Self.writeFormatId(&$0, itag: video.itag, lastModified: UInt64(video.lastModified) ?? 0, xtags: video.xtags) }
        }
        // 19: StreamerContext
        w.message(19) { c in
            c.message(1) { info in
                if manifest.clientName == "VISIONOS" {
                    info.string(12, "Apple") // device_make
                    info.string(13, YouTubeExtractor.visionOS.extra["deviceModel"] ?? "")
                    info.int(16, Int(YouTubeExtractor.visionOS.id) ?? 101)
                    info.string(17, manifest.clientVersion)
                    info.string(18, "visionOS")
                    info.string(19, YouTubeExtractor.visionOS.extra["osVersion"] ?? "")
                } else {
                    info.int(16, 1) // client_name: WEB
                    info.string(17, manifest.clientVersion)
                    info.string(18, "Windows")
                    info.string(19, "10.0")
                }
            }
            if !poToken.isEmpty { c.bytes(2, poToken) }
            if let playbackCookie { c.bytes(3, playbackCookie) }
            for type in sabrContextsToSend.sorted() {
                if let value = sabrContexts[type] {
                    c.message(5) { ctx in
                        ctx.int(1, type)
                        ctx.bytes(2, value)
                    }
                }
            }
            for type in sabrContextsToSend.sorted() where sabrContexts[type] == nil {
                c.int(6, type)
            }
        }
        return w.data
    }

    private static func writeFormatId(_ w: inout ProtoWriter, itag: Int, lastModified: UInt64, xtags: String?) {
        w.int(1, itag)
        w.varint(2, lastModified)
        if let xtags, !xtags.isEmpty { w.string(3, xtags) }
    }

    // MARK: - UMP parts

    private func process(_ part: UMPReader.Part) async throws {
        guard let type = UMPPartType(rawValue: part.type) else {
            if Self.debug { partLog.append("?\(part.type)") }
            return
        }
        switch type {
        case .formatInitializationMetadata:
            let m = try ProtoMessage(part.data)
            if let videoId = m.string(1), videoId != manifest.videoId {
                throw SabrStreamError.protocolError("metadata for unexpected video \(videoId)")
            }
            guard let id = m.message(2), let itag = id.int(1) else { return }
            let key = FormatKey(itag: itag, xtags: id.string(3))
            var state = states[key] ?? FormatState(
                itag: itag, lastModified: id.uint(2) ?? 0, xtags: id.string(3),
                isAudio: (m.string(5) ?? "").hasPrefix("audio")
            )
            state.endSegmentNumber = m.int(4)
            state.endTimeMs = m.int(3)
            states[key] = state
            if Self.debug { partLog.append("FIM(\(itag) end#\(m.int(4) ?? -1) \(m.int(3) ?? -1)ms)") }

        case .mediaHeader:
            let m = try ProtoMessage(part.data)
            if let videoId = m.string(2), videoId != manifest.videoId {
                throw SabrStreamError.protocolError("media for unexpected video \(videoId)")
            }
            guard let headerId = m.int(1) else { return }
            let id = m.message(13)
            guard let itag = id?.int(1) ?? m.int(3) else { return }
            let key = resolveKey(FormatKey(itag: itag, xtags: id?.string(3) ?? m.string(5)))
            partials[headerId] = PartialSegment(
                key: key, isInit: m.bool(8), sequenceNumber: m.int(9) ?? 0,
                contentLength: m.int(14)
            )

        case .media:
            var reader = UMPReader(part.data)
            guard let headerId = reader.readVarint().map(Int.init) else { return }
            partials[headerId]?.data.append(reader.rest())

        case .mediaEnd:
            var reader = UMPReader(part.data)
            guard let headerId = reader.readVarint().map(Int.init), let segment = partials.removeValue(forKey: headerId)
            else { return }
            if let expected = segment.contentLength, expected != segment.data.count {
                throw SabrStreamError.protocolError(
                    "content length mismatch for itag \(segment.key.itag) (\(segment.data.count) of \(expected))")
            }
            guard var state = states[segment.key] else { return }
            if Self.debug { partLog.append("seg(\(segment.key.itag)#\(segment.isInit ? "init" : String(segment.sequenceNumber)))") }
            if segment.isInit {
                if state.initRaw == nil { state.initRaw = segment.data }
            } else if segment.sequenceNumber > 0 {
                state.segments[segment.sequenceNumber] = segment.data
            }
            states[segment.key] = state

        case .nextRequestPolicy:
            let m = try ProtoMessage(part.data)
            backoffMs = m.int(4) ?? 0
            if let cookie = m.bytes(7) { playbackCookie = cookie }
            if Self.debug { partLog.append("NRP(backoff \(backoffMs))") }

        case .sabrRedirect:
            let m = try ProtoMessage(part.data)
            if let string = m.string(1), let url = URL(string: string) { serverURL = url }
            if Self.debug { partLog.append("REDIRECT") }

        case .sabrContextUpdate:
            let m = try ProtoMessage(part.data)
            guard let type = m.int(1), let value = m.bytes(3) else { return }
            if Self.debug { partLog.append("CTX(\(type) send=\(m.bool(4)) policy=\(m.int(5) ?? 0))") }
            if m.int(5) == 2, sabrContexts[type] != nil { return } // KEEP_EXISTING
            sabrContexts[type] = value
            if m.bool(4) { sabrContextsToSend.insert(type) }

        case .sabrContextSendingPolicy:
            let m = try ProtoMessage(part.data)
            for type in m.repeatedInts(1) { sabrContextsToSend.insert(type) }
            for type in m.repeatedInts(2) { sabrContextsToSend.remove(type) }
            for type in m.repeatedInts(3) { sabrContexts.removeValue(forKey: type) }

        case .streamProtectionStatus:
            let m = try ProtoMessage(part.data)
            if Self.debug { partLog.append("SPS(\(m.int(1) ?? 0))") }
            lastProtectionStatus = m.int(1) ?? 0
            switch m.int(1) ?? 0 {
            case 2: // attestation pending: mint a fresh streaming token for the next request
                try await regeneratePoToken()
            case 3: // attestation required
                if regeneratedPoToken {
                    fatalError = SabrStreamError.attestationRequired
                    throw SabrStreamError.attestationRequired
                }
                try await regeneratePoToken()
            default:
                break
            }

        case .reloadPlayerResponse:
            fatalError = SabrStreamError.reloadRequired
            throw SabrStreamError.reloadRequired

        case .sabrError:
            let m = try ProtoMessage(part.data)
            let error = SabrStreamError.server(type: m.string(1) ?? "unknown", code: m.int(2) ?? 0)
            if Self.debug { partLog.append("ERROR(\(error))") }
            fatalError = error
            throw error

        case .sabrSeek:
            if Self.debug { partLog.append("SEEK(\((try? ProtoMessage(part.data))?.int(1) ?? -1))") } // our next request always states the position it wants
        }
    }

    private func regeneratePoToken() async throws {
        guard !regeneratedPoToken, let provider = YouTubeExtractor.poTokenProvider else { return }
        regeneratedPoToken = true
        let token = try await provider.poToken(for: manifest.visitorData)
        if let data = Data(base64URLEncoded: token) { poToken = data }
    }

    /// Falls back to matching by itag when the server's FormatId omits/changes xtags.
    private func resolveKey(_ key: FormatKey) -> FormatKey {
        if states[key] != nil { return key }
        return states.keys.first { $0.itag == key.itag } ?? key
    }

    /// The default-language AAC track with the highest bitrate (falling back to any audio format).
    private static func defaultAudio(in formats: [SabrFormat]) -> SabrFormat? {
        let audio = formats.filter(\.isAudio)
        let preferred = audio.filter { $0.isDefaultAudio && $0.mimeType == "audio/mp4" }
        return (preferred.isEmpty ? audio.filter(\.isDefaultAudio) : preferred).max { $0.bitrate < $1.bitrate }
            ?? audio.max { $0.bitrate < $1.bitrate }
    }

    private static func key(_ format: SabrFormat) -> FormatKey {
        FormatKey(itag: format.itag, xtags: format.xtags)
    }

    // MARK: - Index & cache

    private func buildIndex(key: FormatKey, format: SabrFormat) throws -> SabrSegmentIndex {
        guard var state = states[key], let raw = state.initRaw else {
            throw SabrStreamError.segmentUnavailable(itag: format.itag, segment: 0)
        }
        let boxes = MP4Boxes.topLevel(raw)
        guard boxes.contains(where: { $0.type == "moov" }) else { throw SabrStreamError.unsupportedFormat(format.itag) }
        var initSegment = Data()
        for box in boxes where box.type != "sidx" { initSegment.append(raw[box.range]) }
        guard let durations = MP4Boxes.sidxDurations(raw), !durations.isEmpty else {
            throw SabrStreamError.unsupportedFormat(format.itag)
        }
        var starts: [Int] = []
        var t = 0.0
        for d in durations {
            starts.append(Int((t * 1000).rounded()))
            t += d
        }
        let index = SabrSegmentIndex(format: format, initSegment: initSegment, segmentDurations: durations)
        state.index = index
        state.startTimesMs = starts
        states[key] = state
        return index
    }

    private func evict(key: FormatKey, around number: Int) {
        guard var state = states[key], state.segments.count > maxCachedSegments else { return }
        let sorted = state.segments.keys.sorted { abs($0 - number) > abs($1 - number) }
        for seg in sorted.prefix(state.segments.count - maxCachedSegments) {
            state.segments.removeValue(forKey: seg)
        }
        states[key] = state
    }
}
