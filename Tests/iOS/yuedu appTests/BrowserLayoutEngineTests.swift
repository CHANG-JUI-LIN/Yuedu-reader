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
