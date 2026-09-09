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
        stylesheets.filter { !$0.currentCompatibilityOnly && !$0.isAlternate && !$0.loadFailed && $0.hasSupportedMedia }
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

    /// Failed resource entries retain their identity/diagnostic but never enter cascade.
    /// An empty successfully loaded stylesheet remains a valid author entry.
    let loadFailed: Bool

    init(source: Source, text: String, sourceOrder: Int,
         currentCompatibilityOrder: Int?, currentCompatibilityOnly: Bool,
         media: String?, isAlternate: Bool, loadFailed: Bool = false) {
        self.source = source
        self.text = text
        self.sourceOrder = sourceOrder
        self.currentCompatibilityOrder = currentCompatibilityOrder
        self.currentCompatibilityOnly = currentCompatibilityOnly
        self.media = media
        self.isAlternate = isAlternate
        self.loadFailed = loadFailed
    }

    var identity: StylesheetIdentity {
        let label: String
        switch source {
        case .inline(let ordinal): label = "inline[\(ordinal)]"
        case .linked(let href): label = href
        }
        return StylesheetIdentity(sourceOrder: sourceOrder, label: label)
    }

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
    let selector: String?
    let stylesheet: StylesheetIdentity?

    init(nodeID: UInt64, property: String, value: String, specificity: UInt32,
         sourceOrder: UInt32, origin: UInt8, important: Bool,
         selector: String? = nil, stylesheet: StylesheetIdentity? = nil) {
        self.nodeID = nodeID
        self.property = property
        self.value = value
        self.specificity = specificity
        self.sourceOrder = sourceOrder
        self.origin = origin
        self.important = important
        self.selector = selector
        self.stylesheet = stylesheet
    }

    var source: StyleSourceIdentity {
        StyleSourceIdentity(origin: origin == 1 ? .inlineStyle : .authorStylesheet,
                            stylesheet: stylesheet, selector: selector,
                            specificity: specificity, sourceOrder: Int(sourceOrder), important: important)
    }
}

struct StyleSourceIdentity: Hashable, Codable {
    enum Origin: String, Codable { case authorStylesheet, inlineStyle }
    let origin: Origin
    let stylesheet: StylesheetIdentity?
    let selector: String?
    let specificity: UInt32
    let sourceOrder: Int
    let important: Bool
}

enum FrontendDOMFeature: String, Hashable {
    case table, mathML, scriptedInteractive, unsupportedSVG, hiddenRoot
}

struct FrontendUnsupportedDeclaration: Equatable {
    let semanticPath: String
    let property: String
    let value: String
    let source: StyleSourceIdentity
    let feature: UnsupportedFeature
    let reason: String
}

struct FrontendCapabilityFacts: Equatable {
    var unsupportedDeclarations: [FrontendUnsupportedDeclaration] = []
    var domFeatures: Set<FrontendDOMFeature> = []
    var ingestionFailures: [StylesheetIdentity] = []

    var blocksCutover: Bool {
        !unsupportedDeclarations.isEmpty || !domFeatures.isEmpty || !ingestionFailures.isEmpty
    }

    mutating func recordAdapterGap(_ declaration: FrontendWinningDeclaration,
                                  semanticPath: String = "", reason: String = "Unsupported value") {
        let fact = FrontendUnsupportedDeclaration(
            semanticPath: semanticPath, property: declaration.property, value: declaration.value,
            source: declaration.source, feature: .unparseableLayoutCSS, reason: "ADAPTER_GAP: " + reason
        )
        if !unsupportedDeclarations.contains(fact) { unsupportedDeclarations.append(fact) }
    }
}

struct LexborTextSnapshot: Equatable {
    let nodeID: UInt64
    let parentID: UInt64
    let text: String
}

struct LexborFrontendSnapshot: Equatable {
    let elements: [UInt64: HTMLDOMElementSnapshot]
    let parentIDs: [UInt64: UInt64]
    let textOrder: [LexborTextSnapshot]
    let winningDeclarations: [FrontendWinningDeclaration]
    let diagnostics: [CSSFrontendDiagnostic]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elements == rhs.elements
            && lhs.parentIDs == rhs.parentIDs
            && lhs.textOrder == rhs.textOrder
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
