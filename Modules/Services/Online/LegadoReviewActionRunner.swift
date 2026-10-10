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
                return localized("找不到這則段評所屬的來源配置，可能已被刪除。")
            case .noDestination(let sourceName):
                return String(
                    format: localized("「%@」沒有回應這則段評，可能需要先在來源配置設定填寫 Token。"),
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

        return try await resolve(target, source: source)
    }

    /// Source-explicit entry point also keeps isolated fixtures out of the user's source store.
    func resolve(
        _ target: ReaderHTMLUtilities.ReviewTarget,
        source: BookSource
    ) async throws -> ReaderHTMLUtilities.ReviewTarget {
        guard target.requiresSourceJS else { return target }
        guard target.sourceURL == source.bookSourceUrl else { throw ResolveError.sourceUnavailable }
        let js = target.sourceJS
        let captured = await SourceScriptThread.run { () -> BrowserRequestSink.Value? in
            let session = BookSourceSession.session(for: source)
            let bridge = session.bridgeForAsyncOperations
            let sink = BrowserRequestSink()
            let previous = bridge.browserPresentHandler
            let previousPage = bridge.browserPagePresentHandler
            bridge.browserPresentHandler = { request, completion in
                sink.record(url: request.url, title: request.title)
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
                // Compatibility for v1 normalized chapters. Render artifact v4
                // invalidates these on the normal reader path; keep this only for
                // an already-open page during an in-place app update.
                _ = bridge.evaluateSourceScript(js)
            }
            guard var captured = sink.first else { return nil }
            // A plain URL, or a source page that names its URL without HTML, is loaded from the
            // network: with the source's headers and cookies, as legado's `AnalyzeUrl` does.
            if captured.page == nil || captured.page?.html == nil {
                captured.request = bridge.sourceBrowserRequest(urlString: captured.url)
            }
            return captured
        }

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
            sourceURL: source.bookSourceUrl,
            sourceBrowserPage: captured.page,
            browserRequest: captured.request
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
    ) async throws -> String {
        guard let source = BookSourceStore.shared.sources.first(
            where: { $0.bookSourceUrl == sourceURL }
        ) else {
            throw ResolveError.sourceUnavailable
        }
        let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
        return await SourceScriptThread.run {
            if let actionContext {
                return bridge.evaluateSourceAction(actionContext.replacingScript(script)) ?? ""
            }
            return bridge.evaluateSourceScript(script) ?? ""
        }
    }
}

/// Collects the first browser request a source's JS makes during one evaluation.
/// `browserPresentHandler` is invoked on the JS engine's queue, so access is locked.
private final class BrowserRequestSink: @unchecked Sendable {
    struct Value {
        let url: String
        let title: String
        let page: ReaderHTMLUtilities.ReviewTarget.SourceBrowserPage?
        var request: URLRequest? = nil
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

// MARK: - 簡介 buttons and images

/// What a 簡介 button's or image's script did that the book detail page has to show.
struct BookIntroActionOutcome: Sendable {
    /// A page the script built itself with `java.showBrowser(url, html, js, config)`, shown
    /// the way the reader shows a 段評 page.
    var page: ReaderHTMLUtilities.ReviewTarget?
    /// The script called `java.refreshBookInfo()` or `java.refreshBookToc()`.
    var refreshesBook = false
    /// The script threw. Legado toasts `<name> click error` with this message.
    var errorMessage: String?
}

extension ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot {
    /// The book as a detail page knows it, for a 簡介 script's `book`. Reading progress and
    /// type come from the book's runtime variables when its source recorded them.
    static func detailPage(
        name: String,
        author: String,
        coverURL: String,
        bookURL: String,
        tocURL: String,
        intro: String,
        runtimeVariables: [String: String]
    ) -> Self {
        Self(
            durChapterIndex: Int(runtimeVariables["book.durChapterIndex"] ?? "") ?? 0,
            durChapterTitle: runtimeVariables["book.durChapterTitle"] ?? "",
            order: Int(runtimeVariables["book.order"] ?? "") ?? 0,
            type: Int(runtimeVariables["book.type"] ?? "") ?? 0,
            imageStyle: runtimeVariables["book.imageStyle"] ?? "",
            name: name,
            author: author,
            coverURL: coverURL,
            bookURL: bookURL,
            tocURL: tocURL,
            abstract: intro
        )
    }
}

extension LegadoReviewActionRunner {
    /// Legado's `BookInfoViewModel.onButtonClick` (legado-E) and `runIntroJs` (MD3): runs a
    /// 簡介 button's or image's script in the book's source with `book` bound and no
    /// `result`, under the extensions Legado's login pages get (`SourceLoginJsExtensions`).
    ///
    /// Pages the script opens are shown as it asks: `startBrowser` and the two-argument
    /// `showBrowser` through the shared presenter, a source-built page as the outcome's
    /// `page`. Toasts go to `presentToast` as they happen — 光遇聚合's 书籍讨论 toasts
    /// 「初始化…请稍等」 before a slow `java.ajax`, which must not wait for the script.
    func runIntroAction(
        _ action: BookIntroAction,
        book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot,
        runtimeVariables: [String: String],
        source: BookSource,
        presentToast: @escaping @MainActor (String) -> Void
    ) async -> BookIntroActionOutcome {
        let run = await runBookScript(
            action.script,
            displayName: action.displayName,
            result: "",
            extraBindings: [:],
            book: book,
            chapter: nil,
            runtimeVariables: runtimeVariables,
            source: source,
            presentToast: presentToast
        )
        let outcome = run.outcome
        AppLogger.parse("⟐ introAction", context: [
            "source": source.bookSourceName,
            "kind": action.kind == .button ? "button" : "image",
            "actionHash": Self.actionHash(action.script),
            "page": outcome.page == nil ? "no" : "yes",
            "refresh": outcome.refreshesBook ? "yes" : "no",
            "error": outcome.errorMessage ?? "none"
        ])
        return outcome
    }

