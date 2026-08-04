import SwiftSoup
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

extension StyleTreeChild {
    func elementNode() -> ComputedStyleNode {
        guard case .element(let node) = self else { fatalError("not an element") }
        return node
    }
    func rawText() -> String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

extension ComputedStyle {
    func marginTopPx() -> CGFloat {
        CSSLengthResolver.resolve(marginTop, emBase: fontSize, remBase: 17, percentBase: 400) ?? 0
    }
}

struct ComputedStyleTreeTests {
    func parseBody(_ html: String) async -> Element? {
        try? await HTMLBuilderDOMParser().parse(
            html: html,
            collectStyles: { _ in [] },
            stylesheetCache: nil
        )?.body
    }

    @Test func buildsTreeWithInheritanceAndCascade() async throws {
        let source = """
        <html><head><style>p { color: blue; font-size: 18px }</style></head>
        <body><p class="lead">Hello <strong>world</strong></p></body></html>
        """
        let body = try #require(await parseBody(source))
        let builder = ComputedStyleTreeBuilder(
            rules: CSSParser.parse(css: "p { color: blue; font-size: 18px }"),
            config: BrowserLayoutConfig(rootFontSize: 17, textColor: .black, backgroundColor: .white)
        )
        let tree = builder.buildTree(body: body)
        let p = tree.children[0].elementNode()
        #expect(p.tag == "p")
        #expect(p.style.color?.isEqual(UIColor.blue) == true)
        #expect(p.style.fontSize == 18)
        #expect(abs(p.style.marginTopPx() - 18) < 0.5)
        let strong = try #require(p.children.compactMap { child in
            if case .element(let node) = child { return node }
            return nil
        }.first)
        #expect(strong.tag == "strong")
        #expect(strong.style.fontWeight == 700)
        #expect(strong.style.color?.isEqual(UIColor.blue) == true)
    }
}

struct BlockLayoutTests {
    func style(width: CSSLength = .auto, ml: CSSLength = .px(0), mr: CSSLength = .px(0),
               pt: CGFloat = 0, pb: CGFloat = 0, bt: CGFloat = 0) -> ComputedStyle {
        var s = ComputedStyle(fontSize: 17, fontFamilies: ["PingFangSC-Regular"])
        s.width = width; s.marginLeft = ml; s.marginRight = mr
        s.paddingTop = .px(pt); s.paddingBottom = .px(pb)
        s.borderTopWidth = bt
        return s
    }

    @Test func stacksChildrenVertically() {
        let childA = BlockBox(style: style(), boxType: .block)
        let childB = BlockBox(style: style(), boxType: .block)
        let root = BlockBox(style: style(), boxType: .block, children: [childA, childB])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        #expect(childA.frame == CGRect(x: 0, y: 0, width: 200, height: 0))
        #expect(childB.frame == CGRect(x: 0, y: 0, width: 200, height: 0))
        #expect(root.contentSize.height == 0)
    }

    @Test func fillsContainerWidthWhenAuto() {
        let child = BlockBox(style: style(), boxType: .block)
        let root = BlockBox(style: style(), boxType: .block, children: [child])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        #expect(child.frame.width == 200)
    }

    @Test func percentWidthResolvesAgainstContainer() {
        var s = style()
        s.width = .percent(0.5)
        let child = BlockBox(style: s, boxType: .block)
        let root = BlockBox(style: style(), boxType: .block, children: [child])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        #expect(child.contentSize.width == 100)
    }

    @Test func autoMarginsCenterFixedWidth() {
        var s = style()
        s.width = .px(100)
        s.marginLeft = .auto
        s.marginRight = .auto
        let child = BlockBox(style: s, boxType: .block)
        let root = BlockBox(style: style(), boxType: .block, children: [child])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        #expect(child.frame.minX == 50)
        #expect(child.margins.left == 50)
    }

    @Test func paddingAndBorderConsumeWidth() {
        var s = style()
        s.paddingLeft = .px(10)
        s.paddingRight = .px(10)
        s.borderLeftWidth = 2
        s.borderRightWidth = 2
        let child = BlockBox(style: s, boxType: .block)
        let root = BlockBox(style: style(), boxType: .block, children: [child])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        #expect(child.contentSize.width == 176) // 200 - 20 - 4
    }

