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
        elementNames = context.elements.pointee
        textValues = context.texts.pointee
        declarationProperties = context.declarations.pointee
        #expect(elementNames.contains("P"))
        #expect(textValues.contains("Hello "))
        #expect(textValues.contains("world"))
        #expect(declarationProperties.contains("color"))
        #expect(declarationProperties.contains("width"))
        #expect(context.declarationNodeIDs.pointee.allSatisfy { $0 == context.paragraphID.pointee })
        ylx_document_destroy(document)
    }
}

private final class SnapshotContext {
    var elements: UnsafeMutablePointer<[String]>
    var texts: UnsafeMutablePointer<[String]>
    var declarations: UnsafeMutablePointer<[String]>
    var paragraphID: UnsafeMutablePointer<UInt64>
    var declarationNodeIDs: UnsafeMutablePointer<[UInt64]>
    init() {
        self.elements = .allocate(capacity: 1); self.elements.initialize(to: [])
        self.texts = .allocate(capacity: 1); self.texts.initialize(to: [])
        self.declarations = .allocate(capacity: 1); self.declarations.initialize(to: [])
        self.paragraphID = .allocate(capacity: 1); self.paragraphID.initialize(to: 0)
        self.declarationNodeIDs = .allocate(capacity: 1); self.declarationNodeIDs.initialize(to: [])
    }
    deinit {
        elements.deinitialize(count: 1); elements.deallocate()
        texts.deinitialize(count: 1); texts.deallocate()
        declarations.deinitialize(count: 1); declarations.deallocate()
        paragraphID.deinitialize(count: 1); paragraphID.deallocate()
        declarationNodeIDs.deinitialize(count: 1); declarationNodeIDs.deallocate()
    }
}

private func snapshotString(_ bytes: YLXBytes) -> String {
    guard let base = bytes.bytes else { return "" }
    return String(decoding: UnsafeBufferPointer(start: base, count: bytes.length), as: UTF8.self)
}
private func snapshotElement(_ snapshot: UnsafePointer<YLXElementSnapshot>?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let snapshot, let context else { return 0 }
    let box = Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue()
    let value = snapshot.pointee
    box.elements.pointee.append(snapshotString(value.tag_name))
    if snapshotString(value.tag_name) == "P" { box.paragraphID.pointee = value.node_id }
    return 1
}
private func snapshotAttribute(_ nodeID: UInt64, _ name: YLXBytes, _ value: YLXBytes, _ context: UnsafeMutableRawPointer?) -> Int32 { 1 }
private func snapshotText(_ nodeID: UInt64, _ text: YLXBytes, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue().texts.pointee.append(snapshotString(text)); return 1
}
private func snapshotDeclaration(_ nodeID: UInt64, _ declaration: UnsafePointer<YLXWinningDeclaration>?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let declaration, let context else { return 0 }
    let box = Unmanaged<SnapshotContext>.fromOpaque(context).takeUnretainedValue()
    box.declarations.pointee.append(snapshotString(declaration.pointee.property))
    box.declarationNodeIDs.pointee.append(nodeID)
    return 1
}

private func withDocumentBytes<T>(
    _ html: String,
    _ body: (UnsafeBufferPointer<UInt8>) -> T
) -> T {
    Array(html.utf8).withUnsafeBufferPointer(body)
}
