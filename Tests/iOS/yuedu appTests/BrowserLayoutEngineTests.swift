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