    @Test func contentHeightFromChildren() {
        var childS = style()
        childS.marginTop = .px(10); childS.marginBottom = .px(10)
        let child = BlockBox(style: childS, boxType: .block,
                             lines: [LayoutLine(runs: [], height: 40, ascent: 30, descent: 10,
                                               top: 0, baseline: 30, contentX: 0)])
        _ = BlockLayout.layOut(root: child, containerWidth: 200)
        let root = BlockBox(style: style(), boxType: .block, children: [child])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        #expect(child.frame.height == 40)          // border-box = content
        #expect(root.contentSize.height == 40)     // child occupies 40; its top/bottom margins collapse out
    }
}

extension BlockLayoutTests {
    @Test func siblingMarginsCollapse() {
        var s1 = style(); s1.marginTop = .px(10); s1.marginBottom = .px(30)
        var s2 = style(); s2.marginTop = .px(20); s2.marginBottom = .px(5)
        let childA = BlockBox(style: s1, boxType: .block)
        let childB = BlockBox(style: s2, boxType: .block)
        _ = BlockLayout.layOut(root: childA, containerWidth: 200)
        _ = BlockLayout.layOut(root: childB, containerWidth: 200)
        let root = BlockBox(style: style(), boxType: .block, children: [childA, childB])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        // A bottom (30) and B top (20) collapse to 30; B starts 30 after A's bottom.
        #expect(childB.frame.minY == childA.frame.maxY + 30)
        #expect(childA.frame.maxY == 0)   // A has 0 content and its top margin collapsed into the box
        #expect(childB.frame.minY == 30)
    }

    @Test func collapsedChildHeightInParent() {
        var childS = style()
        childS.marginTop = .px(10); childS.marginBottom = .px(10)
        let child = BlockBox(style: childS, boxType: .block)
        let root = BlockBox(style: style(), boxType: .block, children: [child])
        _ = BlockLayout.layOut(root: root, containerWidth: 200)
        // First-child top and last-child bottom margins collapse into the parent
        // (no border/padding on the parent), so parent content height = 0.
        #expect(root.contentSize.height == 0)
        #expect(child.frame.minY == 0)
    }
}

