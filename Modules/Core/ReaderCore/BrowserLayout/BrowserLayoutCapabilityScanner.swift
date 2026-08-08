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
/// Phase 2A accepts: horizontal reflowable EPUB, block/inline, the supported
/// box model, supported white-space, plain text, links, anchors, basic images.
///
/// A shared stylesheet may declare unsupported features (float, ruby, calc…)
/// for OTHER chapters. The scanner therefore judges capability from what
/// actually APPLIES to this chapter's DOM:
///   - CSS rules are matched against the real DOM elements; only declarations
///     of MATCHED selectors are considered (unmatched rules are ignored).
///   - element inline `style` attributes are checked directly.
///   - DOM-level markers (script, MathML, ruby, table, svg) are checked on the
///     actual markup.
///   - paint-only unsupported properties (background-image, text-shadow,
///     border-radius, background-attachment…) do NOT affect layout and are
///     allowed — they are paint degradation at worst, never a layout rejection.
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
            // An SVG used purely to wrap one raster image (the standard EPUB
            // cover) is renderable — only real vector content is unsupported.
            // Same predicate as the box tree, so the two cannot disagree.
            let svgs = (try? doc.select("svg").array()) ?? []
            if svgs.contains(where: { BoxTreeBuilder.svgWrappedImageSource($0) == nil }) {
                reasons.append(.unsupportedSVG)
            }

            // CSS rules: match selectors against the real DOM. Only declarations
            // from selectors that match at least one element are judged.
            let elements = (try? doc.getAllElements().array()) ?? []
            for css in cssTexts {
                var matchedAnyUnsupported = false
                for rule in CSSParser.parse(css: css, orderOffset: 0) {
                    let matchedElements = elements.filter { element in
                        guard rule.selector.matches(element: element, parent: element.parent()) else { return false }
                        return true
                    }
                    guard !matchedElements.isEmpty else { continue }  // unmatched rule → ignore

                    for (property, value) in rule.declarations {
                        if let feature = layoutAffectingDeclaration(key: property, value: value) {
                            reasons.append(feature)
                            if !matchedAnyUnsupported, let first = matchedElements.first {
                                unsupportedDeclarations.append(UnsupportedDeclaration(
                                    feature: feature, selector: rule.selector.debugDescription,
                                    tag: (try? first.tagName()) ?? "", classes: ((try? first.classNames().map { $0 }) ?? []),
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
        }

        return BrowserLayoutCapabilityResult(
            supported: reasons.isEmpty,
            unsupportedFeatures: dedupe(reasons)
        )
    }

    // MARK: - CSS text scanning (media queries only)

    private static func cssContainsMediaQuery(_ css: String) -> Bool {
        // Strip comments first so a commented-out @media cannot trigger.
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
        if k == "float" { return .float }
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
