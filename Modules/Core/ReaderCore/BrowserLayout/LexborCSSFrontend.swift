import Foundation

/// Lexbor owns syntax, selector matching and cascade. Only copied Swift values
/// enter the style tree; every build releases its document before returning.
final class LexborCSSFrontend: CSSFrontend {
    init() {}

    /// Source compatibility for the initial snapshot tests. No C owner is kept.
    init(input: CSSFrontendInput) throws {
        guard !input.html.isEmpty else { throw LexborDocumentOwner.Error.invalidInput }
    }

    func snapshot(input: CSSFrontendInput) throws -> LexborFrontendSnapshot {
        try Task.checkCancellation()
        let result: LexborFrontendSnapshot
        do {
            let owner = try LexborDocumentOwner(html: input.html)
            result = try LexborHTMLSemanticAdapter.snapshot(owner: owner, input: input)
        }
        try Task.checkCancellation()
        return result
    }

    func buildStyleTree(
        input: CSSFrontendInput,
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        let snapshot = try metrics.time("lexborFrontendSnapshot") { try snapshot(input: input) }
        return try metrics.time("styleTree") {
            try LexborValueStyleTree(snapshot: snapshot, config: config).build()
        }
    }
}

/// Document-local value traversal. Ordering comes from Lexbor's preorder IDs;
/// text and elements share that order, so inline source ranges remain intact.
private final class LexborValueStyleTree {
    let snapshot: LexborFrontendSnapshot
    let config: BrowserLayoutConfig
    let children: [UInt64: [UInt64]]
    let texts: [UInt64: String]
    let declarations: [UInt64: [FrontendWinningDeclaration]]
    var facts = FrontendCapabilityFacts()
    var sources: [String: [String: StyleSourceIdentity]] = [:]
    var nextLayoutNodeID = 1

    init(snapshot: LexborFrontendSnapshot, config: BrowserLayoutConfig) {
        self.snapshot = snapshot
        self.config = config
        var ordered = Dictionary(grouping: snapshot.elements.keys, by: { snapshot.parentIDs[$0] ?? 0 })
        for text in snapshot.textOrder { ordered[text.parentID, default: []].append(text.nodeID) }
        self.children = ordered.mapValues { $0.sorted() }
        self.texts = Dictionary(uniqueKeysWithValues: snapshot.textOrder.map { ($0.nodeID, $0.text) })
        self.declarations = Dictionary(grouping: snapshot.winningDeclarations, by: \.nodeID)
    }

    func build() throws -> CSSFrontendResult {
        guard let bodyID = snapshot.elements.keys.sorted().first(where: { snapshot.elements[$0]?.tagName == "body" }) else {
            throw BrowserLayoutDocument.BrowserLayoutError.emptyBody
        }
        var parent = defaultParent()
        // Compute the ancestors as well: html font/color declarations inherit
        // into body. The reader-provided rem base remains config.rootFontSize.
        var ancestors: [UInt64] = []
        var ancestor = snapshot.parentIDs[bodyID]
        while let id = ancestor, snapshot.elements[id] != nil {
            ancestors.append(id)
            ancestor = snapshot.parentIDs[id]
        }
        for id in ancestors.reversed() {
            parent = resolvedStyle(id, parent: parent)
            // Root suppression cannot be expressed through inherited display:
            // the current layout entry always constructs a body box.
            if parent.isHidden { facts.domFeatures.insert(.hiddenRoot) }
        }
        for diagnostic in snapshot.diagnostics where diagnostic.message != "inactive alternate stylesheet" {
            let identity = diagnostic.stylesheet ?? StylesheetIdentity(sourceOrder: -1, label: "frontend-input")
            if !facts.ingestionFailures.contains(identity) { facts.ingestionFailures.append(identity) }
        }
        let root = node(bodyID, parent: parent, inheritedLink: nil)
        if root.style.isHidden { facts.domFeatures.insert(.hiddenRoot) }
        return CSSFrontendResult(
            rootNode: root, linkAnchors: ComputedStyleTreeBuilder.collectLinkAnchors(root),
            footnotes: collectFootnotes(), nodeCount: nextLayoutNodeID - 1,
            capabilityFacts: facts, diagnostics: snapshot.diagnostics, styleSources: sources
        )
    }

    func defaultParent() -> ComputedStyle {
        var parent = ComputedStyle(fontSize: config.rootFontSize, fontFamilies: config.fontFamilies,
                                   color: config.textColor, backgroundColor: config.backgroundColor,
                                   textAlign: config.defaultTextAlignment)
        if let multiple = config.lineHeight, multiple > 0 {
            parent.lineHeightMultiplier = multiple
            parent.lineHeight = config.rootFontSize * multiple
        }
        parent.configLineSpacing = max(0, config.lineSpacing)
        parent.configParagraphSpacing = max(0, config.paragraphSpacing)
        parent.configLetterSpacing = config.letterSpacing
        parent.configBold = config.isBold
        return parent
    }

