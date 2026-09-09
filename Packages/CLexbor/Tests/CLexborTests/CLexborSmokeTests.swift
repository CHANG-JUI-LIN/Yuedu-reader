import CLexbor
import Testing

@Suite(.serialized)
struct CLexborSmokeTests {
    @Test func reportsPinnedVersion() {
        #expect(String(cString: ylx_lexbor_version()) == "3.0.0")
    }

    @Test func parsesAndDestroysValidXHTML() {
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Hello</p></body></html>"
        var status = YLX_STATUS_OK
        let document = withDocumentBytes(html) { bytes in
            ylx_document_create(bytes.baseAddress, bytes.count, &status)
        }

        #expect(status == YLX_STATUS_OK)
        #expect(document != nil)
        #expect(ylx_document_element_count(document) >= 3)
        ylx_document_destroy(document)
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func recoversMalformedHTML() {
        let html = "<html><body><section><p>Recovered"
        var status = YLX_STATUS_OK
        let document = withDocumentBytes(html) { bytes in
            ylx_document_create(bytes.baseAddress, bytes.count, &status)
        }

        #expect(status == YLX_STATUS_OK)
        #expect(document != nil)
        #expect(ylx_document_element_count(document) >= 4)
        ylx_document_destroy(document)
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func rejectsEmptyInputWithoutLeaking() {
        var status = YLX_STATUS_OK
        let document = ylx_document_create(nil, 0, &status)

        #expect(document == nil)
        #expect(status == YLX_STATUS_INVALID_ARGUMENT)
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func sequentialCreateDestroyLeavesNoLiveDocuments() {
        #expect(ylx_debug_live_document_count() == 0)

        for index in 0..<6 {
            let html = "<html><body><p>Cycle \(index)</p></body></html>"
            var status = YLX_STATUS_OK
            let document = withDocumentBytes(html) { bytes in
                ylx_document_create(bytes.baseAddress, bytes.count, &status)
            }

            #expect(status == YLX_STATUS_OK)
            #expect(document != nil)
            #expect(ylx_debug_live_document_count() == 1)
            ylx_document_destroy(document)
            #expect(ylx_debug_live_document_count() == 0)
        }
    }

    @Test func walksValueSnapshotsAndAttachesStylesheets() {
        let html = "<html><body><p class='lead' style='color: red'>Hello <em>world</em></p></body></html>"
        var status = YLX_STATUS_OK
        var elementNames: [String] = []
        var textValues: [String] = []
        var declarationProperties: [String] = []
        let document = withDocumentBytes(html) { bytes in
            ylx_document_create(bytes.baseAddress, bytes.count, &status)
        }
        #expect(document != nil)
        let css = "p.lead { color: blue; width: 15%; }"
        let cssStatus = withDocumentBytes(css) { bytes in
            ylx_document_attach_stylesheet(document, bytes.baseAddress, bytes.count, 0)
        }
        #expect(cssStatus == YLX_STATUS_OK)
        let context = SnapshotContext()
        let walkStatus = ylx_document_walk(document, snapshotElement, snapshotAttribute, snapshotText, Unmanaged.passUnretained(context).toOpaque())
        #expect(walkStatus == YLX_STATUS_OK)
        let declarationStatus = ylx_document_walk_winning_declarations(document, snapshotDeclaration, Unmanaged.passUnretained(context).toOpaque())
        #expect(declarationStatus == YLX_STATUS_OK)
        elementNames = context.elements
        textValues = context.texts
        declarationProperties = context.declarations
        #expect(elementNames.contains("P"))
        #expect(textValues.contains("Hello "))
        #expect(textValues.contains("world"))
        #expect(declarationProperties.contains("color"))
        #expect(declarationProperties.contains("width"))
        #expect(context.declarationNodeIDs.allSatisfy { $0 == context.paragraphID })
        ylx_document_destroy(document)
    }
    @Test func inlineStylesWorkWithoutStylesheetsAndWalksAreStable() throws {
        let document = try createDocument("<p style='color: red; width: 25%; ruby-position: under'>Hello</p>")
        defer { ylx_document_destroy(document) }
        let first = try snapshot(document)
        let second = try snapshot(document)
        #expect(first.values == second.values)
        #expect(first.values.count == 3)
        #expect(first.values.first { $0.property == "color" }?.value == "red")
        #expect(first.values.first { $0.property == "width" }?.value == "25%")
        #expect(first.values.first { $0.property == "ruby-position" }?.value == "under")
        #expect(first.values.allSatisfy { $0.origin == 1 && $0.selector.isEmpty })
    }

    @Test func acceptsEmptyStylesheetAndReportsInvalidArguments() throws {
        let document = try createDocument("<p style='color: red'>Text</p>")
        defer { ylx_document_destroy(document) }
        #expect(ylx_document_attach_stylesheet(document, nil, 0, 17) == YLX_STATUS_OK)
        #expect(ylx_document_attach_stylesheet(document, nil, 2, 17) == YLX_STATUS_INVALID_ARGUMENT)
        #expect(ylx_document_attach_stylesheet(nil, nil, 0, 17) == YLX_STATUS_INVALID_ARGUMENT)
        try attach(" /* valid empty sheet */ ", to: document, sourceOrder: 18)
        #expect(try snapshot(document).values.count == 1)
    }

    @Test func onlyEmitsCascadeWinnersWithSelectorAndSourceIdentity() throws {
        let document = try createDocument("<p id='target' class='lead' style='color: red; height: 7px !important'>Text</p>")
        defer { ylx_document_destroy(document) }
        try attach("#target { color: green; width: 1px; height: 9px !important } p { width: 2px; width: 3px }", to: document, sourceOrder: 42)
        try attach("p.lead, .unused { color: blue !important; width: 99px; height: 11px !important } #target { width: 8px }", to: document, sourceOrder: 7)
        let values = try snapshot(document).values
        #expect(values.count == 3)
        let color = try #require(values.first { $0.property == "color" })
        #expect(color.value == "blue")
        #expect(color.important)
        #expect(color.origin == 0)
        #expect(color.sourceOrder == 7)
        #expect(color.selector == "p.lead, .unused")
        let width = try #require(values.first { $0.property == "width" })
        #expect(width.value == "8px")
        #expect(width.selector == "#target")
        #expect(width.sourceOrder == 7)
        let height = try #require(values.first { $0.property == "height" })
        #expect(height.value == "7px")
        #expect(height.origin == 1)
    }

    @Test func selectorCombinatorsAttributesAndPseudoClassesUseLexborMatching() throws {
        let document = try createDocument("<section><p id='first'>First</p><p id='target' class='lead' data-kind='intro'><em>child</em></p><p id='other'>Other</p></section>")
        defer { ylx_document_destroy(document) }
        try attach("section > p.lead[data-kind='intro']:nth-child(2):not(.skip) { width: 12px } #first + p { height: 13px } section p.lead em { color: red }", to: document, sourceOrder: 4)
        let result = try snapshot(document)
        let target = try #require(result.attributeIDs["target"])
        #expect(result.values.filter { $0.nodeID == target }.map(\.property).sorted() == ["height", "width"])
        #expect(result.values.filter { $0.nodeID == result.attributeIDs["other"] }.isEmpty)
        #expect(result.values.filter { $0.property == "color" }.count == 1)
    }

    @Test func isGeneralSiblingAndEscapedIdentifiersSelectTheCorrectWinners() throws {
        let document = try createDocument("<section><p id='before' class='lead'>Before</p><h2 id='first'>Heading</h2><div>Gap</div><p id='chapter:one' class='lead'>Target</p><p id='other'>Other</p></section>")
        defer { ylx_document_destroy(document) }
        try attach(#"#first ~ p:is(.lead, #unused) { width: 12px } p.lead { width: 99px } #chapter\:one { color: green }"#, to: document, sourceOrder: 12)
        let result = try snapshot(document)
        let target = try #require(result.attributeIDs["chapter:one"])
        let targetValues = result.values.filter { $0.nodeID == target }
        #expect(targetValues.count == 2)
        #expect(targetValues.first { $0.property == "width" }?.value == "12px")
        #expect(targetValues.first { $0.property == "color" }?.value == "green")
        #expect(targetValues.allSatisfy { $0.sourceOrder == 12 })
        #expect(result.values.first { $0.nodeID == result.attributeIDs["before"] && $0.property == "width" }?.value == "99px")
        #expect(result.values.filter { $0.nodeID == result.attributeIDs["other"] }.isEmpty)
    }

    @Test func invalidSelectorRecoveryStillAppliesSubsequentValidRules() throws {
        let document = try createDocument("<p id='target'>Target</p><em id='other'>Other</em>")
        defer { ylx_document_destroy(document) }
        try attach("p,,em { color: red; height: 44px } p#target { color: green; width: 8px }", to: document, sourceOrder: 13)
        let result = try snapshot(document)
        let target = try #require(result.attributeIDs["target"])
        #expect(result.values.count == 2)
        #expect(result.values.allSatisfy { $0.nodeID == target && $0.sourceOrder == 13 })
        #expect(result.values.first { $0.property == "color" }?.value == "green")
        #expect(result.values.first { $0.property == "width" }?.value == "8px")
        #expect(result.values.allSatisfy { $0.selector == "p#target" })
    }

    @Test func preservesMixedTextAndElementChildOrder() throws {
        let document = try createDocument("<p>A<em>B</em>C<strong>D</strong>E</p>")
        defer { ylx_document_destroy(document) }
        let result = try snapshot(document)
        let children = result.children.filter { $0.parentID == result.paragraphID }.sorted { $0.nodeID < $1.nodeID }
        #expect(children.map(\.value) == ["A", "EM", "C", "STRONG", "E"])
    }

    @Test func embeddedStylesAreConsumedOnlyThroughIngestedStylesheets() throws {
        let document = try createDocument("<style>p { color: blue }</style><p style='height: 2px'>Text</p>")
        defer { ylx_document_destroy(document) }
        #expect(try snapshot(document).values.map(\.property) == ["height"])
        try attach("p { color: blue }", to: document, sourceOrder: 9)
        #expect(try snapshot(document).values.count == 2)
    }

    @Test func customNamesAndValuesRemainDistinctAfterDocumentDestruction() throws {
        let baseline = ylx_debug_live_document_count()
        let document = try createDocument("<p id='target'>Text</p>")
        try attach("p { ruby-position: under; --accent: #123456; unsupported-reader-prop: token(2) }", to: document, sourceOrder: 25)
        let result = try snapshot(document)
        ylx_document_destroy(document)
        #expect(ylx_debug_live_document_count() == baseline)
        #expect(result.values.count == 3)
        #expect(result.values.first { $0.property == "ruby-position" }?.value == "under")
        #expect(result.values.first { $0.property == "--accent" }?.value == "#123456")
        #expect(result.values.first { $0.property == "unsupported-reader-prop" }?.value == "token(2)")
        #expect(result.values.allSatisfy { $0.sourceOrder == 25 && $0.selector == "p" })
    }

    @Test func invalidDeclarationsDoNotReplaceValidWinners() throws {
        let document = try createDocument("<p style='width: 5px; width: nope'>Text</p>")
        defer { ylx_document_destroy(document) }
        try attach("p { color: red; color: invalid-color; width: bogus }", to: document, sourceOrder: 0)
        let values = try snapshot(document).values
        #expect(values.count == 2)
        #expect(values.first { $0.property == "width" }?.value == "5px")
        #expect(values.first { $0.property == "color" }?.value == "red")
        #expect(ylx_document_unparsed_declaration_count(document) == 3)
    }

    @Test func parserRejectedDeclarationsRemainObservableWithoutMatchingElements() throws {
        let document = try createDocument("<p>First</p><p>Second</p><p>Third</p>")
        defer { ylx_document_destroy(document) }
        #expect(ylx_document_unparsed_declaration_count(nil) == 0)
        #expect(ylx_document_unparsed_declaration_count(document) == 0)
        try attach("p { width: var(--reader-width) } .unmatched { height: nope }", to: document, sourceOrder: 0)
        #expect(ylx_document_unparsed_declaration_count(document) == 2)
        #expect(try snapshot(document).values.isEmpty)
        #expect(try snapshot(document).values.isEmpty)
        #expect(ylx_document_unparsed_declaration_count(document) == 2)
        try attach("p { width: 8px }", to: document, sourceOrder: 1)
        #expect(try snapshot(document).values.count == 3)
        #expect(ylx_document_unparsed_declaration_count(document) == 2)
    }

    @Test func unsupportedAtRulesAreObservableInsteadOfAppearingFullyResolved() throws {
        let document = try createDocument("<p>Text</p>")
        defer { ylx_document_destroy(document) }
        #expect(ylx_document_unsupported_rule_count(nil) == 0)
        #expect(ylx_document_unsupported_rule_count(document) == 0)
        try attach("@media all { p { color: red } } @supports (display: grid) { p { width: 10px } } p { height: 2px }", to: document, sourceOrder: 0)
        #expect(ylx_document_unsupported_rule_count(document) == 2)
        #expect(ylx_document_unparsed_declaration_count(document) == 0)
        #expect(try snapshot(document).values.map(\.property) == ["height"])
        try attach("p { width: 3px }", to: document, sourceOrder: 1)
        #expect(ylx_document_unsupported_rule_count(document) == 2)
        #expect(try snapshot(document).values.count == 2)
    }

    @Test func callbackRejectionIsReportedAndStyledOwnersAreReleased() throws {
        for _ in 0..<12 {
            let document = try createDocument("<p style='width: 1px'>Text</p>")
            try attach("p { color: red }", to: document, sourceOrder: 0)
            #expect(ylx_document_walk(document, { _, _ in 0 }, nil, nil, nil) == YLX_STATUS_PARSE_ERROR)
            #expect(ylx_document_walk_winning_declarations(document, { _, _, _ in 0 }, nil) == YLX_STATUS_PARSE_ERROR)
            #expect(try snapshot(document).values.count == 2)
            ylx_document_destroy(document)
        }
        #expect(ylx_debug_live_document_count() == 0)
    }

}

private struct DeclarationValue: Equatable {
    let nodeID: UInt64
    let property: String
    let value: String
    let selector: String
    let sourceOrder: UInt32
    let specificity: UInt32
    let origin: UInt8
    let important: Bool
}

private struct ChildValue: Equatable {
    let nodeID: UInt64
    let parentID: UInt64
    let value: String
}

private final class SnapshotContext {
    var elements: [String] = []
    var texts: [String] = []
    var declarations: [String] = []
    var paragraphID: UInt64 = 0
    var declarationNodeIDs: [UInt64] = []
    var values: [DeclarationValue] = []
    var children: [ChildValue] = []
    var attributeIDs: [String: UInt64] = [:]
}

private func snapshotString(_ bytes: YLXBytes) -> String {
    guard let base = bytes.bytes else { return "" }
    return String(decoding: UnsafeBufferPointer(start: base, count: bytes.length), as: UTF8.self)
}
private func snapshotElement(_ snapshot: UnsafePointer<YLXElementSnapshot>?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let snapshot, let context else { return 0 }
    let box = Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue()
    let value = snapshot.pointee
    box.elements.append(snapshotString(value.tag_name))
    box.children.append(ChildValue(nodeID: value.node_id, parentID: value.parent_node_id, value: snapshotString(value.tag_name)))
    if snapshotString(value.tag_name) == "P" { box.paragraphID = value.node_id }
    return 1
}
private func snapshotAttribute(_ nodeID: UInt64, _ name: YLXBytes, _ value: YLXBytes, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    if snapshotString(name).lowercased() == "id" {
        Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue().attributeIDs[snapshotString(value)] = nodeID
    }
    return 1
}
private func snapshotText(_ nodeID: UInt64, _ parentID: UInt64, _ text: YLXBytes, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let box = Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue()
    box.texts.append(snapshotString(text))
    box.children.append(ChildValue(nodeID: nodeID, parentID: parentID, value: snapshotString(text)))
    return 1
}
private func snapshotDeclaration(_ nodeID: UInt64, _ declaration: UnsafePointer<YLXWinningDeclaration>?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let declaration, let context else { return 0 }
    let box = Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue()
    box.declarations.append(snapshotString(declaration.pointee.property))
    box.declarationNodeIDs.append(nodeID)
    let value = declaration.pointee
    box.values.append(DeclarationValue(nodeID: nodeID, property: snapshotString(value.property),
        value: snapshotString(value.value), selector: snapshotString(value.selector),
        sourceOrder: value.source_order, specificity: value.specificity,
        origin: value.origin, important: value.important != 0))
    return 1
}

private func withDocumentBytes<T>(
    _ html: String,
    _ body: (UnsafeBufferPointer<UInt8>) -> T
) -> T {
    Array(html.utf8).withUnsafeBufferPointer(body)
}

private func createDocument(_ html: String) throws -> OpaquePointer {
    var status = YLX_STATUS_OK
    let document = withDocumentBytes(html) { ylx_document_create($0.baseAddress, $0.count, &status) }
    #expect(status == YLX_STATUS_OK)
    return try #require(document)
}

private func attach(_ css: String, to document: OpaquePointer, sourceOrder: UInt32) throws {
    let status = withDocumentBytes(css) { ylx_document_attach_stylesheet(document, $0.baseAddress, $0.count, sourceOrder) }
    try #require(status == YLX_STATUS_OK)
}

private func snapshot(_ document: OpaquePointer) throws -> SnapshotContext {
    let context = SnapshotContext()
    let pointer = Unmanaged.passUnretained(context).toOpaque()
    try #require(ylx_document_walk(document, snapshotElement, snapshotAttribute, snapshotText, pointer) == YLX_STATUS_OK)
    try #require(ylx_document_walk_winning_declarations(document, snapshotDeclaration, pointer) == YLX_STATUS_OK)
    return context
}
