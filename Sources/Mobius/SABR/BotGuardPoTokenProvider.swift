import Foundation
import MobiusCore
import UIKit
import WebKit

/// Mints BotGuard PO tokens in an offscreen `WKWebView`.
///
/// Port of LibreTube Android's `PoTokenWebView` / `PoTokenGenerator` / `po_token.html`:
/// 1. load the BotGuard helper page with base URL https://www.youtube.com,
/// 2. fetch the challenge (`jnn/v1/Create`), descramble it and run the BotGuard VM in the page,
/// 3. exchange the VM's response for an integrity token (`jnn/v1/GenerateIT`),
/// 4. mint a PO token per identifier with the page's minter until the integrity token expires.
///
/// The network calls are made natively with `URLSession`, as on Android.
public final class BotGuardPoTokenProvider: PoTokenProvider, Sendable {
    public init() {}

    public func poToken(for identifier: String) async throws -> String {
        try await BotGuardMinter.shared.poToken(for: identifier)
    }
}

public struct BotGuardError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { "PO token generation failed: \(message)" }
}

/// Owns the current BotGuard web view and its expiry. Main-actor confined.
@MainActor
final class BotGuardMinter {
    static let shared = BotGuardMinter()

    private var generator: BotGuardWebView?
    private var creation: Task<BotGuardWebView, Error>?

    func poToken(for identifier: String) async throws -> String {
        let (current, isNew) = try await generator(forceRecreate: false)
        do {
            return try await current.mint(identifier: identifier)
        } catch {
            guard !isNew else { throw error }
            // The page may have been torn down (e.g. the web content process was killed in the
            // background); retry once with a fresh one.
            let (fresh, _) = try await generator(forceRecreate: true)
            return try await fresh.mint(identifier: identifier)
        }
    }

    private func generator(forceRecreate: Bool) async throws -> (BotGuardWebView, Bool) {
        if !forceRecreate, let generator, !generator.isExpired {
            return (generator, false)
        }
        if let creation {
            // Someone is already creating one; share it.
            return (try await creation.value, true)
        }
        generator?.close()
        generator = nil
        let task = Task { @MainActor in try await BotGuardWebView.make() }
        creation = task
        defer { creation = nil }
        let made = try await task.value
        generator = made
        return (made, true)
    }
}

/// One loaded BotGuard page plus its integrity token.
@MainActor
final class BotGuardWebView: NSObject, WKNavigationDelegate {
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let googleAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let createURL = URL(string: "https://www.youtube.com/api/jnn/v1/Create")!
    private static let generateITURL = URL(string: "https://www.youtube.com/api/jnn/v1/GenerateIT")!
    private static let timeout: Duration = .seconds(45)

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var pendingScripts: [UUID: CheckedContinuation<String?, Error>] = [:]
    private var timedOut = false
    private var expiration = Date.distantPast
    private var isClosed = false

