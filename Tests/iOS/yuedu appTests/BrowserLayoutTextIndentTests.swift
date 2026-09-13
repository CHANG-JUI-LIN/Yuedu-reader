@testable import YueduCoreText
import Testing
import UIKit
import SwiftSoup
@testable import yuedu_app

@MainActor
@Suite("BrowserLayout CSS text-indent", .serialized)
struct BrowserLayoutTextIndentTests {
    private static let viewport = CGSize(width: 390, height: 844)
    private static let insets = UIEdgeInsets(top: 18, left: 16, bottom: 22, right: 16)

    private struct Fixture {
        let pipeline: BrowserLayoutDocument.BrowserLayoutPipelineResult
        let pages: [PageFragments]
    }

    @Test func parserAcceptsSupportedSingleTokenSubset() {
        #expect(CSSTextIndent.parse("-1px") == .length(.px(-1)))
        #expect(CSSTextIndent.parse("-0.1em") == .length(.em(-0.1)))
        #expect(CSSTextIndent.parse("12pt") == .length(.pt(12)))
        #expect(CSSTextIndent.parse("0") == .length(.px(0)))
        #expect(CSSTextIndent.parse("0px") == .length(.px(0)))
        #expect(CSSTextIndent.parse("0em") == .length(.em(0)))
        #expect(CSSTextIndent.parse("20px") == .length(.px(20)))
        #expect(CSSTextIndent.parse("1em") == .length(.em(1)))
        #expect(CSSTextIndent.parse("2rem") == .length(.rem(2)))
        #expect(CSSTextIndent.parse("10%") == .length(.percent(0.1)))
        #expect(CSSTextIndent.parse("  2EM  ") == .length(.em(2)))
    }

    @Test func parserRejectsOutsideSubset() {
        for value in [
            "hanging", "each-line",
            "2em hanging", "calc(100% - 1em)", "min(2em, 10%)",
            "max(1em, 12px)", "clamp(1em, 2em, 3em)",
            "2", "auto", "inherit", "bogus",
        ] {
            #expect(CSSTextIndent.parse(value) == .unsupported, "value=\(value)")
        }
    }

    @Test func textIndentIsInheritedAndChildZeroOverrides() throws {
        let tree = try styleTree(
            html: """
            <html><body><div class="parent">
              <p class="inherit">a</p><p class="zero">b</p>
            </div></body></html>
            """,
            css: [".parent { text-indent:2em } .zero { text-indent:0 }"]
        )
        #expect(node(class: "parent", in: tree)?.style.textIndent == .length(.px(BrowserLayoutConfig().rootFontSize * 2)))
        #expect(node(class: "inherit", in: tree)?.style.textIndent == .length(.px(BrowserLayoutConfig().rootFontSize * 2)))
        #expect(node(class: "zero", in: tree)?.style.textIndent == .length(.px(0)))
    }

    @Test func authorCascadeReplacesInsteadOfAddingIndent() throws {
        let tree = try styleTree(
            html: """
            <html><body><p class="x" style="text-indent:20px">x</p></body></html>
            """,
            css: ["body { text-indent:2em } p.x { text-indent:1em }"]
        )
        #expect(node(class: "x", in: tree)?.style.textIndent == .length(.px(20)))
    }

