import Foundation
import SwiftSoup
import UIKit

/// Public entry point. `html` is the chapter's XHTML (inline `<style>` blocks are
/// extracted automatically); `cssTexts` is external stylesheet text the caller
/// already loaded (EPUB resource loading stays on the caller side, reusing
/// EPUBStyleResolver later — one data path, no parallel cache).
final class BrowserLayoutDocument {

    private let html: String
    private let cssTexts: [String]
    private let config: BrowserLayoutConfig

    init(html: String, cssTexts: [String], config: BrowserLayoutConfig) {
        self.html = html
        self.cssTexts = cssTexts
        self.config = config
    }

    func renderPages(containerSize: CGSize) async throws -> [PageFragments] {
        let fullCSS = cssTexts + extractInlineStyles(html)
        let document = try SwiftSoup.parse(html)
        guard let body = document.body() else { return [] }

        let rules = fullCSS.flatMap { CSSParser.parse(css: $0, orderOffset: 0) }
        let builder = ComputedStyleTreeBuilder(rules: rules, config: config)
        let rootNode = builder.buildTree(body: body)
        let rootBox = BoxTreeBuilder.buildBlock(for: rootNode, config: config)

        let contentWidth = max(1, containerSize.width - config.contentInsets.left - config.contentInsets.right)
        let contentHeight = max(1, containerSize.height - config.contentInsets.top - config.contentInsets.bottom)
        _ = BlockLayout.layOut(root: rootBox, containerWidth: contentWidth)

        // Empty document: no lines, no children → no pages.
        if rootBox.lines.isEmpty && rootBox.children.isEmpty {
            return []
        }

        return PageFragmentation.fragment(box: rootBox, pageSize: CGSize(width: contentWidth, height: contentHeight))
    }

    private func extractInlineStyles(_ html: String) -> [String] {
        guard let doc = try? SwiftSoup.parse(html),
              let head = doc.head() else { return [] }
        let styleTags = (try? head.select("style").array()) ?? []
        return styleTags.compactMap { try? $0.html() }.filter { !$0.isEmpty }
    }
}
