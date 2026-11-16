import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds an HLS presentation on the device from YouTube's DASH files.
///
/// YouTube's adaptive streams are fragmented MP4 files with a `sidx` segment index.
/// Each fragment is described as an HLS byte-range segment (`EXT-X-BYTERANGE` +
/// `EXT-X-MAP`), so AVPlayer can play separate video and audio tracks in sync, with
/// adaptive quality switching, straight from googlevideo.com — no proxy or remuxing.
public struct LocalHLS: Sendable {
    /// Playlists by file name. `master.m3u8` is the entry point; the others are referenced relatively.
    public let playlists: [String: String]
    public static let masterName = "master.m3u8"

    struct Track: Sendable {
        let name: String
        let stream: PipedStream
        let url: String
        let initRange: ClosedRange<Int>
        let indexRange: ClosedRange<Int>
    }

    struct Segment: Sendable, Equatable {
        let offset: Int
        let length: Int
        let duration: Double
    }

    public enum BuildError: Error, Sendable, LocalizedError {
        case noCompatibleStreams
        case badIndex(String)

        public var errorDescription: String? {
            switch self {
            case .noCompatibleStreams: "No H.264/AAC streams with segment index were found."
            case .badIndex(let detail): "Couldn't read the stream's segment index (\(detail))."
            }
        }
    }

    /// Uses every H.264 MP4 video stream up to `maxHeight` plus the best AAC audio stream
    /// (preferring the original/default audio track).
    public static func build(streams: Streams, maxHeight: Int? = nil, session: URLSession = .shared) async throws -> LocalHLS {
        var videos = streams.videoStreams
            .filter { $0.videoOnly == true && $0.mimeType == "video/mp4" && ($0.codec ?? "").hasPrefix("avc1") }
            .compactMap { track(for: $0, prefix: "video") }
        if let maxHeight {
            let capped = videos.filter { ($0.stream.height ?? 0) <= maxHeight }
            videos = capped.isEmpty ? Array(videos.suffix(1)) : capped
        }
        let audioCandidates = streams.audioStreams
            .filter { $0.mimeType == "audio/mp4" && ($0.codec ?? "").hasPrefix("mp4a") }
            .sorted { lhs, rhs in
                let lo = lhs.audioTrackType == nil || lhs.audioTrackType == "ORIGINAL"
                let ro = rhs.audioTrackType == nil || rhs.audioTrackType == "ORIGINAL"
                if lo != ro { return lo }
                return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
            }
        guard !videos.isEmpty, let audio = audioCandidates.lazy.compactMap({ track(for: $0, prefix: "audio") }).first else {
            throw BuildError.noCompatibleStreams
        }

        // Fetch all segment indexes concurrently (each is a ~1 KB range request).
        let tracks = videos + [audio]
        let segments = try await withThrowingTaskGroup(of: (String, [Segment]).self) { group in
            for track in tracks {
                group.addTask { (track.name, try await fetchSegments(track, session: session)) }
            }
            var result: [String: [Segment]] = [:]
            for try await (name, segs) in group { result[name] = segs }
            return result
        }

        var playlists: [String: String] = [:]
        for track in tracks {
            playlists["\(track.name).m3u8"] = mediaPlaylist(track, segments: segments[track.name] ?? [])
        }
        playlists[masterName] = masterPlaylist(videos: videos, audio: audio)
        return LocalHLS(playlists: playlists)
    }

    static func track(for stream: PipedStream, prefix: String) -> Track? {
        guard let url = stream.url,
              let initStart = stream.initStart, let initEnd = stream.initEnd, initEnd > initStart,
              let indexStart = stream.indexStart, let indexEnd = stream.indexEnd, indexEnd > indexStart
        else { return nil }
        let name = "\(prefix)_\(stream.itag ?? stream.height ?? 0)_\(abs(url.hashValue % 10_000))"
        return Track(name: name, stream: stream, url: url, initRange: initStart...initEnd, indexRange: indexStart...indexEnd)
    }

    static func fetchSegments(_ track: Track, session: URLSession) async throws -> [Segment] {
        guard let url = URL(string: track.url) else { throw BuildError.badIndex("invalid URL") }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(track.indexRange.lowerBound)-\(track.indexRange.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BuildError.badIndex("HTTP \(http.statusCode)")
        }
        return try parseSidx(data, anchor: track.indexRange.upperBound + 1)
    }

    /// Parses an ISO-BMFF `sidx` box. `anchor` is the file offset of the first byte after the box.
    static func parseSidx(_ data: Data, anchor: Int) throws -> [Segment] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
        func u64(_ i: Int) -> Int { u32(i) << 32 | u32(i + 4) }

        guard bytes.count >= 32, bytes[4...7].elementsEqual("sidx".utf8) else { throw BuildError.badIndex("no sidx box") }
        let version = bytes[8]
        var p = 12 + 4 // full box header + reference_ID
        let timescale = u32(p); p += 4
        guard timescale > 0 else { throw BuildError.badIndex("zero timescale") }
        let firstOffset: Int
        if version == 0 { p += 4; firstOffset = u32(p); p += 4 } else { p += 8; firstOffset = u64(p); p += 8 }
        p += 2 // reserved
        let count = u16(p); p += 2
        guard bytes.count >= p + count * 12 else { throw BuildError.badIndex("truncated") }

        var offset = anchor + firstOffset
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for i in 0..<count {
            let base = p + i * 12
            let size = u32(base) & 0x7FFF_FFFF
            let duration = Double(u32(base + 4)) / Double(timescale)
            segments.append(Segment(offset: offset, length: size, duration: duration))
            offset += size
        }
        return segments
    }

    static func mediaPlaylist(_ track: Track, segments: [Segment]) -> String {
        let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(track.url)\",BYTERANGE=\"\(track.initRange.count)@\(track.initRange.lowerBound)\"",
        ]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.6f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(track.url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func masterPlaylist(videos: [Track], audio: Track) -> String {
        let audioCodec = audio.stream.codec ?? "mp4a.40.2"
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(audio.stream.audioTrackName ?? "Default")\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audio.name).m3u8\"",
        ]
        for video in videos.sorted(by: { ($0.stream.height ?? 0) > ($1.stream.height ?? 0) }) {
            let s = video.stream
            var attributes = [
                "BANDWIDTH=\((s.bitrate ?? 1_000_000) + (audio.stream.bitrate ?? 128_000))",
                "CODECS=\"\(s.codec ?? "avc1.4d401f"),\(audioCodec)\"",
                "AUDIO=\"audio\"",
            ]
            if let w = s.width, let h = s.height { attributes.append("RESOLUTION=\(w)x\(h)") }
            if let fps = s.fps, fps > 0 { attributes.append("FRAME-RATE=\(fps)") }
            lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
            lines.append("\(video.name).m3u8")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
