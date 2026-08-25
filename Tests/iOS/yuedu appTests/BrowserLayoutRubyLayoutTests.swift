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
            "<p><ruby>漢<rt><span>かん</span></rt></ruby></p>",
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
            "<p><ruby>漢<rt><span style='display:block'>a</span></rt></ruby></p>",
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

struct BrowserLayoutRubyUnitTests {
    private func pipeline(_ body: String, css: [String] = []) throws
        -> BrowserLayoutDocument.BrowserLayoutPipelineResult {
        let doc = BrowserLayoutDocument(
            html: "<html><body>\(body)</body></html>",
            cssTexts: css,
            config: BrowserLayoutConfig(renderWidth: 300, renderHeight: 400)
        )
        return try doc.makeLayout(containerSize: CGSize(width: 300, height: 400))
    }

    @Test func sourceTextContainsBaseButNotAnnotationOrRP() throws {
        let result = try pipeline("<p>甲<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>乙</p>")
        #expect(result.sourceText == "甲漢乙")
        let units = BrowserLayoutRubyTestProbe.rubyUnits(in: result.rootBox)
        let unit = try #require(units.only)
        #expect(unit.base.map(\.text).joined() == "漢")
        #expect(unit.annotation.text == "かん")
        #expect((result.sourceText as NSString).substring(with: unit.sourceRange) == "漢")
    }

    @Test func inlineDescendantBaseRetainsStyleNodeAndRange() throws {
        let result = try pipeline(
            "<p><a href='note.xhtml'><ruby><span class='b'>漢字</span><rt>かんじ</rt></ruby></a></p>",
            css: ["span.b { font-weight:700 }"]
        )
        let unit = try #require(BrowserLayoutRubyTestProbe.rubyUnits(in: result.rootBox).only)
        let piece = try #require(unit.base.only)
        #expect(piece.text == "漢字")
        #expect(piece.style.fontWeight == 700)
        #expect(piece.nodeID > 0)
        #expect(piece.linkTarget == "note.xhtml")
        #expect(unit.linkTarget == "note.xhtml")
    }

    @Test func rubyAnchorMapsToBaseStart() throws {
        let result = try pipeline("<p>前<ruby id='r'>漢<rt>かん</rt></ruby>後</p>")
        #expect(result.anchorOffsets["r"] == 1)
    }

    @Test func inlineAnnotationDescendantRetainsStylePieces() throws {
        let result = try pipeline(
            "<p><ruby>漢<rt>a<a href='note.xhtml'><span class='annotation'>b</span></a></rt></ruby></p>",
            css: ["span.annotation { font-weight:700 }"]
        )
        let box = try #require(BrowserLayoutRubyTestProbe.rubyBoxes(in: result.rootBox).only)
        #expect(box.annotation.pieces.map(\.text) == ["a", "b"])
        #expect(box.annotation.pieces[1].style.fontWeight == 700)
        #expect(box.annotation.pieces[0].nodeID != box.annotation.pieces[1].nodeID)
        #expect(box.annotation.pieces[1].linkTarget == "note.xhtml")
        #expect(box.annotation.pieces.allSatisfy { $0.sourceRange == box.unit.sourceRange })
        let pages = PageFragmentation.fragment(
            box: result.rootBox,
            pageSize: CGSize(width: 300, height: 400)
        )
        let linkedAnnotation = BrowserLayoutTestSupport.allTextFragments(pages).first {
            $0.renderedTextOverride == "b"
        }
        #expect(linkedAnnotation?.linkTarget == "note.xhtml")
    }
}

struct BrowserLayoutRubyMeasurementTests {
    private func pipeline(_ body: String, width: CGFloat = 300) throws
        -> BrowserLayoutDocument.BrowserLayoutPipelineResult {
        let doc = BrowserLayoutDocument(
            html: "<html><body><p style='margin:0'>\(body)</p></body></html>",
            cssTexts: [],
            config: BrowserLayoutConfig(renderWidth: width, renderHeight: 400)
        )
        return try doc.makeLayout(containerSize: CGSize(width: width, height: 400))
    }

    @Test func rubyAdvanceContainsWiderSideAndCentersBoth() throws {
        for body in [
            "<ruby>漢字<rt>a</rt></ruby>",
            "<ruby>字<rt>long annotation</rt></ruby>",
        ] {
            let result = try pipeline(body)
            let box = try #require(BrowserLayoutRubyTestProbe.rubyBoxes(in: result.rootBox).only)
            #expect(abs(box.advance - max(box.base.width, box.annotation.width)) < 0.01)
            #expect(abs(box.baseOffsetX - (box.advance - box.base.width) / 2) < 0.01)
            #expect(abs(box.annotationOffsetX - (box.advance - box.annotation.width) / 2) < 0.01)
        }
    }

