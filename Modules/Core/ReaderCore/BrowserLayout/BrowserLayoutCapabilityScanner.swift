import Foundation
import SwiftSoup

/// Structured reason a chapter was rejected by the capability scanner.
/// Never carries book titles, chapter text, or URLs — only the feature name.
enum UnsupportedFeature: Equatable, CustomStringConvertible {
    case verticalWritingMode
    case ruby
    case float
    case table
    case flexGrid
    case positioned            // absolute / fixed / sticky
    case mathML
    case scriptedInteractive
    case unsupportedSVG
    case mediaQueries           // @media (layout-affecting)
    case calcOrModernFunctions  // calc() / min() / max() / clamp()
    case unparseableLayoutCSS   // CSS we cannot parse that could affect layout
    case unknownBlockDisplay    // display: flex/grid/table/… mapped here too

    var description: String {
        switch self {
        case .verticalWritingMode: return "vertical-writing-mode"
        case .ruby: return "ruby"
        case .float: return "float"
        case .table: return "table"
        case .flexGrid: return "flex-grid"
        case .positioned: return "positioned"
        case .mathML: return "mathml"
        case .scriptedInteractive: return "scripted-interactive"
        case .unsupportedSVG: return "unsupported-svg"
        case .mediaQueries: return "media-queries"
        case .calcOrModernFunctions: return "calc-modern-functions"
        case .unparseableLayoutCSS: return "unparseable-layout-css"
        case .unknownBlockDisplay: return "unknown-block-display"
        }
    }
}

struct BrowserLayoutCapabilityResult: Equatable {
    let supported: Bool
    let unsupportedFeatures: [UnsupportedFeature]

    static let supported = BrowserLayoutCapabilityResult(supported: true, unsupportedFeatures: [])
}

/// DOM-aware capability scanner. Runs BEFORE any browser-engine layout and
/// decides, per chapter, whether the browser engine can render it correctly.
///
/// Phase 4B accepts: horizontal reflowable EPUB, block/inline, supported CSS Float
/// (replaced images, explicit/percent width boxes, clear: left/right/both),
/// supported box model, supported white-space, plain text, links, anchors, basic images.
enum BrowserLayoutCapabilityScanner {

    /// A matched declaration that would change layout and is not implemented.
    /// Carries the matched element's tag/class and the property for diagnosis
    /// (never book content).
    struct UnsupportedDeclaration: CustomStringConvertible {
        let feature: UnsupportedFeature
        let selector: String
        let tag: String
        let classes: [String]
        let property: String

        var description: String {
            "\(feature.description) via '\(selector)' on <\(tag)>\(classes.isEmpty ? "" : ".\(classes.joined(separator: "."))") property \(property)"
        }
    }

    static func scan(html: String, cssTexts: [String]) -> BrowserLayoutCapabilityResult {
        var reasons: [UnsupportedFeature] = []
        var unsupportedDeclarations: [UnsupportedDeclaration] = []

        // @media anywhere in the stylesheet affects layout for every chapter
        // that links it (the media query is not re-evaluated per element).
        for css in cssTexts {
            if cssContainsMediaQuery(css) { reasons.append(.mediaQueries) }
        }

        // DOM-level checks (script, MathML, SVG semantics, table/float/flex in markup).
        if let doc = try? SwiftSoup.parse(html) {
            let fullCSS = cssTexts + LegacyCSSFrontendSupport.inlineStyles(in: doc)
            func hasAny(_ selector: String) -> Bool {
                ((try? doc.select(selector).isEmpty()) ?? true) == false
            }
            if hasAny("script, iframe, object, embed, canvas, audio, video") {
                reasons.append(.scriptedInteractive)
            }
            if hasAny("math") {
                reasons.append(.mathML)
            }
            if hasAny("ruby, rp, rt") {
                reasons.append(.ruby)
            }
            if hasAny("table, thead, tbody, tr, td, th, colgroup") {
                reasons.append(.table)
            }
            let svgs = (try? doc.select("svg").array()) ?? []
            if svgs.contains(where: { BoxTreeBuilder.svgWrappedImageSource($0) == nil }) {
                reasons.append(.unsupportedSVG)
            }

            // CSS rules: match selectors against the real DOM. Only declarations
            // from selectors that match at least one element are judged.
            let elements = (try? doc.getAllElements().array()) ?? []
            for css in LegacyCSSFrontendSupport.inlineStyles(in: doc) {
                if cssContainsMediaQuery(css) { reasons.append(.mediaQueries) }
            }
            for css in fullCSS {
                var matchedAnyUnsupported = false
                for rule in CSSParser.parse(css: css, orderOffset: 0) {
                    let matchedElements = elements.filter { element in
                        guard rule.selector.matches(element: element, parent: element.parent()) else { return false }
                        return true
                    }
                    guard !matchedElements.isEmpty else { continue }  // unmatched rule → ignore

                    for property in rule.declarationOrder {
                        guard let value = rule.declarations[property] else { continue }
                        if let feature = layoutAffectingDeclaration(key: property, value: value) {
                            reasons.append(feature)
                            if !matchedAnyUnsupported, let first = matchedElements.first {
                                unsupportedDeclarations.append(UnsupportedDeclaration(
                                    feature: feature, selector: rule.selector.debugDescription,
                                    tag: first.tagName(), classes: ((try? first.classNames().map { $0 }) ?? []),
                                    property: property
                                ))
                                matchedAnyUnsupported = true
                            }
                        }
                    }
                    for (property, value) in rule.importantDeclarations {
                        if let feature = layoutAffectingDeclaration(key: property, value: value) {
                            reasons.append(feature)
                        }
                    }
                }
            }

            // Element inline style attributes — always apply to this chapter.
            for element in (try? doc.select("[style]").array()) ?? [] {
                let inline = (try? element.attr("style")) ?? ""
                let decl = CSSParser.parseDeclarationBlock(inline)
                for (key, value) in decl.normal {
                    if let reason = layoutAffectingDeclaration(key: key, value: value) {
                        reasons.append(reason)
                    }
                }
                for (key, value) in decl.important {
                    if let reason = layoutAffectingDeclaration(key: key, value: value) {
                        reasons.append(reason)
                    }
                }
            }

            // Float classification must use the SAME resolved cascade as layout.
            // Replaying declarations here used to get `float: none`, inline
            // priority, specificity, !important, and width:auto resets wrong.
            if let body = doc.body() {
                let rules = LegacyCSSFrontendSupport.parseRules(in: fullCSS)
                let styleTree = ComputedStyleTreeBuilder(
                    rules: rules,
                    config: BrowserLayoutConfig()
                ).buildTree(body: body)
                validateFloats(in: styleTree, hasFloatedAncestor: false, reasons: &reasons)
            }
        }

        return BrowserLayoutCapabilityResult(
            supported: reasons.isEmpty,
            unsupportedFeatures: dedupe(reasons)
        )
    }

