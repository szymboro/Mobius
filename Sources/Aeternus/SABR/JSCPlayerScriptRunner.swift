import Foundation
import JavaScriptCore
import AeternusCore

/// Runs YouTube's player JS (`base.js`) in JavaScriptCore to transform the `n` throttling
/// parameter and ciphered signatures, using the player's own URL builder rather than
/// extracting the individual transform functions.
///
/// One compiled `JSContext` is kept per player id (the ~3 MB script is evaluated once).
/// All JavaScriptCore work happens on a dedicated serial queue, never on the main thread.
public final class JSCPlayerScriptRunner: PlayerScriptRunner, @unchecked Sendable {
    public enum RunnerError: Error, LocalizedError {
        case wrapperNotFound
        case urlBuilderNotFound
        case javaScript(String)
        case unexpectedResult

        public var errorDescription: String? {
            switch self {
            case .wrapperNotFound: "The YouTube player script has an unexpected structure (no _yt_player wrapper)."
            case .urlBuilderNotFound: "Couldn't find the URL builder in the YouTube player script."
            case .javaScript(let message): "YouTube player script error: \(message)"
            case .unexpectedResult: "The YouTube player script returned an unexpected result."
            }
        }
    }

    private struct Compiled {
        let context: JSContext
        let decipher: JSValue
    }

    /// Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "Aeternus.JSCPlayerScriptRunner", qos: .userInitiated)
    private var compiled: [String: Compiled] = [:]
    private var order: [String] = []
    /// Contexts are large (tens of MB); YouTube rotates players rarely, so two is plenty.
    private let maxContexts = 2

    public init() {}

    public func decipher(n: String?, signature: String?, playerId: String, playerScript: String) async throws -> (n: String?, signature: String?) {
        if n == nil && signature == nil { return (nil, nil) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try self.run(n: n, signature: signature, playerId: playerId, playerScript: playerScript)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Queue-confined

    private func run(n: String?, signature: String?, playerId: String, playerScript: String) throws -> (n: String?, signature: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let entry: Compiled
        if let cached = compiled[playerId] {
            entry = cached
        } else {
            entry = try compile(playerScript)
            compiled[playerId] = entry
            order.removeAll { $0 == playerId }
            order.append(playerId)
            while order.count > maxContexts {
                compiled.removeValue(forKey: order.removeFirst())
            }
        }

        var thrown: String?
        entry.context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown exception"
        }
        defer { entry.context.exceptionHandler = nil }

        let args: [Any] = [n ?? NSNull(), signature ?? NSNull()]
        guard let result = entry.decipher.call(withArguments: args) else {
            throw RunnerError.unexpectedResult
        }
        if let thrown {
            // A broken context should not stay cached.
            compiled.removeValue(forKey: playerId)
            order.removeAll { $0 == playerId }
            throw RunnerError.javaScript(thrown)
        }
        guard result.isObject else { throw RunnerError.unexpectedResult }
        return (Self.string(result.forProperty("n")), Self.string(result.forProperty("sig")))
    }

    private static func string(_ value: JSValue?) -> String? {
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        return value.toString()
    }

    private func compile(_ script: String) throws -> Compiled {
        let builderName = try Self.urlBuilderName(in: script)
        let body = try Self.stripWrapper(script)

        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            throw RunnerError.javaScript("couldn't create a JavaScript context")
        }
        context.name = "YouTube player"
        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown exception"
        }

        // Minimal browser surface for base.js's top-level code (no DOM, no network).
        let prelude = """
        var g = {}; globalThis.XMLHttpRequest = { prototype: {} };
        globalThis.location = { href: "https://www.youtube.com/watch?v=x", protocol: "https:", host: "www.youtube.com",
          hostname: "www.youtube.com", origin: "https://www.youtube.com", pathname: "/watch", search: "?v=x", hash: "", port: "" };
        globalThis.document = Object.create(null); globalThis.navigator = Object.create(null);
        globalThis.self = globalThis; globalThis.window = globalThis;

        """
        context.evaluateScript(prelude + body, withSourceURL: URL(string: "https://www.youtube.com/s/player/base.js"))
        if let thrown { throw RunnerError.javaScript(thrown) }

        // builder(url, sp, s) returns the player's URL object; setting `n` and running its
        // first non-trivial prototype method applies the n transform; get(sp) is the signature.
        let wrapper = """
        (function (n, s) {
          var sp = "sig";
          var url = \(builderName)("https://youtube.com/watch?v=x", sp, s == null ? undefined : s);
          if (n != null) url.set("n", n);
          var proto = Object.getPrototypeOf(url);
          var keys = Object.keys(proto).concat(Object.getOwnPropertyNames(proto));
          for (var i = 0; i < keys.length; i++) {
            var key = keys[i];
            if (["constructor", "set", "get", "clone"].indexOf(key) < 0 && typeof url[key] === "function") { url[key](); break; }
          }
          var sig = s == null ? null : url.get(sp);
          return { n: n == null ? null : url.get("n"), sig: sig == null ? null : decodeURIComponent(sig) };
        })
        """
        let function = context.evaluateScript(wrapper)
        if let thrown { throw RunnerError.javaScript(thrown) }
        guard let function, !function.isUndefined, !function.isNull else { throw RunnerError.urlBuilderNotFound }
        context.exceptionHandler = nil
        return Compiled(context: context, decipher: function)
    }

    static func urlBuilderName(in script: String) throws -> String {
        let pattern = #"(\w*)=function\(.*?\)\{[^}]*?set\("alr","yes"\);\w&&"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = script as NSString
        guard let match = regex.firstMatch(in: script, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound
        else { throw RunnerError.urlBuilderNotFound }
        let name = ns.substring(with: match.range(at: 1))
        guard !name.isEmpty else { throw RunnerError.urlBuilderNotFound }
        return name
    }

    /// Removes `var _yt_player={};(function(g){var window=this;` … `})(_yt_player);`
    /// so the player's internals become globals of the context.
    static func stripWrapper(_ script: String) throws -> String {
        let head = "var _yt_player={};(function(g){var window=this;"
        let tail = "})(_yt_player);"
        guard let headRange = script.range(of: head),
              let tailRange = script.range(of: tail, options: .backwards),
              headRange.upperBound <= tailRange.lowerBound
        else { throw RunnerError.wrapperNotFound }
        return String(script[..<headRange.lowerBound])
            + String(script[headRange.upperBound..<tailRange.lowerBound])
            + String(script[tailRange.upperBound...])
    }
}
