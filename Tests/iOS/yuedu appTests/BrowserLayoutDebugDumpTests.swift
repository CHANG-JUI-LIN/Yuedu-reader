import Testing
import SwiftSoup
import UIKit
@testable import yuedu_app

struct BrowserLayoutDebugDumpTests {
    @Test func dumpNestedBoxGeometry() async throws {
        let css = """
        body { margin: 0; }
        .outer { width: 80%; margin: 20px auto; padding: 12px; border: 2px solid; }
        .inner { width: 50%; margin-left: auto; padding: 8px; }
        .inner p { margin: 0; }
        """
        let html = """
        <html><head><style>\(css)</style></head><body>
        <div class="outer"><div class="inner"><p>Text</p></div></div>
        </body></html>
        """
        let config = BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 400, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let pages = try await doc.renderPages(containerSize: CGSize(width: 300, height: 400))
        let dump = doc.dumpFragments(pages)
        try dump.write(toFile: "/tmp/browser-layout-fragments.txt", atomically: true, encoding: .utf8)

        let rules = CSSParser.parse(css: css)
        let document = try SwiftSoup.parse(html)
        let body = try #require(document.body())
        let builder = ComputedStyleTreeBuilder(rules: rules, config: config)
        let rootNode = builder.buildTree(body: body)
        var source = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let rootBox = BoxTreeBuilder.buildBlock(
            for: rootNode, config: config,
            sourceText: &source, anchors: &anchors, imageLoader: { _ in nil }
        )
        _ = BlockLayout.layOut(root: rootBox, containerWidth: 300, rootFontSize: 17)
        var boxes: [String] = []
        func walk(_ box: BlockBox, indent: String) {
            boxes.append("\(indent)box frame=\(box.frame) content=\(box.contentSize) margins=\(box.margins) padding=\(box.padding) borders=\(box.borders)")
            for child in box.children { walk(child, indent: indent + "  ") }
            for line in box.lines {
                boxes.append("\(indent)  line top=\(line.top) h=\(line.height) x=\(line.contentX) runs=\(line.runs.count)")
            }
        }
        walk(rootBox, indent: "")
        try boxes.joined(separator: "\n").write(toFile: "/tmp/browser-layout-boxes.txt", atomically: true, encoding: .utf8)

        // Reproduce producesWrappedLineBoxes input and dump line runs.
        var style = ComputedStyle(fontSize: 16, fontFamilies: ["PingFangSC-Regular"])
        style.lineHeight = 24
        style.textAlign = .left
        let sourceText = "The quick brown fox jumps over the lazy dog. Padding makes layout robust."
        let runs2 = [
            InlineRun(text: "The quick brown fox jumps over the lazy dog.", style: style,
                      sourceRange: NSRange(location: 0, length: 45)),
            InlineRun(text: " Padding makes layout robust.", style: style,
                      sourceRange: NSRange(location: 45, length: 29)),
        ]
        let lines2 = InlineLayout.layoutLines(runs: runs2, maxWidth: 150, rootFontSize: 16,
                                              lineHeight: nil, sourceText: sourceText)
        var runDump: [String] = []
        for (i, line) in lines2.enumerated() {
            for run in line.runs {
                runDump.append("line\(i) range=\(run.sourceRange) x=\(run.x) w=\(run.width) text=\"\((sourceText as NSString).substring(with: run.sourceRange))\"")
            }
        }
        try runDump.joined(separator: "\n").write(toFile: "/tmp/browser-layout-runs.txt", atomically: true, encoding: .utf8)
        #expect(true)
    }
}
