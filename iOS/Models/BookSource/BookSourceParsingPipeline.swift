import Foundation

/// 書源解析管線 — 封裝 HTML/JSON→Model 轉換邏輯，不持有任何網路或快取狀態。
/// 所有方法均為同步呼叫，可由 actor 或非 actor 上下文安全使用。
struct BookSourceParsingPipeline {

    // MARK: - 搜尋結果

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource
    ) throws -> [OnlineBook] {
        let bridge = ModernParserBridge(source: source)
        return try bridge.parseSearchResults(html: html, baseURL: baseURL, source: source)
    }

    // MARK: - 書籍詳情

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

    // MARK: - 目錄

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

    // MARK: - 章節正文

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> ChapterParsePayload {
        let bridge = ModernParserBridge(source: source)
        return try bridge.parseChapterResult(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
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
