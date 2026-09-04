import Foundation

/// Value-only input shared by Current and Lexbor frontends. Resource loading
/// remains outside the frontend; each stylesheet carries enough identity to
/// preserve authored order and diagnose a differential later in the migration.
struct CSSFrontendInput {
    let html: String
    let stylesheets: [AuthorStylesheet]

    init(html: String, stylesheets: [AuthorStylesheet]) {
        self.html = html
        self.stylesheets = stylesheets
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
