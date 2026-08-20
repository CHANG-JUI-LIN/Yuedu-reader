import Foundation
import SwiftSoup
import UIKit

/// Result of the CSS frontend pipeline stage.
/// Encapsulates the resolved style tree, document footnotes, and link anchors.
struct CSSFrontendResult {
    let rootNode: ComputedStyleNode
    let linkAnchors: [Int: LinkAnchorInfo]
    let footnotes: [String: String]
    let nodeCount: Int

    init(
        rootNode: ComputedStyleNode,
        linkAnchors: [Int: LinkAnchorInfo],
        footnotes: [String: String],
        nodeCount: Int
    ) {
        self.rootNode = rootNode
        self.linkAnchors = linkAnchors
        self.footnotes = footnotes
        self.nodeCount = nodeCount
    }
}

/// Abstract interface for HTML/CSS parsing, selector matching, and style cascade resolution.
/// Produces a resolved `CSSFrontendResult` (containing `ComputedStyleNode`) for consumption
/// by `BoxTreeBuilder`.
protocol CSSFrontend: AnyObject {
    /// Builds a computed style tree and associated metadata from XHTML markup and external stylesheets.
    ///
    /// - Parameters:
    ///   - html: The raw XHTML/HTML content of the chapter.
    ///   - cssTexts: Array of external stylesheet CSS strings.
    ///   - config: Reader layout configuration.
    ///   - metrics: Per-stage performance telemetry collector.
    /// - Returns: `CSSFrontendResult` containing the root `ComputedStyleNode`, link anchors, and footnotes.
    func buildStyleTree(
        html: String,
        cssTexts: [String],
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult
}

/// Production implementation using existing SwiftSoup DOM + CSSParser + ComputedStyleTreeBuilder.
final class LegacyCSSFrontend: CSSFrontend {

    init() {}

    func buildStyleTree(
        html: String,
        cssTexts: [String],
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        let document = try metrics.time("htmlParse") { try SwiftSoup.parse(html) }
        guard let body = document.body() else {
            throw BrowserLayoutDocument.BrowserLayoutError.emptyBody
        }
        let fullCSS = metrics.time("cssCollect") {
            cssTexts + LegacyCSSFrontendSupport.inlineStyles(in: document)
        }
        let rules = metrics.time("cssParse") {
            LegacyCSSFrontendSupport.parseRules(in: fullCSS)
        }
        let builder = ComputedStyleTreeBuilder(rules: rules, config: config)
        var linkAnchors: [Int: LinkAnchorInfo] = [:]
        let rootNode = metrics.time("styleTree") {
            let tree = builder.buildTree(body: body)
            linkAnchors = ComputedStyleTreeBuilder.collectLinkAnchors(tree)
            return tree
        }
        let footnotes = BrowserLayoutDocument.collectFootnotes(in: document)

        return CSSFrontendResult(
            rootNode: rootNode,
            linkAnchors: linkAnchors,
            footnotes: footnotes,
            nodeCount: rootNode.nodeID
        )
    }

}

/// Shared collection/parsing policy for every consumer that must agree with
/// the production CSS frontend (notably the capability scanner). Stylesheet
/// order is preserved across separate EPUB resources and inline `<style>`
/// elements, so the cascade has one monotonic source-order axis.
enum LegacyCSSFrontendSupport {
    static func inlineStyles(in document: Document) -> [String] {
        guard let head = document.head() else { return [] }
        return ((try? head.select("style").array()) ?? [])
            .compactMap { try? $0.html() }
            .filter { !$0.isEmpty }
    }

    static func parseRules(in stylesheets: [String]) -> [CSSRule] {
        // LegacyCSSFrontend is a boundary around the existing frontend, so its
        // cascade ordering must remain byte-for-byte compatible. The original
        // BrowserLayoutDocument parsed every stylesheet with a zero offset.
        stylesheets.flatMap { css in
            CSSParser.parse(css: css, orderOffset: 0)
        }
    }
}
