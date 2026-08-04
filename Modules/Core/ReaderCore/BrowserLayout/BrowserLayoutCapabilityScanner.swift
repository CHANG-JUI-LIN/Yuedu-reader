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

/// Conservative capability scanner. Runs BEFORE any browser-engine layout and
/// decides, per chapter, whether the browser engine can render it correctly.
///
/// Phase 2A accepts: horizontal reflowable EPUB, block/inline, the supported
/// box model, supported white-space, plain text, links, anchors, basic images.
///
/// Anything that could change LAYOUT and is not implemented falls back the
/// WHOLE chapter to the legacy engine. Paint-only unsupported properties
/// (background-image, text-shadow, …) do not affect layout and are allowed.
enum BrowserLayoutCapabilityScanner {

    private static let verticalWritingModePatterns: [(String, String)] = [
        ("-epub-writing-mode", #"-epub-writing-mode\s*:\s*vertical-(rl|lr)"#),
        ("-webkit-writing-mode", #"-webkit-writing-mode\s*:\s*vertical-(rl|lr)"#),
        ("writing-mode", #"(^|[;\s{])writing-mode\s*:\s*vertical-(rl|lr)"#),
    ]

    static func scan(html: String, cssTexts: [String]) -> BrowserLayoutCapabilityResult {
        var reasons: [UnsupportedFeature] = []

        for css in cssTexts {
            if cssContainsMediaQuery(css) { reasons.append(.mediaQueries) }
            if cssContainsCalcOrModernFunctions(css) { reasons.append(.calcOrModernFunctions) }
            for (_, pattern) in verticalWritingModePatterns {
                if regexMatch(pattern, in: css) {
                    reasons.append(.verticalWritingMode)
                    break
                }
            }
            for reason in cssLayoutFeatures(in: css) where !reasons.contains(reason) {
                reasons.append(reason)
            }
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
            if hasAny("svg") {
                reasons.append(.unsupportedSVG)
            }
            for element in (try? doc.select("[style]").array()) ?? [] {
                let inline = (try? element.attr("style")) ?? ""
                let decl = CSSParser.parseDeclarationBlock(inline)
                for (key, value) in decl.merged {
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

    // MARK: - CSS text scanning

    private static func cssContainsMediaQuery(_ css: String) -> Bool {
        // Strip comments first so a commented-out @media cannot trigger.
        let cleaned = css.replacingOccurrences(of: #"(?s)/\*.*?(?:\*/|\z)"#, with: "", options: .regularExpression)
        return regexMatch(#"@media\b"#, in: cleaned)
    }

    private static func cssContainsCalcOrModernFunctions(_ css: String) -> Bool {
        regexMatch(#"calc\s*\(|min\s*\(|max\s*\(|clamp\s*\("#, in: css)
    }

    /// Layout-affecting CSS features inside the stylesheet text.
    private static func cssLayoutFeatures(in css: String) -> [UnsupportedFeature] {
        var reasons: [UnsupportedFeature] = []
        let cleaned = css.replacingOccurrences(of: #"(?s)/\*.*?(?:\*/|\z)"#, with: "", options: .regularExpression)

        // Property-level rejections (any declaration with these property names).
        let layoutProperties: [(String, UnsupportedFeature)] = [
            (#"float\s*:"#, .float),
            (#"position\s*:\s*(absolute|fixed|sticky)"#, .positioned),
            (#"ruby-align\s*:|ruby-position\s*:"#, .ruby),
            (#"display\s*:\s*(table|inline-table|flex|inline-flex|grid|inline-grid)"#, .unknownBlockDisplay),
            (#"flex\s*:|flex-direction\s*:|flex-wrap\s*:|flex-basis\s*:|flex-grow\s*:|flex-shrink\s*:|justify-content\s*:|align-items\s*:|grid-template|gap\s*:"#, .flexGrid),
        ]
        for (pattern, reason) in layoutProperties {
            if regexMatch(pattern, in: cleaned) { reasons.append(reason) }
        }

        // Selector-level: generated content changes layout — not implemented.
        if regexMatch(#"::before|::after|\bcontent\s*:"#, in: cleaned) {
            reasons.append(.unparseableLayoutCSS)
        }
        return reasons
    }

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
        if v.contains("calc(") || v.contains("min(") || v.contains("max(") || v.contains("clamp(") {
            return .calcOrModernFunctions
        }
        if k == "ruby-align" || k == "ruby-position" { return .ruby }
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
