import Foundation
import SwiftSoup

/// Named facade for the pre-Lexbor SwiftSoup + CSSParser + CSSSelector cascade.
/// It may use SwiftSoup internally, but every returned DOM identity is copied
/// into `HTMLDOMElementSnapshot` before the document leaves this method.
final class CurrentCSSFrontend: CSSFrontend {
    init() {}

    func buildStyleTree(
        input: CSSFrontendInput,
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        let document = try metrics.time("htmlParse") {
            try SwiftSoup.parse(input.html)
        }
        guard let body = document.body() else {
            throw BrowserLayoutDocument.BrowserLayoutError.emptyBody
        }

        let fullCSS = metrics.time("cssCollect") {
            CurrentCSSFrontendSupport.stylesheetsForCurrentCompatibility(input.stylesheets)
                + CurrentCSSFrontendSupport.inlineStyles(in: document)
        }
        let rules = metrics.time("cssParse") {
            CurrentCSSFrontendSupport.parseRules(in: fullCSS)
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
/// the production Current frontend (notably the capability scanner).
enum CurrentCSSFrontendSupport {
    static func stylesheetsForCurrentCompatibility(
        _ stylesheets: [AuthorStylesheet]
    ) -> [String] {
        stylesheets
            .filter { $0.currentCompatibilityOrder != nil }
            .sorted { lhs, rhs in
                let left = lhs.currentCompatibilityOrder ?? lhs.sourceOrder
                let right = rhs.currentCompatibilityOrder ?? rhs.sourceOrder
                if left == right { return lhs.sourceOrder < rhs.sourceOrder }
                return left < right
            }
            .map(\.text)
    }

    static func inlineStyles(in document: Document) -> [String] {
        guard let head = document.head() else { return [] }
        return ((try? head.select("style").array()) ?? [])
            .compactMap { try? $0.html() }
            .filter { !$0.isEmpty }
    }

    static func parseRules(in stylesheets: [String]) -> [CSSRule] {
        // Current is a boundary around the existing frontend, so its cascade
        // ordering remains byte-for-byte compatible during this task. The old
        // BrowserLayoutDocument parsed every stylesheet with a zero offset.
        stylesheets.flatMap { css in
            CSSParser.parse(css: css, orderOffset: 0)
        }
    }
}

/// Compatibility spelling retained until the production cutover is complete.
/// It deliberately delegates rather than carrying a second implementation.
final class LegacyCSSFrontend: CSSFrontend {
    private let current = CurrentCSSFrontend()

    init() {}

    func buildStyleTree(
        input: CSSFrontendInput,
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        try current.buildStyleTree(input: input, config: config, metrics: &metrics)
    }
}

/// Compatibility alias used by scanner/census code during Tasks 4–8. Keeping
/// one implementation guarantees they parse with the same Current policy.
typealias LegacyCSSFrontendSupport = CurrentCSSFrontendSupport