    private static func validateFloats(
        in node: ComputedStyleNode,
        hasFloatedAncestor: Bool,
        reasons: inout [UnsupportedFeature]
    ) {
        let isFloated = node.style.isFloated
        if isFloated {
            let isReplaced = node.tag == "img"
                || (node.tag == "svg" && node.element.flatMap(BoxTreeBuilder.svgWrappedImageSource) != nil)
            // Non-replaced floats with width:auto need CSS shrink-to-fit, which
            // Phase 4B deliberately does not guess. max-width alone does not
            // turn width:auto into a definite used width.
            if (!isReplaced && node.style.width == .auto) || hasFloatedAncestor {
                reasons.append(.float)
            }
        }

        for child in node.children {
            guard case .element(let childNode) = child else { continue }
            validateFloats(
                in: childNode,
                hasFloatedAncestor: hasFloatedAncestor || isFloated,
                reasons: &reasons
            )
        }
    }

    // MARK: - CSS text scanning (media queries only)

    private static func cssContainsMediaQuery(_ css: String) -> Bool {
        let cleaned = css.replacingOccurrences(of: #"(?s)/\*.*?(?:\*/|\z)"#, with: "", options: .regularExpression)
        return regexMatch(#"@media\b"#, in: cleaned)
    }

    /// Layout-affecting CSS declarations. Paint-only properties
    /// (background-image, background-size, background-position,
    /// background-attachment, border-radius, text-shadow, …) are NOT layout
    /// features — they are paint degradation at worst and must never reject a
    /// chapter.
    private static func layoutAffectingDeclaration(key: String, value: String) -> UnsupportedFeature? {
        let k = key.lowercased()
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if k == "float" || k == "clear" {
            // Float is validated at the element level (supported for images / explicit widths)
            return nil
        }
        if k == "position" && (v.contains("absolute") || v.contains("fixed") || v.contains("sticky")) {
            return .positioned
        }
        if k == "display" && (v.contains("table") || v.contains("flex") || v.contains("grid")) {
            return .unknownBlockDisplay
        }
        if k == "flex" || k == "flex-direction" || k == "flex-wrap" || k == "flex-basis"
            || k == "flex-grow" || k == "flex-shrink" || k == "justify-content"
            || k == "align-items" || k.hasPrefix("grid-") || k == "gap" {
            return .flexGrid
        }
        if v.contains("calc(") || v.contains("min(") || v.contains("max(") || v.contains("clamp(") {
            return .calcOrModernFunctions
        }
        if k == "ruby-align" || k == "ruby-position" { return .ruby }
        if k == "writing-mode"
            || k == "-webkit-writing-mode"
            || k == "-epub-writing-mode" {
            if v.contains("vertical") { return .verticalWritingMode }
        }
        return nil
    }

    private static func regexMatch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func dedupe(_ reasons: [UnsupportedFeature]) -> [UnsupportedFeature] {
        var seen = Set<UnsupportedFeature>()
        return reasons.filter { seen.insert($0).inserted }
    }
}

extension CSSSelector {
    var debugDescription: String {
        "selector"
    }
}
