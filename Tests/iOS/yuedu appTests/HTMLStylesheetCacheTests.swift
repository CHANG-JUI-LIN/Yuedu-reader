import Testing
@testable import yuedu_app

@Suite("HTML stylesheet cache")
struct HTMLStylesheetCacheTests {
    @Test("cached parse results preserve rules and cascade order")
    func cachedParseResultsPreserveRulesAndCascadeOrder() {
        let cache = HTMLStylesheetCache()
        let css = """
        body { color: #111; }
        p:first-letter { font-weight: 700; }
        """

        let first = cache.parsedStylesheet(css: css, orderOffset: 20_000)
        let second = cache.parsedStylesheet(css: css, orderOffset: 20_000)

        #expect(first === second)
        #expect(first.regularRules.count == 1)
        #expect(first.firstLetterRules.count == 1)
        #expect(first.regularRules[0].order == 20_000)
        #expect(first.firstLetterRules[0].order == 20_001)
    }

    @Test("stylesheet order remains part of the cache identity")
    func stylesheetOrderRemainsPartOfCacheIdentity() {
        let cache = HTMLStylesheetCache()
        let css = "p { color: #111; }"

        let first = cache.parsedStylesheet(css: css, orderOffset: 0)
        let second = cache.parsedStylesheet(css: css, orderOffset: 10_000)

        #expect(first !== second)
        #expect(first.regularRules[0].order == 0)
        #expect(second.regularRules[0].order == 10_000)
    }
}