    @Test func annotationIncreasesAscentAndStaysAboveBase() throws {
        let ruby = try pipeline("<ruby>漢<rt>かん</rt></ruby>")
        let plain = try pipeline("漢")
        let rubyLine = try #require(BrowserLayoutRubyTestProbe.lines(in: ruby.rootBox).only)
        let plainLine = try #require(BrowserLayoutRubyTestProbe.lines(in: plain.rootBox).only)
        let box = try #require(rubyLine.runs.compactMap(\.ruby).only)
        #expect(rubyLine.ascent > plainLine.ascent)
        #expect(box.annotationBaselineOffset + box.annotation.descent <= -box.base.ascent + 0.01)
        #expect(box.descent == box.base.descent)
    }

    @Test func lineBreakerNeverSlicesRubyBaseOrAnnotation() throws {
        let result = try pipeline("AAAA <ruby>漢字<rt>very-wide-annotation</rt></ruby> BBBB", width: 95)
        let rubyRuns = BrowserLayoutRubyTestProbe.lines(in: result.rootBox)
            .flatMap(\.runs).filter { $0.ruby != nil }
        let run = try #require(rubyRuns.only)
        #expect(run.sourceRange.length == 2)
        #expect((result.sourceText as NSString).substring(with: run.sourceRange) == "漢字")
        #expect(run.width == run.ruby?.advance)
    }
}

struct BrowserLayoutRubyFragmentTests {
    @Test func emitsIndependentBaseAndAnnotationGeometry() async throws {
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(
            "<html><body><p style='margin:0'>甲<ruby>漢<rt>かん</rt></ruby>乙</p></body></html>"
        )
        #expect(doc.lastSourceText == "甲漢乙")
        let rubyGroup = try #require(BrowserLayoutRubyTestProbe.rubyGroups(in: pages).only)
        let texts = BrowserLayoutRubyTestProbe.texts(in: rubyGroup)
        let base = try #require(texts.first { $0.renderedTextOverride == nil })
        let annotation = try #require(texts.first { $0.renderedTextOverride == "かん" })
        #expect(annotation.rect.maxY <= base.rect.minY + 0.01)
        #expect(annotation.sourceRange == base.sourceRange)
        #expect(annotation.sourceMapping == .wholeRange)

        let list = DisplayListBuilder.build(for: pages[0], sourceText: doc.lastSourceText)
        let rendered = list.items.compactMap { item -> String? in
            guard case .text(let text) = item else { return nil }
            return text.text
        }
        #expect(rendered.contains("漢"))
        #expect(rendered.contains("かん"))
        #expect(BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText) == "甲漢乙")
    }

    @Test func rubyChildrenNeverSplitAcrossPages() async throws {
        let lead = String(repeating: "前文 ", count: 12)
        let html = "<html><body><p style='margin:0'>\(lead)<ruby>漢字<rt>かんじ</rt></ruby>後文</p></body></html>"
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 120, height: 45)
        let groupsByPage = pages.enumerated().flatMap { pageIndex, page in
            BrowserLayoutRubyTestProbe.rubyGroups(in: [page]).map { (pageIndex, $0) }
        }
        let pair = try #require(groupsByPage.only)
        let texts = BrowserLayoutRubyTestProbe.texts(in: pair.1)
        #expect(texts.count >= 2)
        #expect(texts.allSatisfy { $0.rect.minY >= pages[pair.0].pageRect.minY })
        #expect(texts.allSatisfy { $0.rect.maxY <= pages[pair.0].pageRect.maxY + 0.01 })
    }
}

@MainActor
struct BrowserLayoutRubyInteractionTests {
    @Test func baseSelectionIncludesBaseAndWholeAnnotationRects() async throws {
        let fixture = try await BrowserLayoutRubyEngineFixture.make(
            html: "<html><body><p>甲<ruby>漢<rt>かん</rt></ruby>乙</p></body></html>"
        )
        let baseRange = (fixture.sourceText as NSString).range(of: "漢")
        let mapped = fixture.engine.rects(forSpine: 0, range: baseRange)
        let rects = try #require(mapped.only?.rects)
        #expect(rects.count == 2)
        #expect(rects.map(\.minY).min()! < rects.map(\.minY).max()!)
    }

