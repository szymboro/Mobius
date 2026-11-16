import Foundation

public enum Formatters {
    /// "4:05", "1:02:03". Negative values (unknown / live) give "LIVE".
    public static func duration(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "LIVE" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return "\(h):\(pad(m)):\(pad(s))"
        }
        return "\(m):\(pad(s))"
    }

    /// Convenience overload for playback positions.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return duration(Int(seconds.rounded(.down)))
    }

    /// "999", "1.2K", "12K", "3.4M", "1.1B".
    public static func compactCount(_ n: Int) -> String {
        let sign = n < 0 ? "-" : ""
        let value = Double(abs(n))
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (threshold, suffix) in units where value >= threshold {
            let scaled = value / threshold
            let text: String
            if scaled < 10 {
                let rounded = (scaled * 10).rounded(.down) / 10
                text = rounded == rounded.rounded(.down) ? String(Int(rounded)) : String(format: "%.1f", rounded)
            } else {
                text = String(Int(scaled.rounded(.down)))
            }
            return sign + text + suffix
        }
        return sign + String(Int(value))
    }

    /// "1.2M views"
    public static func views(_ n: Int) -> String {
        "\(compactCount(n)) view\(n == 1 ? "" : "s")"
    }

    /// "1.2M subscribers"
    public static func subscribers(_ n: Int) -> String {
        "\(compactCount(n)) subscriber\(n == 1 ? "" : "s")"
    }

    /// Relative time like "3 days ago" for a date.
    public static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 0 {
            return "upcoming"
        }
        let units: [(Int, String)] = [
            (365 * 24 * 3600, "year"), (30 * 24 * 3600, "month"), (7 * 24 * 3600, "week"),
            (24 * 3600, "day"), (3600, "hour"), (60, "minute"),
        ]
        for (size, name) in units where seconds >= size {
            let count = seconds / size
            return "\(count) \(name)\(count == 1 ? "" : "s") ago"
        }
        return "just now"
    }

    /// Relative time for Piped epoch-millisecond timestamps; empty string if unknown.
    public static func relativeDate(millis: Int) -> String {
        guard millis > 0 else { return "" }
        return relativeDate(Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    private static func pad(_ v: Int) -> String {
        v < 10 ? "0\(v)" : "\(v)"
    }
}
