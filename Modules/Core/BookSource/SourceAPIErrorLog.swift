import Foundation

/// The last failure a book source's own API reported.
///
/// Legado rule JS routinely drops its API's error envelope on the floor:
/// 同人小说网's `requestApiUrl` only raises a toast when the reply carries `msg`,
/// while the server answers `{"error":"无效JWT，你还可尝试21次"}` — so an invite code
/// pasted into 源变量 instead of a Token left the 發現頁 empty and the
/// 「邀请码注册Token」 button visibly dead, with the real reason reaching only the
/// device log. This records what the server actually said, at the points where a
/// source-initiated HTTP response is read:
///
/// - `ModernParserBridge.recordJSNetwork` — every `java.ajax` / `java.ajaxAll` call
/// - `ModernParserBridge.fetch` — search / book info / TOC / content rule URLs
/// - the login sheet's own `analyzeUrlHandler` — 登入選單 button actions
///
/// It is replayed **only where the screen would otherwise stay silent** (an empty
/// 發現頁, a button that produced no message of its own), never in place of
/// content the source did return, so a false positive can never hide real results.
/// In memory only: a failure describes what the API is doing *now*, and a stale
/// one restored after relaunch would misattribute an unrelated empty screen.
final class SourceAPIErrorLog: @unchecked Sendable {

    static let shared = SourceAPIErrorLog()

    struct Failure {
        /// HTTP status of the reply; `nil` for a transport failure or timeout.
        let statusCode: Int?
        /// The server's own words — already bounded and whitespace-collapsed.
        /// `nil` when the reply carried no readable JSON error envelope.
        let message: String?
        /// `host/path` of the request, query stripped. A blocked request often has
        /// an empty body (Cloudflare/WAF answers 403 with `content-length: 0`), and
        /// then the endpoint is the only thing left to report. The query never goes
        /// in: these APIs carry the user's token in it.
        let endpoint: String?

        /// Single line fit for a `Text` — e.g.
        /// `HTTP 403 · www.trxs666.com/user/invite · 无效JWT，你还可尝试21次`.
        var displayText: String {
            var parts = [statusCode.map { "HTTP \($0)" } ?? localized("連線失敗")]
            if let endpoint, !endpoint.isEmpty { parts.append(endpoint) }
            if let message, !message.isEmpty { parts.append(message) }
            return parts.joined(separator: " · ")
        }
    }

    private var failures: [String: Failure] = [:]
    private let queue = DispatchQueue(label: "com.yuedu.sourceAPIErrorLog")

    private init() {}

    // MARK: - Recording

    /// Record the outcome of one source-initiated request.
    ///
    /// A healthy reply **clears** the stored failure: "last failure" has to mean
    /// "this source's API is failing right now", otherwise a long-gone error would
    /// be blamed for an empty screen that has some other cause.
    func record(
        sourceUrl: String, requestUrl: String? = nil,
        statusCode: Int?, body: String?, timedOut: Bool = false
    ) {
        guard !sourceUrl.isEmpty else { return }
        let endpoint = Self.endpoint(of: requestUrl)
        let failure: Failure?
        if timedOut {
            failure = Failure(
                statusCode: nil, message: localized("連線逾時"), endpoint: endpoint)
        } else if let statusCode, (200..<300).contains(statusCode) {
            // A 2xx still counts as a failure when the body IS an error envelope:
            // these aggregator APIs answer `{"error":"访问被拒绝"}` with HTTP 200.
            failure = Self.errorEnvelopeMessage(body).map {
                Failure(statusCode: statusCode, message: $0, endpoint: endpoint)
            }
        } else {
            failure = Failure(
                statusCode: statusCode,
                message: Self.errorEnvelopeMessage(body),
                endpoint: endpoint
            )
        }
        queue.sync {
            if let failure {
                failures[sourceUrl] = failure
            } else {
                failures.removeValue(forKey: sourceUrl)
            }
        }
    }

    // MARK: - Reading

    func last(for sourceUrl: String) -> Failure? {
        queue.sync { failures[sourceUrl] }
    }

    func clear(for sourceUrl: String) {
        queue.sync { _ = failures.removeValue(forKey: sourceUrl) }
    }

    /// `host/path` of a request URL — never the query, which carries the token.
    private static func endpoint(of requestUrl: String?) -> String? {
        guard let requestUrl, let components = URLComponents(string: requestUrl),
              let host = components.host else { return nil }
        return host + components.path
    }

    // MARK: - Error envelope

    /// Keys an API uses to say *this went wrong*.
    ///
    /// `msg` / `message` are deliberately absent: sources carry success text in
    /// them too (同人小说网's own check is `res.msg != 'success'`), so reading them
    /// as errors would label healthy replies as failures.
    private static let errorKeys = ["error", "errmsg", "errorMsg", "err_msg", "error_msg"]

    /// The message a JSON error envelope carries, or `nil` when the body is not one.
    ///
    /// Anything that is not a small JSON object — HTML error pages, real payloads —
    /// yields `nil` and the HTTP status alone becomes the whole message. That keeps
    /// unbounded, source-controlled markup out of SwiftUI layout, and keeps this off
    /// the hot path: chapter and book-list bodies are far past the size cap, so they
    /// never reach `JSONSerialization`.
    static func errorEnvelopeMessage(_ body: String?) -> String? {
        // `utf8.count` (O(1)) not `count` (O(n)): this runs on every response,
        // including multi-megabyte chapter bodies.
        guard let body, body.utf8.count <= 4096,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in errorKeys {
            guard let text = object[key] as? String else { continue }
            let sanitized = Self.sanitized(text)
            if !sanitized.isEmpty { return sanitized }
        }
        return nil
    }

    /// Collapse the server's text to one bounded line before it reaches a `Text`.
    private static func sanitized(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count <= 200 ? collapsed : String(collapsed.prefix(200)) + "…"
    }
}
