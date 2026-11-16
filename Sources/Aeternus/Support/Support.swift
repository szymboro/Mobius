import Foundation
import AeternusCore

// `Settings` collides with SwiftUI's (macOS-only) `Settings` scene and
// `Subscription` with Combine's protocol, so refer to the Core types by alias.
typealias AppSettings = AeternusCore.Settings
typealias ChannelSubscription = AeternusCore.Subscription

/// Lifts a value into an Optional. Lets the UI read Core model fields the same
/// way whether Core declares them optional or not (mirroring the nullable
/// Kotlin models).
@inline(__always)
func optional<T>(_ value: T?) -> T? { value }

/// Converts any integer field (Int, Int64, …) to `Int`, treating negative
/// sentinel values (Piped uses -1 for "unknown") as missing.
func intValue<T: BinaryInteger>(_ value: T?) -> Int? {
    guard let value else { return nil }
    let int = Int(clamping: value)
    return int >= 0 ? int : nil
}

/// Loading state shared by all screens.
enum LoadPhase: Equatable {
    case loading
    case loaded
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

extension Array where Element: Identifiable {
    /// Appends only elements whose id is not present yet (pages can overlap).
    mutating func appendUnique(_ newElements: [Element]) {
        var seen = Set(map(\.id))
        for element in newElements where seen.insert(element.id).inserted {
            append(element)
        }
    }

    func uniqued() -> [Element] {
        var result: [Element] = []
        result.appendUnique(self)
        return result
    }
}

enum TextFormatting {
    /// Piped descriptions and comments are HTML; render them as plain text.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative upload time from a Piped millisecond timestamp, falling back
    /// to Piped's pre-formatted text ("3 days ago").
    static func relativeTime(millis: Int?, fallback: String?) -> String? {
        if let millis, millis > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            return date.formatted(.relative(presentation: .named))
        }
        if let fallback, !fallback.isEmpty { return fallback }
        return nil
    }

    static func views(_ count: Int?) -> String? {
        guard let count else { return nil }
        return "\(Formatters.compactCount(count)) views"
    }
}
