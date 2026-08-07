import Foundation
import Testing
@testable import yuedu_app

@Suite("RuleAutoComplete")
struct RuleAutoCompleteTests {

    // MARK: - Basic completion by type

    @Test("text rule without attribute gets @text appended")
    func plainTextRule() {
        #expect(RuleAutoComplete.autoComplete("a") == "a@text")
    }

    @Test("link rule without attribute gets @href appended")
    func plainLinkRule() {
        #expect(RuleAutoComplete.autoComplete("a", type: .link) == "a@href")
    }

    @Test("image rule without attribute gets @src appended")
    func plainImageRule() {
        #expect(RuleAutoComplete.autoComplete("img", type: .image) == "img@src")
    }

    @Test("already complete rules are left unchanged")
    func alreadyCompleteRules() {
        #expect(RuleAutoComplete.autoComplete("a@href") == "a@href")
        #expect(RuleAutoComplete.autoComplete("a@text") == "a@text")
        #expect(RuleAutoComplete.autoComplete("img@src") == "img@src")
        #expect(RuleAutoComplete.autoComplete("//div//text()") == "//div//text()")
    }

    // MARK: - Separator segments (&& / %% / ||)

    @Test("each && segment completes independently")
    func segmentCompletion() {
        #expect(RuleAutoComplete.autoComplete("a&&b") == "a@text&&b@text")
        #expect(RuleAutoComplete.autoComplete("a%%b", type: .link) == "a@href%%b@href")
        #expect(RuleAutoComplete.autoComplete("a||b", type: .image) == "a@src||b@src")
    }

    @Test("segments with attributes keep them while bare ones complete")
    func mixedSegments() {
        #expect(RuleAutoComplete.autoComplete("a@href&&b") == "a@href&&b@text")
    }

    // MARK: - Complex rules are left alone

    @Test("complex rules (js/json/{{}}) are not completed")
    func complexRulesUntouched() {
        #expect(RuleAutoComplete.autoComplete("@js:return 'a'") == "@js:return 'a'")
        #expect(RuleAutoComplete.autoComplete("{{key}}") == "{{key}}")
        #expect(RuleAutoComplete.autoComplete("<js>return 1</js>") == "<js>return 1</js>")
        #expect(RuleAutoComplete.autoComplete("$.books[0]") == "$.books[0]")
        #expect(RuleAutoComplete.autoComplete(":root") == ":root")
        #expect(RuleAutoComplete.autoComplete("a", preRule: "@js:1") == "a")
    }

    @Test("blank input stays blank")
    func blankInput() {
        #expect(RuleAutoComplete.autoComplete("") == "")
        #expect(RuleAutoComplete.autoComplete(nil) == "")
    }

    // MARK: - Tail split (## regex / ,{ request params)

    @Test("## tail rides along after completion")
    func tailAfterHashHash() {
        #expect(RuleAutoComplete.autoComplete("a##\\d+") == "a@text##\\d+")
    }

    @Test("request-param tail rides along after completion")
    func tailAfterCommaBrace() {
        #expect(RuleAutoComplete.autoComplete("a,{\"webView\": true}") == "a@text,{\"webView\": true}")
    }

    // MARK: - img text → alt fix

    @Test("img@text reads alt text instead")
    func imgTextBecomesAlt() {
        #expect(RuleAutoComplete.autoComplete("img@text") == "img@alt")
    }

    @Test("img class variant keeps its class in the alt fix")
    func imgClassVariant() {
        #expect(RuleAutoComplete.autoComplete("img.cover@text") == "img.cover@alt")
    }

    @Test("img text fix preserves trailing segment separators")
    func imgTextFixPreservesSeq() {
        #expect(RuleAutoComplete.autoComplete("img@text&&a") == "img@alt&&a@text")
    }

    // MARK: - XPath

    @Test("xpath rules use text() / @href / @src")
    func xpathCompletion() {
        #expect(RuleAutoComplete.autoComplete("//div", type: .text) == "//div//text()")
        #expect(RuleAutoComplete.autoComplete("//div", type: .link) == "//div//@href")
        #expect(RuleAutoComplete.autoComplete("//div", type: .image) == "//div//@src")
        #expect(RuleAutoComplete.autoComplete("@Xpath://div") == "@Xpath://div//text()")
    }

    @Test("xpath img text fix keeps the slash")
    func xpathImgTextFix() {
        #expect(RuleAutoComplete.autoComplete("//div/img@text") == "//div/img/@alt")
    }
}
