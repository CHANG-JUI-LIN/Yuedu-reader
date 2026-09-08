import Foundation

/// Value-only input shared by Current and Lexbor frontends. Resource loading
/// remains outside the frontend; each stylesheet carries enough identity to
/// preserve authored order and diagnose a differential later in the migration.
struct CSSFrontendInput {
    let html: String
    let stylesheets: [AuthorStylesheet]
    let diagnostics: [CSSFrontendDiagnostic]

    init(html: String, stylesheets: [AuthorStylesheet], diagnostics: [CSSFrontendDiagnostic] = []) {
        self.html = html
        self.stylesheets = stylesheets
        self.diagnostics = diagnostics
    }

    /// Lexbor consumes each active authored sheet exactly once, in DOM order.
    /// Unsupported media remains in `stylesheets` and diagnostics for the gate.
    var activeAuthorStylesheets: [AuthorStylesheet] {
        stylesheets.filter { !$0.currentCompatibilityOnly && !$0.isAlternate && $0.hasSupportedMedia }
            .sorted { $0.sourceOrder < $1.sourceOrder }
    }

    /// Compatibility boundary for existing callers that still provide an
    /// ordered `[String]`. Task 5 replaces production ingestion with authored
    /// stylesheet identities while retaining this helper for focused tests.
    static func currentCompatibility(html: String, cssTexts: [String]) -> Self {
        let stylesheets = cssTexts.enumerated().map { index, text in
            AuthorStylesheet(
                source: .linked(href: "current-compatibility://stylesheet/\(index)"),
                text: text,
                sourceOrder: index,
                currentCompatibilityOrder: index,
                currentCompatibilityOnly: false,
                media: nil,
                isAlternate: false
            )
        }
        return CSSFrontendInput(html: html, stylesheets: stylesheets)
    }
}

struct AuthorStylesheet: Equatable {
    enum Source: Equatable {
        case inline(nodeOrdinal: Int)
        case linked(href: String)
    }

    let source: Source
    let text: String
    let sourceOrder: Int
    let currentCompatibilityOrder: Int?
    let currentCompatibilityOnly: Bool
    let media: String?
    let isAlternate: Bool

    var hasSupportedMedia: Bool {
        let value = (media ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "all"
    }
}

struct StylesheetIdentity: Hashable, Codable {
    let sourceOrder: Int
    let label: String
}

struct CSSFrontendDiagnostic: Equatable {
    enum Stage: Equatable {
        case html
        case css
        case selector
        case style
        case ingestion
        case adapter
        case allocation
    }

    let stage: Stage
    let stylesheet: StylesheetIdentity?
    let semanticPath: String?
    let property: String?
    let message: String
}

struct FrontendWinningDeclaration: Equatable {
    let nodeID: UInt64
    let property: String
    let value: String
    let specificity: UInt32
    let sourceOrder: UInt32
    let origin: UInt8
    let important: Bool
}

struct LexborFrontendSnapshot: Equatable {
    let elements: [UInt64: HTMLDOMElementSnapshot]
    let parentIDs: [UInt64: UInt64]
    let textOrder: [(nodeID: UInt64, text: String)]
    let winningDeclarations: [FrontendWinningDeclaration]
    let diagnostics: [CSSFrontendDiagnostic]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elements == rhs.elements
            && lhs.parentIDs == rhs.parentIDs
            && lhs.textOrder.map { "\($0.nodeID):\($0.text)" } == rhs.textOrder.map { "\($0.nodeID):\($0.text)" }
            && lhs.winningDeclarations == rhs.winningDeclarations
            && lhs.diagnostics == rhs.diagnostics
    }
}

/// Pointer-free DOM identity consumed after the frontend returns. Neither a
/// SwiftSoup object nor a Lexbor handle may cross this boundary.
struct HTMLDOMElementSnapshot: Equatable {
    let semanticPath: String
    let tagName: String
    let namespace: String?
    let attributes: [String: String]
    let svgRenderability: SVGRenderability?

    init(
        semanticPath: String,
        tagName: String,
        namespace: String?,
        attributes: [String: String],
        svgRenderability: SVGRenderability?
    ) {
        self.semanticPath = semanticPath
        self.tagName = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.namespace = namespace
        var normalized: [String: String] = [:]
        for key in attributes.keys.sorted() {
            normalized[key.lowercased()] = attributes[key]
        }
        self.attributes = normalized
        self.svgRenderability = svgRenderability
    }

    func attribute(_ name: String) -> String? {
        attributes[name.lowercased()]
    }

    var classTokens: [String] {
        (attribute("class") ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    var htmlSemanticElement: HTMLSemanticElement {
        HTMLSemanticElement(tagName: tagName, attributes: attributes)
    }

    var linkSemantic: LinkSemantic {
        let epub = LinkSemantic.from(epubType: attribute("epub:type") ?? "")
        if epub != .plain { return epub }
        let roles = (attribute("role") ?? "")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        return roles.contains("doc-noteref") ? .noteref : .plain
    }

    /// Temporary source-compatibility helper for diagnostic tests written
    /// against SwiftSoup's throwing API. It still returns copied value data.
    func classNames() throws -> Set<String> {
        Set(classTokens)
    }
}

enum SVGRenderability: Equatable {
    case rasterWrapper(source: String)
    case unsupportedVector
}
