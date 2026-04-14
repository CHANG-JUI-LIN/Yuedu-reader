import Foundation

/// 書源解析管線 — 封裝 HTML/JSON→Model 轉換邏輯，不持有任何網路或快取狀態。
/// 所有方法均為同步呼叫，可由 actor 或非 actor 上下文安全使用。
///
/// When `ParserSettings.useModernParser` is true, routes through
/// `ModernParserBridge`; otherwise uses the legacy `DefaultWebNovelParserService`.
struct BookSourceParsingPipeline {

    // MARK: - 搜尋結果

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource
    ) throws -> [OnlineBook] {
        if ParserSettings.useModernParser {
            let bridge = ModernParserBridge(source: source)
            return try bridge.parseSearchResults(
                html: html, baseURL: baseURL, source: source
            )
        }
        return try DefaultWebNovelParserService.shared.parseSearchResults(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: nil
        )
    }

    // MARK: - 書籍詳情

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> OnlineBook {
        if ParserSettings.useModernParser {
            let bridge = ModernParserBridge(source: source)
            return try bridge.parseBookInfo(
                html: html, bookUrl: bookUrl, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
        return try DefaultWebNovelParserService.shared.parseBookInfo(
            html: html,
            bookUrl: bookUrl,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    // MARK: - 目錄

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> [OnlineChapterRef] {
        if ParserSettings.useModernParser {
            let bridge = ModernParserBridge(source: source)
            return try bridge.parseTOC(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
        return try DefaultWebNovelParserService.shared.parseTOC(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func extractNextTocURL(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> String {
        if ParserSettings.useModernParser {
            let bridge = ModernParserBridge(source: source)
            return bridge.extractNextTocURL(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
        let rule = source.ruleToc.nextTocUrl
        guard !rule.isEmpty else { return "" }
        return (try? DefaultWebNovelParserService.shared.extractSingleValue(
            html: html,
            baseURL: baseURL,
            rule: rule,
            source: source,
            runtimeVariables: runtimeVariables
        )) ?? ""
    }

    // MARK: - 章節正文

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> ChapterParsePayload {
        if ParserSettings.useModernParser {
            let bridge = ModernParserBridge(source: source)
            return try bridge.parseChapterResult(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
        let payload = try DefaultWebNovelParserService.shared.parseChapterPayload(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
        return ChapterParsePayload(
            content: payload.content,
            title: payload.title,
            sourceMatched: payload.sourceMatched,
            isPay: payload.isPay,
            runtimeVariables: payload.runtimeVariables
        )
    }

    func extractNextContentURLs(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> [String] {
        if ParserSettings.useModernParser {
            let bridge = ModernParserBridge(source: source)
            return bridge.extractNextContentURLs(
                html: html, baseURL: baseURL,
                source: source, runtimeVariables: runtimeVariables
            )
        }
        let rule = source.ruleContent.nextContentUrl
        guard !rule.isEmpty else { return [] }
        return (try? DefaultWebNovelParserService.shared.extractStringList(
            html: html,
            baseURL: baseURL,
            rule: rule,
            source: source,
            runtimeVariables: runtimeVariables,
            isURL: true
        )) ?? []
    }
}
