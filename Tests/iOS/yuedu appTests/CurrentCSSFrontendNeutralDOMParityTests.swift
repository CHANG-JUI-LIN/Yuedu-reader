import Testing
@testable import yuedu_app

@Suite(.serialized)
struct CurrentCSSFrontendNeutralDOMParityTests {
    @Test func snapshotsAuthoredDOMWithoutRetainingFrontendNodes() throws {
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>Neutral DOM</title></head>
          <body id="root" class="book shell" data-custom="kept" lang="zh-Hant">
            <p id="p0" data-order="first">Alpha<a id="note-link" class="note marker" href="#note-1" epub:type="noteref" role="doc-noteref">[1]</a>Omega</p>
            <p id="p1" data-order="second">Beta<img id="portrait" class="round hero" src="portrait.png" alt="Portrait" data-extra="preserved" /></p>
            <svg id="cover" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><image xlink:href="cover.jpg" /></svg>
          </body>
        </html>
        """
        var metrics = LayoutMetrics()
        let result = try CurrentCSSFrontend().buildStyleTree(
            input: CSSFrontendInput(html: html, stylesheets: []),
            config: BrowserLayoutConfig(),
            metrics: &metrics
        )

        let root = result.rootNode
        let body = try #require(root.semanticElement)
        #expect(body.tagName == "body")
        #expect(body.namespace == "http://www.w3.org/1999/xhtml")
        #expect(body.attribute("id") == "root")
        #expect(body.attribute("class") == "book shell")
        #expect(body.attribute("data-custom") == "kept")
        #expect(body.attribute("lang") == "zh-Hant")

        let firstParagraph = try #require(find(id: "p0", in: root))
        let secondParagraph = try #require(find(id: "p1", in: root))
        #expect(firstParagraph.semanticElement?.semanticPath.contains("p[0]#p0") == true)
        #expect(secondParagraph.semanticElement?.semanticPath.contains("p[1]#p1") == true)

        let orderedContent = firstParagraph.children.map { child -> String in
            switch child {
            case .text(let text):
                return "text:\(text)"
            case .element(let element):
                return "element:\(element.tag)"
            }
        }
        #expect(orderedContent == ["text:Alpha", "element:a", "text:Omega"])

        let link = try #require(find(id: "note-link", in: root))
        #expect(link.semanticElement?.attribute("href") == "#note-1")
        #expect(link.semanticElement?.attribute("epub:type") == "noteref")
        #expect(link.semanticElement?.attribute("role") == "doc-noteref")
        #expect(link.semanticElement?.attribute("class") == "note marker")
        #expect(link.semanticElement?.linkSemantic == .noteref)

        let image = try #require(find(id: "portrait", in: root))
        #expect(image.semanticElement?.attribute("src") == "portrait.png")
        #expect(image.semanticElement?.attribute("alt") == "Portrait")
        #expect(image.semanticElement?.attribute("data-extra") == "preserved")
        #expect(image.semanticElement?.classTokens == ["round", "hero"])

        let svg = try #require(find(id: "cover", in: root))
        #expect(svg.semanticElement?.namespace == "http://www.w3.org/2000/svg")
        #expect(svg.semanticElement?.svgRenderability == .rasterWrapper(source: "cover.jpg"))
    }

    @Test func marksVectorSVGAsUnsupported() throws {
        let html = """
        <html><body><svg id="vector" xmlns="http://www.w3.org/2000/svg"><path d="M0 0 L1 1" /></svg></body></html>
        """
        var metrics = LayoutMetrics()
        let result = try CurrentCSSFrontend().buildStyleTree(
            input: CSSFrontendInput(html: html, stylesheets: []),
            config: BrowserLayoutConfig(),
            metrics: &metrics
        )

        let svg = try #require(find(id: "vector", in: result.rootNode))
        #expect(svg.semanticElement?.svgRenderability == .unsupportedVector)
    }

    private func find(id: String, in node: ComputedStyleNode) -> ComputedStyleNode? {
        if node.semanticElement?.attribute("id") == id {
            return node
        }
        for child in node.children {
            guard case .element(let childNode) = child else { continue }
            if let match = find(id: id, in: childNode) {
                return match
            }
        }
        return nil
    }
}