    @Test func annotationHitMapsToBaseAndSharesLink() async throws {
        let fixture = try await BrowserLayoutRubyEngineFixture.make(
            html: "<html><body><p><a href='note.xhtml'><ruby>漢<rt>かん</rt></ruby></a></p></body></html>"
        )
        let annotation = try #require(fixture.displayTexts.first { $0.text == "かん" })
        let point = CGPoint(x: annotation.rect.midX, y: annotation.rect.midY)
        #expect(fixture.pageView.sourceRange(at: point) == annotation.sourceRange)
        #expect(fixture.pageView.linkTarget(at: point) == "note.xhtml")
        let linked = fixture.regions.regions.filter { $0.href == "note.xhtml" }
        #expect(linked.count == 2)
        #expect(linked.allSatisfy { $0.sourceRange == annotation.sourceRange })
    }

    @Test func textAfterRubyKeepsPreciseShapedSelection() async throws {
        let fixture = try await BrowserLayoutRubyEngineFixture.make(
            html: "<html><body><p><ruby>漢字<rt>かんじ</rt></ruby>office</p></body></html>"
        )
        let range = (fixture.sourceText as NSString).range(of: "office")
        let rect = try #require(fixture.engine.rects(forSpine: 0, range: range).first?.rects.first)
        let item = try #require(fixture.displayTexts.first { $0.text == "office" })
        #expect(rect.minX >= item.rect.minX - 0.01)
        #expect(rect.maxX <= item.rect.maxX + 0.01)
    }
}

@MainActor
private struct BrowserLayoutRubyEngineFixture {
    let engine: BrowserLayoutPageEngine
    let sourceText: String
    let pageView: BrowserLayoutPageView
    let displayTexts: [DisplayTextItem]
    let regions: LinkInteractionRegionSet

    static func make(html: String) async throws -> BrowserLayoutRubyEngineFixture {
        let resource = MockBrowserLayoutResource(chapters: [
            .init(title: "ruby", href: "ruby.xhtml", html: html, css: []),
        ])
        let settings = ReaderRenderSettings(
            theme: "paper",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 12,
            marginV: 12,
            footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ruby-\(UUID().uuidString)")
        let delegate = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: ["ruby"]),
            renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        let engine = BrowserLayoutPageEngine(
            resource: resource,
            delegate: delegate,
            settings: settings,
            mode: .browserForced
        )
        await engine.start(renderSize: CGSize(width: 300, height: 180), bookId: "ruby")
        let layout = try #require(engine.testChapterLayout?.layout)
        let list = layout.displayList(
            forPage: 0,
            themeTextColor: .black,
            oldThemeColor: .black
        )
        let regions = LinkInteractionRegionSet.build(
            from: list,
            spineIndex: 0,
            anchors: layout.linkAnchors
        )
        let pageView = BrowserLayoutPageView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 180)
        )
        pageView.displayList = list
        pageView.interactionRegions = regions
        let texts = list.items.compactMap { item -> DisplayTextItem? in
            guard case .text(let text) = item else { return nil }
            return text
        }
        return BrowserLayoutRubyEngineFixture(
            engine: engine,
            sourceText: layout.sourceText,
            pageView: pageView,
            displayTexts: texts,
            regions: regions
        )
    }
}

enum BrowserLayoutRubyTestProbe {
    static func rubyUnits(in root: BlockBox) -> [RubyInlineUnit] {
        var result: [RubyInlineUnit] = []
        func walk(_ box: BlockBox) {
            result.append(contentsOf: box.inlineRuns.compactMap(\.ruby))
            box.children.forEach(walk)
        }
        walk(root)
        return result
    }

    static func lines(in root: BlockBox) -> [LayoutLine] {
        var result: [LayoutLine] = []
        func walk(_ box: BlockBox) {
            result.append(contentsOf: box.lines)
            box.children.forEach(walk)
        }
        walk(root)
        return result
    }

    static func rubyBoxes(in root: BlockBox) -> [RubyBox] {
        lines(in: root).flatMap(\.runs).compactMap(\.ruby)
    }

    static func rubyGroups(in pages: [PageFragments]) -> [[Fragment]] {
        var result: [[Fragment]] = []
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                guard case .group(let children) = fragment else { continue }
                let annotationCount = texts(in: children).filter {
                    $0.sourceMapping == .wholeRange
                }.count
                if annotationCount == 1 { result.append(children) }
                walk(children)
            }
        }
        pages.forEach { walk($0.fragments) }
        return result
    }

    static func texts(in fragments: [Fragment]) -> [TextFragment] {
        var result: [TextFragment] = []
        func walk(_ input: [Fragment]) {
            for fragment in input {
                switch fragment {
                case .text(let text): result.append(text)
                case .group(let children): walk(children)
                case .fill, .image: break
                }
            }
        }
        walk(fragments)
        return result
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private extension StyleTreeChild {
    var rubyElement: ComputedStyleNode? {
        guard case .element(let node) = self else { return nil }
        return node
    }
}