    /// legado-E / MD3 `SourceCallBack`: runs the source's `ruleContent.callBackJs` with `event`,
    /// `result`, `book` and `chapter` bound, under the same extensions a 簡介 script gets
    /// (toasts, browser pages) — legado hands button events its login-page `java`.
    ///
    /// `handled` follows legado's `String.isTrue()`: anything but blank, `null`, `false`, `no`,
    /// `not`, `0` or `0.0` means the script took the tap over. legado's Rhino unwraps a script
    /// that returns nothing (`undefined`) to `null`, which `toString()`s to "null" — not handled,
    /// so the app's own action runs; our engine reports `undefined` and `null` alike as nil,
    /// read the same way. A script that throws is logged and, as in legado, neither counts as
    /// handled nor triggers the fallback.
    func runCallBack(
        _ event: SourceCallBackEvent,
        source: BookSource,
        book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot,
        chapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot?,
        result: String?,
        runtimeVariables: [String: String],
        presentToast: @escaping @MainActor (String) -> Void
    ) async -> SourceCallBackOutcome {
        guard let script = source.ruleContent.callBackJs, !script.isEmpty else {
            return SourceCallBackOutcome(handled: false, failed: false, page: nil, value: nil)
        }
        let run = await runBookScript(
            script,
            displayName: source.bookSourceName,
            result: result ?? "",
            extraBindings: ["event": event.rawValue],
            book: book,
            chapter: chapter,
            runtimeVariables: runtimeVariables,
            source: source,
            presentToast: presentToast
        )
        let failed = run.outcome.errorMessage != nil
        let handled = !failed && Self.legadoIsTrue(run.value, nilIsTrue: false)
        AppLogger.parse("⟐ callBackJs", context: [
            "source": source.bookSourceName,
            "event": event.rawValue,
            "value": String((run.value ?? "<undefined>").prefix(40)),
            "handled": handled ? "yes" : "no",
            "error": run.outcome.errorMessage ?? "none"
        ])
        if let error = run.outcome.errorMessage {
            AppLogger.error("Source callBackJs failed", context: [
                "source": source.bookSourceName, "event": event.rawValue, "error": error,
            ])
        }
        return SourceCallBackOutcome(handled: handled, failed: failed, page: run.outcome.page, value: run.value)
    }

