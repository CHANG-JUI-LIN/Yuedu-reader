import Foundation
import UIKit

/// Result of the CSS frontend pipeline stage.
/// Encapsulates the resolved style tree, document footnotes, and link anchors.
struct CSSFrontendResult {
    let rootNode: ComputedStyleNode
    let linkAnchors: [Int: LinkAnchorInfo]
    let footnotes: [String: String]
    let nodeCount: Int
    /// Value-only evidence for differential/cutover gates. Production remains Current.
    let capabilityFacts: FrontendCapabilityFacts
    let diagnostics: [CSSFrontendDiagnostic]
    let styleSources: [String: [String: StyleSourceIdentity]]

    init(
        rootNode: ComputedStyleNode,
        linkAnchors: [Int: LinkAnchorInfo],
        footnotes: [String: String],
        nodeCount: Int,
        capabilityFacts: FrontendCapabilityFacts = .init(),
        diagnostics: [CSSFrontendDiagnostic] = [],
        styleSources: [String: [String: StyleSourceIdentity]] = [:]
    ) {
        self.rootNode = rootNode
        self.linkAnchors = linkAnchors
        self.footnotes = footnotes
        self.nodeCount = nodeCount
        self.capabilityFacts = capabilityFacts
        self.diagnostics = diagnostics
        self.styleSources = styleSources
    }
}

/// Abstract interface for HTML/CSS parsing, selector matching, and style cascade resolution.
/// Produces a resolved `CSSFrontendResult` (containing `ComputedStyleNode`) for consumption
/// by `BoxTreeBuilder`.
protocol CSSFrontend: AnyObject {
    /// Builds a computed style tree and associated metadata from XHTML markup and external stylesheets.
    ///
    /// - Parameters:
    ///   - input: Value-only XHTML and authored stylesheet input.
    ///   - config: Reader layout configuration.
    ///   - metrics: Per-stage performance telemetry collector.
    /// - Returns: `CSSFrontendResult` containing the root `ComputedStyleNode`, link anchors, and footnotes.
    func buildStyleTree(
        input: CSSFrontendInput,
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult
}

extension CSSFrontend {
    /// Temporary source-compatible entry point for production ingestion and
    /// focused tests. Task 5 supplies authored stylesheet identities directly.
    func buildStyleTree(
        html: String,
        cssTexts: [String],
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        try buildStyleTree(
            input: .currentCompatibility(html: html, cssTexts: cssTexts),
            config: config,
            metrics: &metrics
        )
    }
}
