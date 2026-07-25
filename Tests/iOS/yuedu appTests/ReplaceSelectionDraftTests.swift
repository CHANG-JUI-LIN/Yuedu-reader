import Testing
@testable import yuedu_app

@Suite("Replace selection draft")
struct ReplaceSelectionDraftTests {
    @Test("Selected text creates a literal cleanup rule")
    func createsLiteralCleanupRule() throws {
        let rule = try #require(ReplaceSelectionDraft.makeRule(
            selectedText: "  廣告文字  \n 第二行 ",
            scope: "https://example.com/source"
        ))

        #expect(rule.name.isEmpty)
        #expect(rule.pattern == "廣告文字\n第二行")
        #expect(rule.replacement.isEmpty)
        #expect(rule.isRegex == false)
        #expect(rule.enabled)
        #expect(rule.scope == "https://example.com/source")
    }

    @Test("Whitespace-only selection does not create a rule")
    func ignoresWhitespaceOnlySelection() {
        #expect(ReplaceSelectionDraft.makeRule(selectedText: "  \n  ", scope: "global") == nil)
    }

    @Test("Book-source URL is preferred over the chapter URL for cleanup scope")
    func resolvesBookSourceScope() {
        #expect(ReplaceRuleScope.resolve(
            chapterURL: "https://example.com/book/1/chapter/2",
            bookSourceURL: "https://example.com"
        ) == "https://example.com")
        #expect(ReplaceRuleScope.resolve(
            chapterURL: "https://example.com/book/1/chapter/2",
            bookSourceURL: "  "
        ) == "https://example.com/book/1/chapter/2")
    }
}