    /// legado `String?.isTrue(nullIsTrue)`.
    static func legadoIsTrue(_ value: String?, nilIsTrue: Bool) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value != "null" else {
            return nilIsTrue
        }
        let falsy: Set<String> = ["false", "no", "not", "0", "0.0"]
        return !falsy.contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// One book-scoped source script (簡介 button or image, `callBackJs`), on the source's
    /// shared session with the 簡介 extensions installed for its duration.
    private func runBookScript(
        _ script: String,
        displayName: String,
        result: String,
        extraBindings: [String: String],
        book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot,
        chapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot?,
        runtimeVariables: [String: String],
        source: BookSource,
        presentToast: @escaping @MainActor (String) -> Void
    ) async -> (outcome: BookIntroActionOutcome, value: String?) {
        let context = ReaderHTMLUtilities.LegadoSourceActionContext(
            version: ReaderHTMLUtilities.LegadoSourceActionContext.currentVersion,
            sourceURL: source.bookSourceUrl,
            script: script,
            result: result,
            // Legado's `BaseSource.evalJS` binds `baseUrl` to the source's key.
            baseURL: source.bookSourceUrl,
            runtimeVariables: runtimeVariables,
            book: book,
            chapter: chapter ?? .init(
                index: book.durChapterIndex,
                title: book.durChapterTitle,
                order: book.order,
                url: "",
                isVip: false
            )
        )
        return await SourceScriptThread.run { () -> (outcome: BookIntroActionOutcome, value: String?) in
            let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
            let sink = IntroActionSink()
            let previousBrowser = bridge.browserPresentHandler
            let previousPage = bridge.browserPagePresentHandler
            let previousToast = bridge.toastHandler
            let previousRefreshInfo = bridge.refreshBookInfoHandler
            let previousRefreshToc = bridge.refreshBookTocHandler
            // `startBrowser` reaches the shared presenter on its own; the two-argument
            // `showBrowser` shows a page only where the host installs a presenter.
            bridge.browserPresentHandler = LegadoJSBridge.sharedBrowserPresenter
            bridge.browserPagePresentHandler = { [weak bridge] request in
                sink.record(page: ReaderHTMLUtilities.ReviewTarget(
                    url: request.baseURL,
                    title: displayName,
                    sourceURL: source.bookSourceUrl,
                    sourceBrowserPage: .init(
                        baseURL: request.baseURL,
                        html: request.html,
                        injectedJavaScript: request.injectedJavaScript,
                        configurationJSON: request.configurationJSON,
                        sourceURL: source.bookSourceUrl,
                        actionContext: context
                    ),
                    // No HTML: the page is the URL, requested with the source's headers.
                    browserRequest: request.html == nil
                        ? bridge?.sourceBrowserRequest(urlString: request.baseURL) : nil
                ))
            }
            // The bridge delivers toasts on the main queue.
            bridge.toastHandler = { message in
                MainActor.assumeIsolated { presentToast(message) }
            }
            bridge.refreshBookInfoHandler = { sink.markRefresh() }
            bridge.refreshBookTocHandler = { sink.markRefresh() }
            defer {
                bridge.browserPresentHandler = previousBrowser
                bridge.browserPagePresentHandler = previousPage
                bridge.toastHandler = previousToast
                bridge.refreshBookInfoHandler = previousRefreshInfo
                bridge.refreshBookTocHandler = previousRefreshToc
            }
            let value = bridge.evaluateSourceAction(context, extraBindings: extraBindings)
            return (
                BookIntroActionOutcome(
                    page: sink.page,
                    refreshesBook: sink.refreshes,
                    errorMessage: bridge.lastSourceScriptError
                ),
                value
            )
        }
    }
}

/// What a source's `callBackJs` did with one event.
struct SourceCallBackOutcome: Sendable {
    /// The script took the tap over (legado `isTrue`); the app skips its own action.
    var handled: Bool
    /// The script threw; logged. legado neither treats this as handled nor falls back.
    var failed: Bool
    /// A page the script built with the four-argument `java.showBrowser`.
    var page: ReaderHTMLUtilities.ReviewTarget?
    /// What the script returned, for the log and tests; nil for `undefined`/`null`.
    var value: String? = nil
}

/// Collects what one 簡介 script asked of the detail page. The bridge calls in from the
/// JS engine's queue, so access is locked.
private final class IntroActionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPage: ReaderHTMLUtilities.ReviewTarget?
    private var refreshRequested = false

    func record(page: ReaderHTMLUtilities.ReviewTarget) {
        lock.lock()
        defer { lock.unlock() }
        if recordedPage == nil { recordedPage = page }
    }

    func markRefresh() {
        lock.lock()
        defer { lock.unlock() }
        refreshRequested = true
    }

    var page: ReaderHTMLUtilities.ReviewTarget? {
        lock.lock()
        defer { lock.unlock() }
        return recordedPage
    }

    var refreshes: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refreshRequested
    }
}
