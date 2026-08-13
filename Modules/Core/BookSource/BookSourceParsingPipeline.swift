import Foundation

/// Thin routing layer between `BookSourceFetcher` and the rule engine.
///
/// Every method used to build a fresh `ModernParserBridge` (a whole new
/// JSContext + shims + jsLib evaluation) per call; they now share the
/// per-source `BookSourceSession`, so one 詳情→目錄→章節 chain pays the JS
/// runtime cost once. `withBridge` serializes same-source parses (the bridge
/// carries per-call book/chapter context).
struct BookSourceParsingPipeline {

    // MARK: - Search

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil
    ) throws -> [OnlineBook] {
        try BookSourceSession.session(for: source).withBridge { bridge in
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
    ) throws -> OnlineBook {
        try BookSourceSession.session(for: source).withBridge { bridge in
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
    ) throws -> [OnlineChapterRef] {
        try parseTOCResult(
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
    ) throws -> (chapters: [OnlineChapterRef], runtimeVariables: [String: String]?) {
        try BookSourceSession.session(for: source).withBridge { bridge in
            let chapters = try bridge.parseTOC(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
            return (chapters, bridge.lastTOCRuntimeVariables)
        }
    }

    /// One-pass TOC page parse: chapters AND the next-page URL from a single
    /// DOM build (the split calls used to parse the same HTML twice).
    func parseTOCPage(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> (
        chapters: [OnlineChapterRef],
        nextTocURL: String,
        runtimeVariables: [String: String]?
    ) {
        try BookSourceSession.session(for: source).withBridge { bridge in
            let page = try bridge.parseTOCPage(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
            return (page.chapters, page.nextTocURL, bridge.lastTOCRuntimeVariables)
        }
    }

    func extractNextTocURL(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> String {
        BookSourceSession.session(for: source).withBridge { bridge in
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
    ) throws -> ChapterParsePayload {
        try BookSourceSession.session(for: source).withBridge { bridge in
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
    ) -> [String] {
        BookSourceSession.session(for: source).withBridge { bridge in
            bridge.extractNextContentURLs(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
    }

    // MARK: - loginCheckJs

    /// Evaluate `loginCheckJs` against the raw HTML using JSCoreEngine.
    /// Returns `true` when the rule signals that a login is required.
    func checkLoginRequired(
        html: String,
        baseURL: String,
        source: BookSource
    ) -> Bool {
        // Most sources declare no loginCheckJs; skipping the session lookup and its
        // parse lock keeps them off the bridge entirely on the search hot path.
        guard !source.loginCheckJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return BookSourceSession.session(for: source).withBridge { bridge in
            bridge.checkLoginRequired(html: html, baseURL: baseURL)
        }
    }
}