    func resolvedStyle(_ id: UInt64, parent: ComputedStyle) -> ComputedStyle {
        guard let element = snapshot.elements[id] else { return parent }
        var inheritedParent = parent
        // text-indent inherits its computed font-relative length, not an em
        // token to be resolved again against the descendant's different font.
        switch inheritedParent.textIndent {
        case .length(.em(let value)): inheritedParent.textIndent = .length(.px(value * parent.fontSize))
        case .length(.rem(let value)): inheritedParent.textIndent = .length(.px(value * config.rootFontSize))
        default: break
        }
        var style = inheritedParent.inherited(from: inheritedParent)
        style = style.applyingUA(UserAgentStyle.basis(for: element.tagName))
        if element.tagName == "rt" { style.fontSize = parent.fontSize * 0.5 }
        // CSS border defaults differ from the legacy model's convenience defaults.
        style.borderTopWidth = 3; style.borderRightWidth = 3
        style.borderBottomWidth = 3; style.borderLeftWidth = 3
        style.borderTopStyle = .none; style.borderRightStyle = .none
        style.borderBottomStyle = .none; style.borderLeftStyle = .none
        style.borderColor = style.color
        ComputedStyleTreeBuilder.applyPresentationalHints(
            HTMLPresentationalHintExtractor.extract(from: element.htmlSemanticElement), to: &style
        )
        let winners = declarations[id] ?? []
        LexborComputedStyleAdapter.apply(winners: winners, to: &style, parent: parent,
                                        config: config, facts: &facts, semanticPath: element.semanticPath)
        if style.borderTopStyle == .none { style.borderTopWidth = 0 }
        if style.borderRightStyle == .none { style.borderRightWidth = 0 }
        if style.borderBottomStyle == .none { style.borderBottomWidth = 0 }
        if style.borderLeftStyle == .none { style.borderLeftWidth = 0 }
        if !(winners.contains { $0.property == "border-color" }) { style.borderColor = style.color }
        if element.attribute("hidden") != nil { style.isHidden = true }
        var winningSources: [String: StyleSourceIdentity] = [:]
        for winner in winners { winningSources[winner.property] = winner.source }
        sources[element.semanticPath] = winningSources
        return style
    }

    func node(_ id: UInt64, parent: ComputedStyle, inheritedLink: String?) -> ComputedStyleNode {
        let element = snapshot.elements[id]!
        let style = resolvedStyle(id, parent: parent)
        switch element.tagName {
        case "table": facts.domFeatures.insert(.table)
        case "math": facts.domFeatures.insert(.mathML)
        case "script": facts.domFeatures.insert(.scriptedInteractive)
        case "svg" where element.svgRenderability == .unsupportedVector: facts.domFeatures.insert(.unsupportedSVG)
        default: break
        }
        let ownLink = element.tagName == "a" ? element.attribute("href") : nil
        let link = ownLink.flatMap { $0.isEmpty ? nil : $0 } ?? inheritedLink
        var styleChildren: [StyleTreeChild] = []
        for childID in children[id] ?? [] {
            if let text = texts[childID] { styleChildren.append(.text(text)) }
            else if snapshot.elements[childID] != nil {
                let firstChildID = nextLayoutNodeID
                let child = node(childID, parent: style, inheritedLink: link)
                if !child.style.isHidden { styleChildren.append(.element(child)) }
                else {
                    // Hidden subtrees retain diagnostic paths, but consume no
                    // layout identities, matching the Current tree contract.
                    nextLayoutNodeID = firstChildID
                }
            }
        }
        // Layout-facing IDs use the existing postorder contract. Raw DOM
        // preorder IDs remain in the immutable snapshot for differential work.
        let layoutID = nextLayoutNodeID
        nextLayoutNodeID += 1
        return ComputedStyleNode(
            tag: element.tagName, semanticElement: element, style: style, children: styleChildren,
            nodeID: layoutID, linkTarget: link,
            anchorID: element.attribute("id").flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func collectFootnotes() -> [String: String] {
        var notes: [String: String] = [:]
        for id in snapshot.elements.keys.sorted() {
            guard let element = snapshot.elements[id], let anchor = element.attribute("id"), !anchor.isEmpty else { continue }
            let types = Set((element.attribute("epub:type") ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let isDuokan = element.tagName == "li" && element.classTokens.contains(where: { $0.contains("footnote") })
            guard isDuokan || !types.isDisjoint(with: ["footnote", "endnote", "note", "rearnote"]) else { continue }
            let text = plainText(id).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { notes[anchor] = text }
        }
        return notes
    }

    func plainText(_ id: UInt64) -> String {
        (children[id] ?? []).map { childID in
            if let text = texts[childID] { return text }
            guard let element = snapshot.elements[childID] else { return "" }
            let text = plainText(childID)
            return UserAgentStyle.basis(for: element.tagName).display == .block || element.tagName == "br"
                ? " " + text + " " : text
        }.joined()
    }
}