    var isExpired: Bool { isClosed || Date() >= expiration }

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
    }

    /// Mobile Safari's user agent for this iOS version; also sent with the native requests.
    static var userAgent: String {
        let version = UIDevice.current.systemVersion
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        let major = version.split(separator: ".").first.map(String.init) ?? "17"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    static func make() async throws -> BotGuardWebView {
        let view = BotGuardWebView()
        // WebKit's JS calls don't observe task cancellation, so a timeout closes the view,
        // which fails every pending continuation.
        let watchdog = Task { @MainActor [weak view] in
            try await Task.sleep(for: timeout)
            view?.timedOut = true
            view?.close()
        }
        defer { watchdog.cancel() }
        do {
            try await view.initialize()
            return view
        } catch {
            let timedOut = view.timedOut
            view.close()
            if timedOut { throw BotGuardError("timed out after \(timeout)") }
            throw error
        }
    }

    private func initialize() async throws {
        attachToWindow()

        // 1. Load the helper page. didFinish fires after the load event, i.e. after the
        //    synchronous <script> in <head> has defined every function.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(Self.html, baseURL: URL(string: "https://www.youtube.com")!)
        }
        let ready = try await evaluate(
            "return typeof runBotGuard === 'function' && typeof parseChallenge === 'function';",
            arguments: [:]
        )
        guard ready == "true" else { throw BotGuardError("BotGuard page didn't load") }

        // 2. Challenge → BotGuard VM → botguardResponse (webPoSignalOutput stays in the page).
        let challenge = try await Self.botguardRequest(Self.createURL, payload: [Self.requestKey])
        guard let challengeJSON = String(data: challenge, encoding: .utf8) else {
            throw BotGuardError("unreadable challenge")
        }
        let response = try await evaluate("""
            const result = await runBotGuard(parseChallenge(JSON.parse(raw)));
            window.webPoSignalOutput = result.webPoSignalOutput;
            return String(result.botguardResponse);
            """, arguments: ["raw": challengeJSON])
        guard let botguardResponse = response, !botguardResponse.isEmpty else {
            throw BotGuardError("BotGuard returned no response")
        }

        // 3. botguardResponse → integrity token + lifetime.
        let itData = try await Self.botguardRequest(Self.generateITURL, payload: [Self.requestKey, botguardResponse])
        guard let array = try? JSONSerialization.jsonObject(with: itData) as? [Any],
              let integrityToken = array.first as? String
        else {
            throw BotGuardError("unexpected GenerateIT response: \(String(decoding: itData.prefix(200), as: UTF8.self))")
        }
        let rawTTL: Any = array.count > 1 ? array[1] : 0
        let ttl: Double = switch rawTTL {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string) ?? 0
        default: 0
        }
        guard !isClosed else { throw BotGuardError("generator closed") }
        _ = try await evaluate("window.integrityToken = b64ToBytes(token); return true;", arguments: ["token": integrityToken])
        // Leave 10 minutes of margin, as Android does.
        expiration = Date().addingTimeInterval(max(ttl - 600, 0))
        if ttl <= 600 {
            // Unknown/short lifetime: still usable now, but don't cache it for long.
            expiration = Date().addingTimeInterval(60)
        }
    }

    func mint(identifier: String) async throws -> String {
        guard !isClosed else { throw BotGuardError("generator closed") }
        let value = try await evaluate("""
            return bytesToB64url(obtainPoToken(window.webPoSignalOutput, window.integrityToken, new TextEncoder().encode(identifier)));
            """, arguments: ["identifier": identifier])
        guard let token = value, !token.isEmpty else {
            throw BotGuardError("minter returned no token")
        }
        return token
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        loadContinuation?.resume(throwing: BotGuardError("closed"))
        loadContinuation = nil
        let pending = pendingScripts
        pendingScripts = [:]
        for continuation in pending.values {
            continuation.resume(throwing: BotGuardError("closed"))
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    // MARK: Helpers

    /// `callAsyncJavaScript` awaiting the returned promise. Pending calls fail when the view closes.
    /// Results are converted to strings (booleans as "true"/"false") so they can cross the continuation.
    private func evaluate(_ body: String, arguments: [String: Any]) async throws -> String? {
        guard !isClosed else { throw BotGuardError("generator closed") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            pendingScripts[id] = continuation
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let continuation = self?.pendingScripts.removeValue(forKey: id) else { return }
                    switch result {
                    case .success(let value):
                        let text: String? = switch value {
                        case let string as String: string
                        case let bool as Bool: bool ? "true" : "false"
                        case is NSNull: nil
                        default: String(describing: value)
                        }
                        continuation.resume(returning: text)
                    case .failure(let error):
                        let ns = error as NSError
                        let jsMessage = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
                        continuation.resume(throwing: BotGuardError(jsMessage ?? ns.localizedDescription))
                    }
                }
            }
        }
    }

    /// WebKit may throttle or suspend timers in a web view that isn't in a window; BotGuard
    /// polls with setInterval, so keep it in the view hierarchy as an invisible 1×1 view.
    private func attachToWindow() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
        if let window, webView.superview == nil {
            window.insertSubview(webView, at: 0)
        }
    }

    private static func botguardRequest(_ url: URL, payload: [String]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(googleAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BotGuardError("\(url.lastPathComponent) HTTP \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return data
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: BotGuardError("page load failed: \(error.localizedDescription)"))
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: BotGuardError("page load failed: \(error.localizedDescription)"))
        loadContinuation = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The minter state is gone; force recreation on next use.
        expiration = .distantPast
        loadContinuation?.resume(throwing: BotGuardError("web content process terminated"))
        loadContinuation = nil
    }

    // MARK: Page

    /// `po_token.html` from Android plus the challenge parsing / base64 helpers that Android
    /// does in Kotlin (JavaScriptUtil.kt).
    static let html = #"""
    <!DOCTYPE html>
    <html lang="en"><head><title></title><script>
    function loadBotGuard(challengeData) {
      this.vm = this[challengeData.globalName];
      this.program = challengeData.program;
      this.vmFunctions = {};
      this.syncSnapshotFunction = null;
      if (!this.vm)
        throw new Error('[BotGuardClient]: VM not found in the global object');
      if (!this.vm.a)
        throw new Error('[BotGuardClient]: Could not load program');
      const vmFunctionsCallback = function (asyncSnapshotFunction, shutdownFunction, passEventFunction, checkCameraFunction) {
        this.vmFunctions = {
          asyncSnapshotFunction: asyncSnapshotFunction,
          shutdownFunction: shutdownFunction,
          passEventFunction: passEventFunction,
          checkCameraFunction: checkCameraFunction
        };
      };
      this.syncSnapshotFunction = this.vm.a(this.program, vmFunctionsCallback, true, this.userInteractionElement, function () {}, [ [], [] ])[0];
      return new Promise(function (resolve, reject) {
        var i = 0;
        var refreshIntervalId = setInterval(function () {
          if (!!this.vmFunctions.asyncSnapshotFunction) {
            resolve(this);
            clearInterval(refreshIntervalId);
          }
          if (i >= 10000) {
            reject("asyncSnapshotFunction is null even after 10 seconds");
            clearInterval(refreshIntervalId);
          }
          i += 1;
        }, 1);
      });
    }

    function snapshot(args) {
      return new Promise(function (resolve, reject) {
        if (!this.vmFunctions.asyncSnapshotFunction)
          return reject(new Error('[BotGuardClient]: Async snapshot function not found'));
        this.vmFunctions.asyncSnapshotFunction(function (response) { resolve(response) }, [
          args.contentBinding,
          args.signedTimestamp,
          args.webPoSignalOutput,
          args.skipPrivacyBuffer
        ]);
      });
    }

    function runBotGuard(challengeData) {
      const interpreterJavascript = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
      if (interpreterJavascript) {
        new Function(interpreterJavascript)();
      } else throw new Error('Could not load VM');
      const webPoSignalOutput = [];
      return loadBotGuard({
        globalName: challengeData.globalName,
        globalObj: this,
        program: challengeData.program
      }).then(function (botguard) {
        return botguard.snapshot({ webPoSignalOutput: webPoSignalOutput });
      }).then(function (botguardResponse) {
        return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
      });
    }

    function obtainPoToken(webPoSignalOutput, integrityToken, identifier) {
      const getMinter = webPoSignalOutput[0];
      if (!getMinter)
        throw new Error('PMD:Undefined');
      const mintCallback = getMinter(integrityToken);
      if (!(mintCallback instanceof Function))
        throw new Error('APF:Failed');
      const result = mintCallback(identifier);
      if (!result)
        throw new Error('YNJ:Undefined');
      if (!(result instanceof Uint8Array))
        throw new Error('ODM:Invalid');
      return result;
    }

    function b64ToBytes(s) {
      s = s.replace(/-/g, '+').replace(/_/g, '/').replace(/\./g, '=');
      const bin = atob(s);
      const u = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
      return u;
    }

    function bytesToB64url(u) {
      let s = '';
      for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
      return btoa(s).replace(/\+/g, '-').replace(/\//g, '_');
    }

    // Create's response is either [challenge, ...] or [?, "<scrambled base64>"], where every
    // byte of the scrambled form is the JSON byte minus 97.
    function parseChallenge(raw) {
      let c;
      if (raw.length > 1 && typeof raw[1] === 'string') {
        const b = b64ToBytes(raw[1]);
        c = JSON.parse(new TextDecoder().decode(b.map(function (x) { return (x + 97) & 255; })));
      } else c = raw[0];
      const str = function (a) { return a ? a.find(function (x) { return typeof x === 'string'; }) : null; };
      return {
        messageId: c[0],
        interpreterJavascript: {
          privateDoNotAccessOrElseSafeScriptWrappedValue: str(c[1]),
          privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: str(c[2])
        },
        interpreterHash: c[3],
        program: c[4],
        globalName: c[5],
        clientExperimentsStateBlob: c[7]
      };
    }
    </script></head><body></body></html>
    """#
}
