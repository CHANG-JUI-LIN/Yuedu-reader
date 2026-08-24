import Testing
import UIKit
@testable import yuedu_app

struct BrowserLayoutRubySubsetTests {
    private func tree(
        _ body: String,
        css: [String] = [],
        writingMode: ReaderWritingMode = .horizontal
    ) throws -> ComputedStyleNode {
        var metrics = LayoutMetrics()
        return try LegacyCSSFrontend().buildStyleTree(
            html: "<html><body>\(body)</body></html>",
            cssTexts: css,
            config: BrowserLayoutConfig(writingMode: writingMode),
            metrics: &metrics
        ).rootNode
    }

    @Test func acceptsCensusRubyShapes() throws {
        for body in [
            "<p><ruby>漢<rt>かん</rt></ruby></p>",
            "<p><ruby><span>漢字</span><rt>かんじ</rt></ruby></p>",
            "<p><ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby></p>",
        ] {
            let root = try tree(body)
            #expect(HorizontalRubySupport.validate(root).isSupported)
        }
    }

    @Test func resolvesRubyComputedValuesThroughCascade() throws {
        let root = try tree(
            "<p><ruby class='r'>漢<rt>かん</rt></ruby></p>",
            css: ["ruby.r { ruby-align:center; ruby-position:over }"]
        )
        let ruby = try #require(HorizontalRubySupport.rubyNodes(in: root).first)
        #expect(ruby.style.rubyAlign == .center)
        #expect(ruby.style.rubyPosition == .over)
        let rt = try #require(ruby.children.compactMap(\.rubyElement).first { $0.tag == "rt" })
        #expect(abs(rt.style.fontSize - ruby.style.fontSize * 0.5) < 0.01)
    }

    @Test func rejectsRubyOutsidePhase4DSubset() throws {
        let rejected = [
            "<p><ruby>漢</ruby></p>",
            "<p><ruby>漢<rt>a</rt><rt>b</rt></ruby></p>",
            "<p><ruby><rb>漢</rb><rt>a</rt></ruby></p>",
            "<p><ruby>漢<rtc><rt>a</rt></rtc></ruby></p>",
            "<p><ruby>外<ruby>內<rt>n</rt></ruby><rt>w</rt></ruby></p>",
            "<p><ruby><span style='display:block'>漢</span><rt>a</rt></ruby></p>",
        ]
        for body in rejected {
            let root = try tree(body)
            #expect(!HorizontalRubySupport.validate(root).isSupported)
        }
        let verticalRoot = try tree(
            "<p><ruby>漢<rt>a</rt></ruby></p>",
            writingMode: .verticalRTL
        )
        #expect(!HorizontalRubySupport.validate(
            verticalRoot,
            writingMode: .verticalRTL
        ).isSupported)
    }

    @Test func rejectsUnsupportedRubyCSSValues() throws {
        for css in [
            "ruby { ruby-align:start }",
            "ruby { ruby-align:space-between }",
            "ruby { ruby-position:under }",
            "ruby { ruby-position:inter-character }",
            "ruby { -epub-ruby-position:under }",
            "ruby { ruby-merge:collapse }",
        ] {
            let root = try tree("<p><ruby>漢<rt>a</rt></ruby></p>", css: [css])
            #expect(!HorizontalRubySupport.validate(root).isSupported)
        }
    }
}

private extension StyleTreeChild {
    var rubyElement: ComputedStyleNode? {
        guard case .element(let node) = self else { return nil }
        return node
    }
}
