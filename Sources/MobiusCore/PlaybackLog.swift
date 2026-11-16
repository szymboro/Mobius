import Foundation

/// In-memory diagnostics for the playback pipeline (extractor, PO token, SABR, local server, AVPlayer).
/// Shown in the player's log sheet so problems on a device can be copied and reported.
public final class PlaybackLog: @unchecked Sendable {
    public static let shared = PlaybackLog()
    public static let maxLines = 3000

    private let lock = NSLock()
    private var lines: [String] = []
    private var start = Date()

    public init() {}

    public func add(_ message: String, _ category: String = "app") {
        let line = String(format: "%7.2f [%@] %@", Date().timeIntervalSince(start), category, message)
        lock.lock()
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        lock.unlock()
    }

    /// Starts a new log section for a video (keeps the earlier lines, resets the clock).
    public func begin(_ title: String) {
        lock.lock()
        start = Date()
        lines.append("")
        lines.append("===== \(title) — \(ISO8601DateFormatter().string(from: Date())) =====")
        lock.unlock()
    }

    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
