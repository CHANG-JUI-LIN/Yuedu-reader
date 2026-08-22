import Foundation
import Testing
@testable import yuedu_app

/// `::first-letter` is how EPUBs actually spell a drop cap — the CSS3 two-colon form
/// is what the spec prescribes for pseudo-elements, and CSS2's single colon only
/// survives for compatibility. The parser matched the suffix but then cut the
/// selector at `lastIndex(of: ":")`, which for the two-colon form lands *between* the
/// colons and leaves `p:` behind. `parseComponent` rejects a leftover colon, so the
/// rule was discarded and the drop cap silently never rendered.
@Suite("CSS :first-letter selectors")
struct CSSFirstLetterSelectorTests {

    private func parse(_ css: String) -> (regular: [CSSRule], firstLetter: [CSSRule]) {
        CSSParser.parseWithFirstLetter(css: css, orderOffset: 0)
    }

    @Test("the CSS3 two-colon spelling is recognised")
    func doubleColonIsParsed() {
        let parsed = parse("p::first-letter { font-size: 3em; }")
        #expect(parsed.firstLetter.count == 1)
        #expect(parsed.regular.isEmpty)
    }

    @Test("the CSS2 single-colon spelling still works")
    func singleColonStillWorks() {
        let parsed = parse("p:first-letter { font-size: 3em; }")
        #expect(parsed.firstLetter.count == 1)
        #expect(parsed.regular.isEmpty)
    }

    /// Both spellings must resolve to the same element selector, or the drop cap would
    /// land on different paragraphs depending on how the book spelled it.
    @Test("both spellings resolve to the same element")
    func bothSpellingsAgree() {
        let single = parse("p:first-letter { font-size: 3em; }").firstLetter
        let double = parse("p::first-letter { font-size: 3em; }").firstLetter
        #expect(single.count == 1)
        #expect(double.count == 1)
        // `CSSSelector` is not Equatable; its structural description is, and two
        // identical structs print identically.
        #expect(
            single.first.map { String(describing: $0.selector) }
                == double.first.map { String(describing: $0.selector) }
        )
    }

    @Test("pseudo-element case does not matter")
    func caseInsensitive() {
        #expect(parse("p::FIRST-LETTER { font-size: 3em; }").firstLetter.count == 1)
        #expect(parse("P:First-Letter { font-size: 3em; }").firstLetter.count == 1)
    }

    @Test("class and descendant selectors keep working with either spelling")
    func compoundSelectors() {
        #expect(parse(".verse::first-letter { color: red; }").firstLetter.count == 1)
        #expect(parse("div.chapter p::first-letter { color: red; }").firstLetter.count == 1)
    }

    @Test("a selector list splits into one rule per selector")
    func selectorLists() {
        let parsed = parse("p::first-letter, .verse:first-letter { font-size: 2em; }")
        #expect(parsed.firstLetter.count == 2)
    }

    /// The universal selector is not supported by `parseComponent` at all, so a bare
    /// pseudo-element has no element to attach to and is still dropped. Recorded so the
    /// behaviour is deliberate rather than accidental.
    @Test("a bare pseudo-element has no element to attach to")
    func barePseudoElementIsDropped() {
        #expect(parse("::first-letter { font-size: 3em; }").firstLetter.isEmpty)
    }

    @Test("ordinary rules are untouched")
    func ordinaryRulesUnaffected() {
        let parsed = parse("p { margin: 0; } h1 { font-size: 2em; }")
        #expect(parsed.regular.count == 2)
        #expect(parsed.firstLetter.isEmpty)
    }

    /// Other pseudo-elements stay unsupported and dropped rather than being misapplied
    /// to the bare element — `p::before` content must not restyle every `p`.
    @Test("unsupported pseudo-elements are dropped, not misapplied")
    func otherPseudoElementsAreDropped() {
        let parsed = parse("p::before { content: 'x'; color: red; }")
        #expect(parsed.regular.isEmpty)
        #expect(parsed.firstLetter.isEmpty)
    }
}
