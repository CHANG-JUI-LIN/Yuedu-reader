import Testing
import UIKit
@testable import yuedu_app

struct BrowserLayoutFeatureTests {
    @Test func featureIsOffByDefault() {
        #expect(BrowserLayoutFeature.isEnabled == false)
    }
}

struct CSSLengthResolverTests {
    @Test func parsesUnits() throws {
        #expect(CSSLengthResolver.parse("12px") == .px(12))
        #expect(CSSLengthResolver.parse("0") == .px(0))
        #expect(CSSLengthResolver.parse("1.5") == .px(1.5))
        #expect(CSSLengthResolver.parse("50%") == .percent(0.5))
        #expect(CSSLengthResolver.parse("1.5em") == .em(1.5))
        #expect(CSSLengthResolver.parse("2rem") == .rem(2))
        #expect(CSSLengthResolver.parse("auto") == .auto)
        #expect(CSSLengthResolver.parse("12 px") == nil)
        #expect(CSSLengthResolver.parse("calc(100% - 10px)") == nil) // deferred
    }

    @Test func resolvesWithBases() throws {
        let em = try #require(CSSLengthResolver.resolve(.em(2), emBase: 17, remBase: 17, percentBase: 400))
        #expect(em == 34)
        let percent = try #require(CSSLengthResolver.resolve(.percent(0.5), emBase: 17, remBase: 17, percentBase: 400))
        #expect(percent == 200)
        #expect(CSSLengthResolver.resolve(.auto, emBase: 17, remBase: 17, percentBase: 400) == nil)
        #expect(CSSLengthResolver.resolve(.pt(72), emBase: 17, remBase: 17, percentBase: 400) == 96)
    }
}

struct ComputedStyleTests {
    @Test func inheritedCopiesOnlyInheritedFields() {
        let parent = ComputedStyle(
            fontSize: 20, fontFamilies: ["Georgia"], fontWeight: 700, isItalic: true,
            color: .red, textAlign: .center, lineHeight: 30
        )
        let child = parent.inherited(from: parent)
        #expect(child.fontSize == 20)
        #expect(child.fontFamilies == ["Georgia"])
        #expect(child.fontWeight == 700)
        #expect(child.isItalic)
        #expect(child.color == .red)
        #expect(child.textAlign == .center)
        #expect(child.lineHeight == 30)
        #expect(child.backgroundColor == nil)          // not inherited
        #expect(child.marginTop == .px(0))             // box props reset
        #expect(child.width == .auto)
    }

    @Test func uaDefaultsForTags() {
        let p = UserAgentStyle.basis(for: "p")
        #expect(p.display == .block)
        #expect(p.marginTop == .em(1))
        #expect(p.marginBottom == .em(1))
        let span = UserAgentStyle.basis(for: "span")
        #expect(span.display == .inline)
        let head = UserAgentStyle.basis(for: "style")
        #expect(head.display == .none)
        #expect(head.isHidden)
        let h1 = UserAgentStyle.basis(for: "h1")
        #expect(h1.fontSize == 32)
        #expect(h1.fontWeight == 700)
    }
}
