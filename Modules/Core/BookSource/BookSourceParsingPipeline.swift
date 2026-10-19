import Foundation

/// Thin routing layer between `BookSourceFetcher` and the rule engine.
///
/// Every method used to build a fresh `ModernParserBridge` (a whole new
/// JSContext + shims + jsLib evaluation) per call; they now share the
/// per-source `BookSourceSession`, so one 詳情→目錄→章節 chain pays the JS
/// runtime cost once. Each call takes the source's turn (`BookSourceSession.withTurn`) and
/// runs on its host, because the bridge carries per-call book/chapter context.
struct BookSourceParsingPipeline {

    // MARK: - Search

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)? = nil
    ) async throws -> [OnlineBook] {
        try await BookSourceSession.session(for: source).withTurn { bridge in
            try bridge.parseSearchResults(
                html: html, baseURL: baseURL, source: source, earlyFilter: earlyFilter
            )
        }
    }

    // MARK: - Book Details

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> OnlineBook {
        try await BookSourceSession.session(for: source).withTurn { bridge in
            try bridge.parseBookInfo(
                html: html, bookUrl: bookUrl, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
    }

    // MARK: - TOC

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> [OnlineChapterRef] {
        try await parseTOCResult(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        ).chapters
    }

    func parseTOCResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> (chapters: [OnlineChapterRef], runtimeVariables: [String: String]?) {
        try await BookSourceSession.session(for: source).withTurn { bridge in
            // Drains SwiftSoup's autoreleased DOM per page.
            try autoreleasepool {
                let chapters = try bridge.parseTOC(
                    html: html, baseURL: baseURL,
                    source: source, runtimeVariables: runtimeVariables
                )
                return (chapters, bridge.lastTOCRuntimeVariables)
            }
        }
    }

    /// One-pass TOC page parse: chapters AND the next-page URL from a single
    /// DOM build (the split calls used to parse the same HTML twice).
    func parseTOCPage(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> (
        chapters: [OnlineChapterRef],
        nextTocURL: String,
        runtimeVariables: [String: String]?
    ) {
        try await BookSourceSession.session(for: source).withTurn { bridge in
            try autoreleasepool {
                let page = try bridge.parseTOCPage(
                    html: html, baseURL: baseURL,
                    source: source, runtimeVariables: runtimeVariables
                )
                return (page.chapters, page.nextTocURL, bridge.lastTOCRuntimeVariables)
            }
        }
    }

    func extractNextTocURL(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async -> String {
        await BookSourceSession.session(for: source).withTurn { bridge in
            bridge.extractNextTocURL(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
    }

    // MARK: - Chapter Content

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        chapterRef: OnlineChapterRef? = nil,
        nextChapterURL: String? = nil
    ) async throws -> ChapterParsePayload {
        try await BookSourceSession.session(for: source).withTurn { bridge in
            try bridge.parseChapterResult(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables,
                chapterRef: chapterRef,
                nextChapterURL: nextChapterURL
            )
        }
    }

    func extractNextContentURLs(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async -> [String] {
        await SourcePerfTrace.spanAsync("chapter.nextContent", source.bookSourceName, thresholdMs: 0) {
            // An absent rule needs no runtime context. Acquiring the shared parse lock
            // first made a completed chapter wait for another chapter's review requests
            // merely to discover that this source has no continuation page.
            guard !source.ruleContent.nextContentUrl.isEmpty else { return [] }
            return await BookSourceSession.session(for: source).withTurn { bridge in
                bridge.extractNextContentURLs(
                    html: html, baseURL: baseURL,
                    source: source, runtimeVariables: runtimeVariables
                )
            }
        }
    }

    // MARK: - loginCheckJs

    /// What `loginCheckJs` left of a response: the status and body the caller goes on with.
    struct CheckedResponse: Sendable {
        let code: Int
        let body: String
    }

    /// Executes Legado `loginCheckJs` against the response to `result` and returns the
    /// original or the source-replaced response after its side effects. The response object
    /// the script sees is built on the host, where it is used.
    func applyLoginCheck(to result: LegadoHTTPResult, source: BookSource) async -> CheckedResponse {
        // Most sources declare no loginCheckJs; skipping the session lookup and its
        // parse lock keeps them off the bridge entirely on the search hot path.
        guard source.hasLoginCheckJs else {
            let response = LegadoStrResponse(result: result)
            return CheckedResponse(code: response.code(), body: response.body())
        }
        return await BookSourceSession.session(for: source).withTurn { bridge in
            let checked = bridge.applyLoginCheck(to: LegadoStrResponse(result: result))
            return CheckedResponse(code: checked.code(), body: checked.body())
        }
    }

    /// `applyLoginCheck(to:)` for a page rendered in a WebView, which has no status to
    /// report: the check sees it as a 200.
    func applyLoginCheck(renderedHTML html: String, url: URL, source: BookSource) async -> String {
        guard source.hasLoginCheckJs else { return html }
        let urlString = url.absoluteString
        return await BookSourceSession.session(for: source).withTurn { bridge in
            bridge.applyLoginCheck(to: LegadoStrResponse(url: urlString, body: html)).body()
        }
    }
}