struct CoreTextLineBreakerTests {
    @Test func breaksLongTextIntoMultipleLines() throws {
        let paragraph = "This is a sentence that is long enough to wrap onto several lines when constrained to a narrow column width."
        let attr = NSAttributedString(string: paragraph, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        let breaker = CoreTextLineBreaker()
        let lines = breaker.breakLines(attributed: attr, maxWidth: 100)
        #expect(lines.count >= 3)
        #expect(lines.map(\.range.length).reduce(0, +) == attr.length)
        for line in lines {
            #expect(line.width <= 100.01)
        }
    }

    @Test func singleLineWhenWideEnough() throws {
        let paragraph = "Hello world"
        let attr = NSAttributedString(string: paragraph, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        let lines = CoreTextLineBreaker().breakLines(attributed: attr, maxWidth: 400)
        #expect(lines.count == 1)
        #expect(lines[0].range.length == attr.length)
    }

    @Test func newlineForcesBreak() throws {
        let paragraph = "Alpha\nBeta"
        let attr = NSAttributedString(string: paragraph, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        let lines = CoreTextLineBreaker().breakLines(attributed: attr, maxWidth: 400)
        #expect(lines.count == 2)
    }
}

struct InlineLayoutTests {
    @Test func producesWrappedLineBoxes() {
        var style = ComputedStyle(fontSize: 16, fontFamilies: ["PingFangSC-Regular"])
        style.lineHeight = 24
        style.textAlign = .left
        let runs = [
            InlineRun(text: "The quick brown fox jumps over the lazy dog.", style: style),
            InlineRun(text: " Padding makes layout robust.", style: style),
        ]
        let lines = InlineLayout.layoutLines(runs: runs, maxWidth: 150, rootFontSize: 16, lineHeight: nil)
        #expect(lines.count >= 2)
        for line in lines {
            #expect(line.height == 24)
            #expect(line.baseline >= line.top)
            #expect(line.baseline <= line.top + line.height)
        }
    }

    @Test func collapsesWhitespaceAcrossRuns() {
        var style = ComputedStyle(fontSize: 16, fontFamilies: ["PingFangSC-Regular"])
        style.lineHeight = 24
        let collapsed = InlineLayout.collapseRuns([InlineRun(text: "Alpha   Beta\nGamma", style: style)])
        #expect(collapsed.count == 1)
        #expect(collapsed[0].text == "Alpha Beta Gamma")
        let lines = InlineLayout.layoutLines(runs: collapsed, maxWidth: 400, rootFontSize: 16, lineHeight: nil)
        let total = lines.flatMap(\.runs).map(\.range.length).reduce(0, +)
        #expect(total == 16)
    }
}

struct PageFragmentationTests {
    func lineBox(height: CGFloat, top: CGFloat, text: String, style: ComputedStyle) -> LayoutLine {
        LayoutLine(runs: [LineRun(range: NSRange(location: 0, length: (text as NSString).length),
                                 x: 0, width: 80, style: style, font: InlineLayout.font(for: style))],
                   height: height, ascent: height * 0.75, descent: height * 0.25,
                   top: top, baseline: top + height * 0.75, contentX: 0)
    }

    @Test func splitsBlockAcrossPages() {
        var style = ComputedStyle(fontSize: 17, fontFamilies: ["PingFangSC-Regular"])
        style.color = .black
        let lines = (0..<10).map { lineBox(height: 40, top: CGFloat($0) * 40, text: "L\($0) ", style: style) }
        let block = BlockBox(style: style, boxType: .block, lines: lines)
        _ = BlockLayout.layOut(root: block, containerWidth: 300)
        let pages = PageFragmentation.fragment(box: block, pageSize: CGSize(width: 300, height: 100))
        #expect(pages.count == 4)                      // 400pt content / 100pt pages
        #expect(pages.map(\.fragments.count) == [3, 2, 3, 2])
        for page in pages {
            #expect(page.index >= 0)
            #expect(!page.fragments.isEmpty)
        }
    }
}

struct BrowserLayoutDocumentTests {
    @Test func rendersSimpleChapterToPages() async throws {
        let html = """
        <html><head>
        <style>p { margin: 0; line-height: 1.2 }</style>
        </head><body>
        <p>One line paragraph.</p>
        </body></html>
        """
        let config = BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 400, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let pages = try await doc.renderPages(containerSize: CGSize(width: 300, height: 400))
        #expect(pages.count == 1)
        let displayList = DisplayListBuilder.build(for: pages[0])
        #expect(displayList.items.contains { item in
            if case .text = item { return true }
            return false
        })
        #expect(displayList.items.count >= 1)
    }

    @Test func emptyBodyYieldsNoPages() async throws {
        let doc = BrowserLayoutDocument(html: "<html><body></body></html>", cssTexts: [], config: BrowserLayoutConfig())
        let pages = try await doc.renderPages(containerSize: CGSize(width: 300, height: 400))
        #expect(pages.isEmpty)
    }
}

struct DisplayListTests {
    @Test func convertsFragmentsToItems() {
        let page = PageFragments(
            index: 0,
            pageRect: CGRect(x: 0, y: 0, width: 300, height: 100),
            fragments: [
                .fill(FillFragment(rect: CGRect(x: 10, y: 0, width: 280, height: 40), color: .red, cornerRadius: 0)),
                .text(TextFragment(range: NSRange(location: 0, length: 4),
                                   rect: CGRect(x: 10, y: 4, width: 60, height: 20),
                                   baselineY: 20, font: .systemFont(ofSize: 16), color: .black)),
                .group([.fill(FillFragment(rect: CGRect(x: 5, y: 50, width: 100, height: 10), color: .blue, cornerRadius: 2))]),
            ]
        )
        let list = DisplayListBuilder.build(for: page)
        #expect(list.items.count == 3)
        guard case .fill(let fill) = list.items[0] else { Issue.record("expected fill"); return }
        #expect(fill.color == .red)
        guard case .text(let text) = list.items[1] else { Issue.record("expected text"); return }
        #expect(text.rect == CGRect(x: 10, y: 4, width: 60, height: 20))
        guard case .fill(let groupedFill) = list.items[2] else { Issue.record("expected fill from group"); return }
        #expect(groupedFill.cornerRadius == 2)
    }
}
