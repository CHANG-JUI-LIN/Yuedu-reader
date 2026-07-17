import Foundation

/// Book source parsing pipeline — encapsulates HTML/JSON→Model conversion logic with no network or cache state.
/// All methods are synchronous and safe to use from actor or non-actor contexts.
struct BookSourceParsingPipeline {

    // MARK: - Search Results

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil
    ) throws -> [OnlineBook] {
        let bridge = ModernParserBridge(source: source)
        return try bridge.parseSearchResults(
            html: html, baseURL: baseURL, source: source, earlyFilter: earlyFilter
        )
    }

    // MARK: - Book Details

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> OnlineBook {
        let bridge = ModernParserBridge(source: source)
        return try bridge.parseBookInfo(
            html: html, bookUrl: bookUrl, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
        )
    }

    // MARK: - TOC

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> [OnlineChapterRef] {
        let bridge = ModernParserBridge(source: source)
        return try bridge.parseTOC(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
        )
    }

    func extractNextTocURL(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> String {
        let bridge = ModernParserBridge(source: source)
        return bridge.extractNextTocURL(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
        )
    }

    // MARK: - Chapter Content

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        chapterRef: OnlineChapterRef? = nil
    ) throws -> ChapterParsePayload {
        let bridge = ModernParserBridge(source: source)
        return try bridge.parseChapterResult(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables,
            chapterRef: chapterRef
        )
    }

    func extractNextContentURLs(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> [String] {
        let bridge = ModernParserBridge(source: source)
        return bridge.extractNextContentURLs(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
        )
    }

    // MARK: - loginCheckJs

    /// Evaluate `loginCheckJs` against the raw HTML using JSCoreEngine.
    /// Returns `true` when the rule signals that a login is required.
    func checkLoginRequired(
        html: String,
        baseURL: String,
        source: BookSource
    ) -> Bool {
        let bridge = ModernParserBridge(source: source)
        return bridge.checkLoginRequired(html: html, baseURL: baseURL)
    }
}