    @Test func resolvesEmPxPercentAndZeroAgainstOwningInlineSize() throws {
        let cases: [(value: String, expected: CGFloat)] = [
            ("2em", 40),
            ("1em", 20),
            ("20px", 20),
            ("10%", 20),
            ("0", 0),
        ]
        for item in cases {
            let value = try fixture(
                body: "<p class='target'>A paragraph with enough words to render a line.</p>",
                css: ".target { width:200px; margin:0; padding:0; text-indent:\(item.value) }"
            )
            let line = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines.first)
            #expect(abs(line.contentX - item.expected) < 0.01, "value=\(item.value)")
        }
    }

    @Test func onlyFirstFormattedLineIsIndented() throws {
        let prose = String(repeating: "first line constraint wraps ordinary prose ", count: 8)
        let value = try fixture(
            body: "<p class='target'>\(prose)</p>",
            css: ".target { width:210px; margin:0; line-height:24px; text-indent:2em }"
        )
        let lines = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines)
        #expect(lines.count >= 2)
        #expect(abs(lines[0].contentX - 40) < 0.01)
        #expect(abs(lines[1].contentX) < 0.01)
    }

    @Test func indentChangesTheFirstBreakWithoutChangingSourceOrder() throws {
        let prose = String(repeating: "earlier line break keeps source ranges monotonic ", count: 6)
        let zero = try fixture(
            body: "<p class='target'>\(prose)</p>",
            css: ".target { width:230px; margin:0; line-height:24px; text-indent:0 }"
        )
        let indented = try fixture(
            body: "<p class='target'>\(prose)</p>",
            css: ".target { width:230px; margin:0; line-height:24px; text-indent:40px }"
        )
        let zeroLine = try #require(box(class: "target", in: zero.pipeline.rootBox)?.lines.first)
        let indentedLine = try #require(box(class: "target", in: indented.pipeline.rootBox)?.lines.first)
        #expect(lineSourceEnd(indentedLine) < lineSourceEnd(zeroLine))
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(indented.pages))
        #expect(
            BrowserLayoutTestSupport.visibleText(indented.pages, sourceText: indented.pipeline.sourceText)
                == BrowserLayoutTestSupport.visibleText(zero.pages, sourceText: zero.pipeline.sourceText)
        )
    }

    @Test func inheritedIndentAndChildZeroAffectActualLines() throws {
        let value = try fixture(
            body: "<div class='parent'><p class='inherit'>inherited first line</p><p class='zero'>zero first line</p></div>",
            css: ".parent { text-indent:2em } p { margin:0 } .zero { text-indent:0 }"
        )
        let inherited = try #require(box(class: "inherit", in: value.pipeline.rootBox)?.lines.first)
        let zero = try #require(box(class: "zero", in: value.pipeline.rootBox)?.lines.first)
        #expect(abs(inherited.contentX - 40) < 0.01)
        #expect(abs(zero.contentX) < 0.01)
    }

    @Test func anonymousGroupsConsumeOuterFirstLineExactlyOnce() throws {
        let value = try fixture(
            body: "<div class='outer'>prefix text<div class='inner'>nested text</div>suffix text</div>",
            css: ".outer { margin:0; text-indent:20px } .inner { margin:0 }"
        )
        let outer = try #require(box(class: "outer", in: value.pipeline.rootBox))
        let inlineBoxes = allBoxes(outer).filter { !$0.inlineRuns.isEmpty }
        #expect(inlineBoxes.count == 3)
        #expect(inlineBoxes.filter { $0.ownsFirstFormattedLine }.count == 2)

        let prefix = try #require(inlineBoxes.first {
            if case .anonymous = $0.boxType { return true }
            return false
        })
        let nested = try #require(inlineBoxes.first { $0.debugClasses.contains("inner") })
        let suffix = try #require(inlineBoxes.first { $0 === outer })
        #expect(prefix.ownsFirstFormattedLine)
        #expect(nested.ownsFirstFormattedLine)
        #expect(!suffix.ownsFirstFormattedLine)
        #expect(abs(try #require(prefix.lines.first).contentX - 20) < 0.01)
        #expect(abs(try #require(nested.lines.first).contentX - 20) < 0.01)
        #expect(abs(try #require(suffix.lines.first).contentX) < 0.01)
    }

    @Test func oversizedPositiveIndentPreservesOriginAndMakesProgress() throws {
        let prose = "Oversized indent still emits every source unit in order."
        let value = try fixture(
            body: "<p class='target'>\(prose)</p>",
            css: ".target { margin:0; text-indent:500px }"
        )
        let lines = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines)
        let first = try #require(lines.first)
        #expect(abs(first.contentX - 500) < 0.01)
        #expect(!first.runs.isEmpty)
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(value.pages))
        #expect(
            BrowserLayoutTestSupport.visibleText(value.pages, sourceText: value.pipeline.sourceText)
                == prose
        )
    }

    @Test func firstLineConstraintComposesAfterFloatInterval() {
        let base = InlineInterval(
            lineX: 120,
            lineWidth: 272,
            leftIntrusion: 120,
            rightIntrusion: 0
        )
        let final = InlineFirstLineConstraint(textIndent: 34).apply(to: base)
        #expect(final.lineX == 154)
        #expect(final.lineWidth == 238)
        #expect(final.leftIntrusion == 120)
        #expect(final.rightIntrusion == 0)
    }

    @Test func linkOnFirstLineUsesIndentedDisplayAndHitGeometry() throws {
        let value = try fixture(
            body: "<p class='target'><a href='note.xhtml#n1'>linked first-line phrase</a> and suffix</p>",
            css: ".target { width:230px; margin:0; line-height:24px; text-indent:20px }"
        )
        let line = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines.first)
        #expect(abs(line.contentX - 20) < 0.01)

        let page = try #require(value.pages.first)
        let regions = LinkInteractionRegionSet.build(
            from: DisplayListBuilder.build(for: page, sourceText: value.pipeline.sourceText),
            spineIndex: 0,
            anchors: value.pipeline.linkAnchors
        )
        let link = try #require(regions.regions.first)
        #expect(link.pageLocalRect.minX >= Self.insets.left + 20 - 0.01)
        #expect(regions.hitTest(CGPoint(x: link.pageLocalRect.midX, y: link.pageLocalRect.midY)) != nil)
        let expected = (value.pipeline.sourceText as NSString).range(of: "linked first-line phrase")
        #expect(NSIntersectionRange(link.sourceRange, expected).length > 0)
    }

    @Test func rubyOnFirstLineRemainsAtomicAndMapsAnnotationToBase() throws {
        let value = try fixture(
            body: "<p class='target'><ruby><span>漢字</span><rt>かんじ</rt></ruby> follows ruby</p>",
            css: ".target { width:180px; margin:0; line-height:30px; text-indent:20px } ruby { ruby-align:center; ruby-position:over }"
        )
        let first = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines.first)
        #expect(abs(first.contentX - 20) < 0.01)
        let rubyRuns = first.runs.filter { $0.ruby != nil }
        #expect(rubyRuns.count == 1)
        #expect(rubyRuns.first?.shapedRange?.length == 1)

        let fragments = BrowserLayoutTestSupport.allTextFragments(value.pages)
        let annotation = try #require(fragments.first { $0.renderedTextOverride == "かんじ" })
        #expect(annotation.sourceMapping == .wholeRange)
        #expect(annotation.sourceRange == rubyRuns[0].sourceRange)
        #expect(
            BrowserLayoutTestSupport.visibleText(value.pages, sourceText: value.pipeline.sourceText)
                == "漢字 follows ruby"
        )
    }

    @Test func inlineImageOnFirstLineUsesSameIndentedLineAndLinkMapping() throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 40, height: 24),
            color: .red
        )
        let value = try fixture(
            body: "<p class='target'><a href='image.xhtml'><img src='fixture.png'/></a> image suffix text</p>",
            css: ".target { width:150px; margin:0; line-height:28px; text-indent:30px } img { width:40px; height:24px }",
            imageLoader: { $0 == "fixture.png" ? image : nil }
        )
        let first = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines.first)
        #expect(abs(first.contentX - 30) < 0.01)
        #expect(first.runs.first?.atomic != nil)

        let imageFragment = try #require(BrowserLayoutTestSupport.allImageFragments(value.pages).first)
        #expect(imageFragment.rect.minX >= Self.insets.left + 30 - 0.01)
        #expect(imageFragment.linkTarget == "image.xhtml")
        let page = try #require(value.pages.first)
        let regions = LinkInteractionRegionSet.build(
            from: DisplayListBuilder.build(for: page, sourceText: value.pipeline.sourceText),
            spineIndex: 0,
            anchors: value.pipeline.linkAnchors
        )
        #expect(regions.regions.contains { $0.kind == .image && $0.href == "image.xhtml" })
    }

    @Test func leftFloatIntervalThenIndentAffectsOnlyFirstLine() throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 100, height: 70),
            color: .blue
        )
        let prose = String(repeating: "left float interval composition ", count: 14)
        let value = try fixture(
            body: "<div class='flow'><img class='float' src='float.png'/><p class='target'>\(prose)</p></div>",
            css: ".flow, .target { margin:0 } .float { float:left; width:100px; height:70px; margin:0 } .target { line-height:20px; text-indent:34px }",
            imageLoader: { $0 == "float.png" ? image : nil }
        )
        let lines = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines)
        #expect(lines.count >= 4)
        #expect(abs(lines[0].contentX - 134) < 0.01)
        #expect(abs(lines[1].contentX - 100) < 0.01)
        #expect(lines.contains { $0.top >= 70 && abs($0.contentX) < 0.01 })
    }

    @Test func rightFloatWidthThenIndentUsesOneIntervalPipeline() throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 100, height: 70),
            color: .green
        )
        let prose = String(
            repeating: "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥天地玄黃宇宙洪荒",
            count: 8
        )
        let zero = try fixture(
            body: "<div class='flow'><img class='float' src='float.png'/><p class='target'>\(prose)</p></div>",
            css: ".flow, .target { margin:0 } .float { float:right; width:100px; height:70px; margin:0 } .target { line-height:20px; text-indent:0 }",
            imageLoader: { $0 == "float.png" ? image : nil }
        )
        let value = try fixture(
            body: "<div class='flow'><img class='float' src='float.png'/><p class='target'>\(prose)</p></div>",
            css: ".flow, .target { margin:0 } .float { float:right; width:100px; height:70px; margin:0 } .target { line-height:20px; text-indent:34px }",
            imageLoader: { $0 == "float.png" ? image : nil }
        )
        let zeroLines = try #require(box(class: "target", in: zero.pipeline.rootBox)?.lines)
        let lines = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines)
        #expect(lines.count >= 4)
        #expect(abs(lines[0].contentX - 34) < 0.01)
        #expect(abs(lines[1].contentX) < 0.01)
        #expect(lineSourceEnd(lines[0]) < lineSourceEnd(zeroLines[0]))
        #expect(lines.contains { $0.top >= 70 && abs($0.contentX) < 0.01 })
    }

    @Test func indentedParagraphSpansPagesWithMonotonicMappingAndSelection() throws {
        let prose = String(repeating: "pagination source mapping remains exact across every page. ", count: 120)
        let zero = try fixture(
            body: "<p class='target'>\(prose)</p>",
            css: ".target { width:230px; margin:0; line-height:24px; text-indent:0 }"
        )
        let value = try fixture(
            body: "<p class='target'>\(prose)</p>",
            css: ".target { width:230px; margin:0; line-height:24px; text-indent:40px }"
        )
        #expect(value.pages.count >= 2)
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(value.pages))
        #expect(
            BrowserLayoutTestSupport.visibleText(value.pages, sourceText: value.pipeline.sourceText)
                == BrowserLayoutTestSupport.visibleText(zero.pages, sourceText: zero.pipeline.sourceText)
        )

        let pageRanges = BrowserChapterLayout.buildPageRanges(
            value.pages,
            sourceText: value.pipeline.sourceText
        )
        #expect(pageRanges.count == value.pages.count)
        #expect(zip(pageRanges, pageRanges.dropFirst()).allSatisfy { lhs, rhs in
            lhs.location <= rhs.location && NSMaxRange(lhs) <= NSMaxRange(rhs)
        })

        let pageOneText = try #require(textFragments(in: value.pages[1]).first {
            $0.sourceRange.length > 0 && $0.sourceMapping != .wholeRange
        })
        let selection = NSRange(location: pageOneText.sourceRange.location, length: 1)
        let selectionRows = BrowserLayoutGeometryFingerprint.snapshot(
            pipeline: value.pipeline,
            pages: value.pages,
            selectionRange: selection
        ).canonicalRows.filter { $0.hasPrefix("selection|") }
        #expect(!selectionRows.isEmpty)
        #expect(selectionRows.allSatisfy { $0.hasPrefix("selection|1|") })
    }

    @Test func hangingIsRejectedByDocumentAdmission() {
        #expect(throws: BrowserLayoutDocument.BrowserLayoutError.self) {
            _ = try fixture(
                body: "<p class='target'>unsupported</p>",
                css: ".target { text-indent:hanging }"
            )
        }
    }

    @Test func eachLineIsRejectedByDocumentAdmission() {
        #expect(throws: BrowserLayoutDocument.BrowserLayoutError.self) {
            _ = try fixture(
                body: "<p class='target'>unsupported</p>",
                css: ".target { text-indent:each-line }"
            )
        }
    }

    @Test func negativeIndentPreservesTheFirstLineOrigin() throws {
        let value = try fixture(
            body: "<p class='target'>A negative first-line indent remains supported.</p>",
            css: ".target { text-indent:-1px; margin:0 }"
        )
        let line = try #require(box(class: "target", in: value.pipeline.rootBox)?.lines.first)
        #expect(abs(line.contentX + 1) < 0.01)
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(value.pages))
    }

    @Test func nonZeroIndentUsesTheVerticalInlineAxis() throws {
        let contentWidth = Self.viewport.width - Self.insets.left - Self.insets.right
        let contentHeight = Self.viewport.height - Self.insets.top - Self.insets.bottom
        var config = BrowserLayoutConfig(
            renderWidth: contentWidth,
            renderHeight: contentHeight,
            rootFontSize: 20,
            fontFamilies: ["Helvetica"],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: Self.insets
        )
        config.writingMode = .verticalRTL
        let document = BrowserLayoutDocument(
            html: "<html><body><p>直排首行縮排沿用邏輯行內座標</p></body></html>",
            cssTexts: ["p { text-indent:20px }"],
            config: config
        )
        let result = try document.makeLayout(containerSize: Self.viewport)
        let paragraph = try #require(allBoxes(result.rootBox).first { !$0.lines.isEmpty })
        #expect(abs(try #require(paragraph.lines.first).contentX - 20) < 0.01)
    }

    @Test func repeatedIndentFloatRubyLayoutIsDeterministic() throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 70, height: 55),
            color: .purple
        )
        let body = "<div class='flow'><img class='float' src='float.png'/><p class='target'><ruby>漢<rt>かん</rt></ruby> deterministic text around a float.</p></div>"
        let css = ".flow, .target { margin:0 } .float { float:left; width:70px; height:55px; margin:0 } .target { line-height:28px; text-indent:20px } ruby { ruby-align:center; ruby-position:over }"
        let first = try fixture(
            body: body,
            css: css,
            imageLoader: { $0 == "float.png" ? image : nil }
        )
        let second = try fixture(
            body: body,
            css: css,
            imageLoader: { $0 == "float.png" ? image : nil }
        )
        #expect(
            BrowserLayoutGeometryFingerprint.snapshot(
                pipeline: first.pipeline,
                pages: first.pages
            ) == BrowserLayoutGeometryFingerprint.snapshot(
                pipeline: second.pipeline,
                pages: second.pages
            )
        )
    }

    private func styleTree(html: String, css: [String]) throws -> ComputedStyleNode {
        var metrics = LayoutMetrics()
        return try LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: BrowserLayoutConfig(),
            metrics: &metrics
        ).rootNode
    }

    private func fixture(
        body: String,
        css: String,
        imageLoader: ((String) -> UIImage?)? = nil
    ) throws -> Fixture {
        let contentWidth = Self.viewport.width - Self.insets.left - Self.insets.right
        let contentHeight = Self.viewport.height - Self.insets.top - Self.insets.bottom
        let config = BrowserLayoutConfig(
            renderWidth: contentWidth,
            renderHeight: contentHeight,
            rootFontSize: 20,
            fontFamilies: ["Helvetica"],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: Self.insets
        )
        let document = BrowserLayoutDocument(
            html: "<html><body>\(body)</body></html>",
            cssTexts: ["html, body { margin:0; padding:0 } \(css)"],
            config: config,
            imageLoader: imageLoader
        )
        let pipeline = try document.makeLayout(
            containerSize: Self.viewport,
            fragmentHeight: contentHeight
        )
        let pages = PageFragmentation.fragment(
            box: pipeline.rootBox,
            pageSize: Self.viewport,
            contentInsets: Self.insets
        )
        return Fixture(pipeline: pipeline, pages: pages)
    }

    private func allBoxes(_ root: BlockBox) -> [BlockBox] {
        [root] + root.children.flatMap(allBoxes)
    }

    private func box(class className: String, in root: BlockBox) -> BlockBox? {
        allBoxes(root).first { $0.debugClasses.contains(className) }
    }

    private func lineSourceEnd(_ line: LayoutLine) -> Int {
        line.runs.map { NSMaxRange($0.sourceRange) }.max() ?? 0
    }

    private func textFragments(in page: PageFragments) -> [TextFragment] {
        func collect(_ fragments: [Fragment]) -> [TextFragment] {
            fragments.flatMap { fragment in
                switch fragment {
                case .text(let text): return [text]
                case .group(let children): return collect(children)
                default: return []
                }
            }
        }
        return collect(page.fragments)
    }

    private func node(class className: String, in root: ComputedStyleNode) -> ComputedStyleNode? {
        let classes = root.element.flatMap { try? $0.classNames() } ?? []
        if classes.contains(className) { return root }
        for child in root.children {
            guard case .element(let childNode) = child else { continue }
            if let match = node(class: className, in: childNode) { return match }
        }
        return nil
    }
}
