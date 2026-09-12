@testable import YueduCoreText
import Foundation
import CLexbor
import Testing
@testable import yuedu_app

@Suite(.serialized)
struct LexborCSSFrontendSyntheticTests {
    @Test func snapshotsDOMAttributesTextAndCascade() throws {
        let html = "<html><body><p id='p' class='lead' style='color: red'>Hello <em>world</em></p></body></html>"
        let input = CSSFrontendInput(
            html: html,
            stylesheets: [AuthorStylesheet(
                source: .linked(href: "memory.css"), text: "p.lead { color: blue; width: 15%; }",
                sourceOrder: 0, currentCompatibilityOrder: nil,
                currentCompatibilityOnly: false, media: nil, isAlternate: false
            )]
        )
        let frontend = try LexborCSSFrontend(input: input)
        let snapshot = try frontend.snapshot(input: input)
        let paragraphEntry = try #require(snapshot.elements.first { $0.value.tagName == "p" })
        let paragraph = paragraphEntry.value
        let paragraphID = paragraphEntry.key
        #expect(paragraph.attribute("id") == "p")
        #expect(paragraph.classTokens == ["lead"])
        #expect(snapshot.textOrder.map(\.text).joined() == "Hello world")
        #expect(snapshot.winningDeclarations.contains { $0.property == "color" })
        #expect(snapshot.winningDeclarations.contains { $0.property == "width" })
        #expect(snapshot.winningDeclarations.contains { $0.origin == 1 })
        #expect(snapshot.winningDeclarations.filter { $0.property == "color" || $0.property == "width" }
            .allSatisfy { $0.nodeID == paragraphID })
    }

    @Test func snapshotsHaveCompletePathsAndMixedChildOrder() throws {
        let html = "<body><section id='a'><p id='p'>Alpha<em>Beta</em>Omega</p></section><section id='b'><p>Other</p></section></body>"
        let input = CSSFrontendInput(html: html, stylesheets: [])
        let snapshot = try LexborCSSFrontend().snapshot(input: input)
        let paragraphs = snapshot.elements.values.filter { $0.tagName == "p" }
        #expect(Set(paragraphs.map(\.semanticPath)).count == 2)
        #expect(paragraphs.contains { $0.semanticPath.contains("section[0]#a/") && $0.semanticPath.hasSuffix("p[0]#p") })
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        let paragraph = try #require(find("p", in: result.rootNode))
        #expect(paragraph.children.map { child in
            switch child { case .text(let text): "text:" + text; case .element(let node): "element:" + node.tag }
        } == ["text:Alpha", "element:em", "text:Omega"])
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func hintCascadeAndInlineOnlyStyleReachComputedValues() throws {
        for (author, inline, expected) in [
            ("", "", 0.15), ("img {width:40%}", "", 0.4),
            ("img {width:40%}", "width:30%", 0.3),
            ("img {width:40% !important}", "width:30%", 0.4),
            ("", "width:30%", 0.3)
        ] {
            let input = CSSFrontendInput.currentCompatibility(
                html: "<body><img id='image' width='15%' style='\(inline)'></body>",
                cssTexts: author.isEmpty ? [] : [author]
            )
            var metrics = LayoutMetrics()
            let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
            #expect(find("image", in: result.rootNode)?.style.width == .percent(expected))
            #expect(!result.capabilityFacts.blocksCutover)
        }
    }

    @Test func preservesLinkFootnoteAndSVGIdentityAfterOwnerDestruction() throws {
        let input = CSSFrontendInput(html: """
        <html><body><p><a id="ref" href="#n" epub:type="noteref">[<em id="inner">1</em>]</a></p>
        <aside id="n" epub:type="footnote"><p>Note <b>body</b></p></aside>
        <svg id="cover" xmlns="http://www.w3.org/2000/svg"><image xlink:href="Images/Cover.JPG"/></svg></body></html>
        """, stylesheets: [])
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        let inner = try #require(find("inner", in: result.rootNode))
        #expect(inner.linkTarget == "#n")
        #expect(result.linkAnchors[inner.nodeID]?.semantic == .noteref)
        #expect(result.footnotes["n"] == "Note body")
        #expect(find("cover", in: result.rootNode)?.semanticElement?.svgRenderability == .rasterWrapper(source: "Images/Cover.JPG"))
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func unsupportedShorthandIsRetainedAndCannotEnterLayout() throws {
        let input = CSSFrontendInput.currentCompatibility(html: "<body><p id='p'>Text</p></body>", cssTexts: ["p { margin: 1em; margin-left: 2em }"])
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        let gap = try #require(result.capabilityFacts.unsupportedDeclarations.first { $0.property == "margin" })
        #expect(gap.value == "1em")
        #expect(gap.source.stylesheet?.sourceOrder == 0)
        #expect(gap.semanticPath.hasSuffix("p[0]#p"))
        #expect(gap.source.selector?.contains("p") == true)
        let document = BrowserLayoutDocument(input: input, config: .init(), frontend: LexborCSSFrontend())
        #expect(throws: (any Error).self) {
            _ = try document.makeLayout(containerSize: .init(width: 320, height: 480), metrics: &metrics)
        }
    }

    @Test func frontendCanBeReusedWithoutRetainingOrAccumulatingCascade() throws {
        let frontend = LexborCSSFrontend()
        for value in [10, 20, 30] {
            let input = CSSFrontendInput.currentCompatibility(html: "<p id='p'>Text</p>", cssTexts: ["p {width:\(value)px}"])
            var metrics = LayoutMetrics()
            let result = try frontend.buildStyleTree(input: input, config: .init(), metrics: &metrics)
            #expect(find("p", in: result.rootNode)?.style.width == .px(CGFloat(value)))
            #expect(ylx_debug_live_document_count() == 0)
        }
    }

    @Test func unparsedValuesAndAtRulesBlockCutoverInsteadOfDisappearing() throws {
        for css in ["p {width:var(--reader-width)}", "@media all {p {color:red}}"] {
            var metrics = LayoutMetrics()
            let input = CSSFrontendInput.currentCompatibility(html: "<p>Text</p>", cssTexts: [css])
            let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
            #expect(result.capabilityFacts.blocksCutover)
            #expect(!result.diagnostics.isEmpty)
        }
    }

    @Test func lexborRejectedClearBothCannotEnterLayout() throws {
        // Lexbor 3.0.0's clear parser omits the valid `both` keyword.
        let input = CSSFrontendInput.currentCompatibility(html: "<p id='p'>Text</p>", cssTexts: ["p {clear:both}"])
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        #expect(result.capabilityFacts.blocksCutover)
        #expect(result.diagnostics.contains { $0.message.contains("cannot parse") })
        let document = BrowserLayoutDocument(input: input, config: .init(), frontend: LexborCSSFrontend())
        #expect(throws: (any Error).self) {
            _ = try document.makeLayout(containerSize: .init(width: 320, height: 480), metrics: &metrics)
        }
    }

    @Test func computedInheritanceUsesParentFontAndPercentRemainsSymbolic() throws {
        let html = "<div style='font-size:20px;width:2em;text-indent:1em'><p id='child' style='font-size:40px;width:inherit'>X</p></div>"
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: .init(html: html, stylesheets: []), config: .init(), metrics: &metrics)
        let child = try #require(find("child", in: result.rootNode))
        #expect(child.style.width == .px(40))
        #expect(child.style.textIndent == .length(.px(20)))
        #expect(!result.capabilityFacts.blocksCutover)
    }

    @Test func rootSuppressionNeverEntersVisibleLayout() throws {
        var metrics = LayoutMetrics()
        let input = CSSFrontendInput(html: "<html style='display:none'><body><p>X</p></body></html>", stylesheets: [])
        let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        #expect(result.capabilityFacts.domFeatures.contains(.hiddenRoot))
        let document = BrowserLayoutDocument(input: input, config: .init(), frontend: LexborCSSFrontend())
        #expect(throws: (any Error).self) { _ = try document.makeLayout(containerSize: .init(width: 320, height: 480), metrics: &metrics) }
    }

    @Test func borderDefaultsAndLonghandStylesUseCSSComputedWidths() throws {
        let html = "<body><p id='width' style='border-top-width:5px'>X</p><p id='style' style='border-top-style:solid'>Y</p><p id='both' style='font-size:20px;border-top-width:0.5em;border-top-style:dashed;color:red'>Z</p></body>"
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: .init(html: html, stylesheets: []), config: .init(), metrics: &metrics)
        #expect(find("width", in: result.rootNode)?.style.borderTopWidth == 0)
        #expect(find("style", in: result.rootNode)?.style.borderTopWidth == 3)
        #expect(find("both", in: result.rootNode)?.style.borderTopWidth == 10)
        #expect(find("both", in: result.rootNode)?.style.borderTopStyle == .dashed)
        #expect(!result.capabilityFacts.blocksCutover)
    }

    @Test func hiddenSubtreesDoNotConsumeLayoutIdentities() throws {
        let input = CSSFrontendInput(html: "<body><div style='display:none'><p>Hidden</p></div><p id='visible'>Visible <em>text</em></p></body>", stylesheets: [])
        var metrics = LayoutMetrics()
        let lexbor = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        let current = try CurrentCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        #expect(lexbor.nodeCount == current.nodeCount)
        #expect(lexbor.rootNode.nodeID == current.rootNode.nodeID)
        #expect(find("visible", in: lexbor.rootNode)?.nodeID == find("visible", in: current.rootNode)?.nodeID)
    }

    @Test func longhandValuesPassThroughActualLexborSerialization() throws {
        let input = CSSFrontendInput.currentCompatibility(html: "<p id='p'>Text</p>", cssTexts: ["""
        p {font-family:"Case Font";font-size:20px;font-weight:700;font-style:italic;
           line-height:150%;color:#123456;text-indent:10%;float:left;clear:right;
           margin-left:2em;padding-top:3%;width:50%;max-width:9rem;
           border-top-style:solid;border-top-width:2px;white-space:pre-wrap;
           background-image:url("Images/BG.PNG");background-size:cover}
        """])
        var metrics = LayoutMetrics()
        let result = try LexborCSSFrontend().buildStyleTree(input: input, config: .init(), metrics: &metrics)
        let style = try #require(find("p", in: result.rootNode)?.style)
        #expect(style.fontFamilies == ["Case Font"]); #expect(style.fontSize == 20)
        #expect(style.fontWeight == 700); #expect(style.isItalic); #expect(style.lineHeight == 30)
        #expect(style.cssFloat == .left); #expect(style.cssClear == .right)
        #expect(style.textIndent == .length(.percent(0.1)))
        #expect(style.marginLeft == .em(2)); #expect(style.paddingTop == .percent(0.03))
        #expect(style.width == .percent(0.5)); #expect(style.maxWidth == .rem(9))
        #expect(style.borderTopWidth == 2); #expect(style.whiteSpace == .preWrap)
        #expect(style.backgroundImage?.source == "Images/BG.PNG"); #expect(style.backgroundImage?.size == .cover)
        #expect(!result.capabilityFacts.blocksCutover)
    }

    private func find(_ id: String, in node: ComputedStyleNode) -> ComputedStyleNode? {
        if node.anchorID == id { return node }
        for child in node.children {
            if case .element(let element) = child, let match = find(id, in: element) { return match }
        }
        return nil
    }
}
