import Foundation
import CryptoKit

/// Resolves a 段評 bubble whose review page only exists once the source's own JS has run.
///
/// Legado's model for an image click-config is simply "evaluate the `click` JS in the source
/// runtime and let the source decide what to open". Most sources open a URL we can derive
/// statically, so `ReaderHTMLUtilities` maps those ahead of time. 同人小说网 cannot be mapped: its
/// `createSvg(bid,cid,pid,count,nano)` builds `…/novel/comment/page?…&token=<user's shared token>`
/// inside jsLib and hands it to `java.showBrowser`. So we run the call and intercept the browser
/// request instead of guessing the URL — which also means a token change takes effect immediately
/// rather than being frozen into a cached chapter.
///
/// Serialized as an actor because resolution installs a `browserPresentHandler` on the source's
/// shared session for the duration of one evaluation; two overlapping taps would otherwise steal
/// each other's handler.
actor LegadoReviewActionRunner {
    static let shared = LegadoReviewActionRunner()

    enum ResolveError: LocalizedError {
        case sourceUnavailable
        case noDestination(sourceName: String)

        var errorDescription: String? {
            switch self {
            case .sourceUnavailable:
                return localized("找不到這則段評所屬的書源，可能已被刪除。")
            case .noDestination(let sourceName):
                return String(
                    format: localized("「%@」沒有回應這則段評，可能需要先在書源設定填寫 Token。"),
                    sourceName
                )
            }
        }
    }

    /// Runs `target.sourceJS` and returns the target with the URL the source asked to open.
    func resolve(
        _ target: ReaderHTMLUtilities.ReviewTarget
    ) async throws -> ReaderHTMLUtilities.ReviewTarget {
        guard target.requiresSourceJS else { return target }
        guard let source = BookSourceStore.shared.sources.first(
            where: { $0.bookSourceUrl == target.sourceURL }
        ) else {
            AppLogger.parse("⟐ reviewAction no source", context: ["sourceURL": target.sourceURL])
            throw ResolveError.sourceUnavailable
        }

        let js = target.sourceJS
        let captured = await Task.detached(priority: .userInitiated) { () -> BrowserRequestSink.Value? in
            let session = BookSourceSession.session(for: source)
            let bridge = session.bridgeForAsyncOperations
            let sink = BrowserRequestSink()
            let previous = bridge.browserPresentHandler
            let previousPage = bridge.browserPagePresentHandler
            bridge.browserPresentHandler = { url, title, completion in
                sink.record(url: url, title: title)
                // `startBrowserAwait` blocks a JS thread on this completion — always call it.
                completion(nil)
            }
            bridge.browserPagePresentHandler = { request in
                sink.record(
                    page: request,
                    sourceURL: source.bookSourceUrl,
                    actionContext: target.actionContext
                )
            }
            defer {
                bridge.browserPresentHandler = previous
                bridge.browserPagePresentHandler = previousPage
            }
            if let actionContext = target.actionContext {
                _ = bridge.evaluateSourceAction(actionContext)
            } else {
                // Compatibility for v1 normalized chapters. Render artifact v3
                // invalidates these on the normal reader path; keep this only for
                // an already-open page during an in-place app update.
                _ = bridge.evaluateSourceScript(js)
            }
            return sink.first
        }.value

        guard let captured else {
            AppLogger.parse("⟐ reviewAction no destination", context: [
                "source": source.bookSourceName,
                "actionHash": Self.actionHash(js)
            ])
            throw ResolveError.noDestination(sourceName: source.bookSourceName)
        }

        AppLogger.parse("⟐ reviewAction resolved", context: [
            "source": source.bookSourceName,
            "actionHash": Self.actionHash(js),
            "host": URL(string: captured.url)?.host ?? "",
            "sourcePage": captured.page == nil ? "no" : "yes"
        ])
        return ReaderHTMLUtilities.ReviewTarget(
            url: captured.url,
            title: captured.title.isEmpty ? target.title : captured.title,
            sourceBrowserPage: captured.page
        )
    }

    private static func actionHash(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Executes one `window.run(...)` request from a source-authored review page in the
    /// same per-source session that produced the chapter and review bubble.
    func runSourcePageScript(
        _ script: String,
        sourceURL: String,
        actionContext: ReaderHTMLUtilities.LegadoSourceActionContext?
    ) throws -> String {
        guard let source = BookSourceStore.shared.sources.first(
            where: { $0.bookSourceUrl == sourceURL }
        ) else {
            throw ResolveError.sourceUnavailable
        }
        let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
        if let actionContext {
            return bridge.evaluateSourceAction(actionContext.replacingScript(script)) ?? ""
        }
        return bridge.evaluateSourceScript(script) ?? ""
    }
}

/// Collects the first browser request a source's JS makes during one evaluation.
/// `browserPresentHandler` is invoked on the JS engine's queue, so access is locked.
private final class BrowserRequestSink: @unchecked Sendable {
    struct Value {
        let url: String
        let title: String
        let page: ReaderHTMLUtilities.ReviewTarget.SourceBrowserPage?
    }

    private let lock = NSLock()
    private var value: Value?

    func record(url: String, title: String) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = Value(url: url, title: title, page: nil) }
    }

    func record(
        page request: LegadoBrowserPageRequest,
        sourceURL: String,
        actionContext: ReaderHTMLUtilities.LegadoSourceActionContext?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return }
        let page = ReaderHTMLUtilities.ReviewTarget.SourceBrowserPage(
            baseURL: request.baseURL,
            html: request.html,
            injectedJavaScript: request.injectedJavaScript,
            configurationJSON: request.configurationJSON,
            sourceURL: sourceURL,
            actionContext: actionContext
        )
        value = Value(url: request.baseURL, title: "", page: page)
    }

    var first: Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
