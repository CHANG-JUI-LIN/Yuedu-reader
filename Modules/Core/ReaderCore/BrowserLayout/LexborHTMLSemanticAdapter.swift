import CLexbor
import Foundation

final class LexborHTMLSemanticAdapter {
    final class Context {
        var elements: [UInt64: HTMLDOMElementSnapshot] = [:]
        var parents: [UInt64: UInt64] = [:]
        var attributes: [UInt64: [String: String]] = [:]
        var textOrder: [(nodeID: UInt64, text: String)] = []
        var declarations: [FrontendWinningDeclaration] = []

        func updateAttributes() {
            for (nodeID, snapshot) in elements {
                elements[nodeID] = HTMLDOMElementSnapshot(
                    semanticPath: snapshot.semanticPath, tagName: snapshot.tagName,
                    namespace: snapshot.namespace, attributes: attributes[nodeID] ?? [:],
                    svgRenderability: snapshot.svgRenderability
                )
            }
        }
    }

    static func snapshot(owner: LexborDocumentOwner, input: CSSFrontendInput) throws -> LexborFrontendSnapshot {
        let context = Context()
        let status = owner.withDocument { document in
            for stylesheet in input.activeAuthorStylesheets {
                let attachStatus = stylesheet.text.utf8CString.withUnsafeBytes { bytes in
                    ylx_document_attach_stylesheet(
                        document, bytes.bindMemory(to: UInt8.self).baseAddress,
                        max(0, bytes.count - 1), UInt32(stylesheet.sourceOrder)
                    )
                }
                guard attachStatus == YLX_STATUS_OK else { return attachStatus }
            }
            let walkStatus = ylx_document_walk(
                document, lexborElementCallback, lexborAttributeCallback,
                lexborTextCallback, Unmanaged.passUnretained(context).toOpaque()
            )
            guard walkStatus == YLX_STATUS_OK else { return walkStatus }
            return ylx_document_walk_winning_declarations(
                document, lexborDeclarationCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )
        }
        guard status == YLX_STATUS_OK else { throw LexborError.bridge(status) }
        context.updateAttributes()
        return LexborFrontendSnapshot(
            elements: context.elements, parentIDs: context.parents,
            textOrder: context.textOrder,
            winningDeclarations: context.declarations,
            diagnostics: input.diagnostics
        )
    }

    enum LexborError: Swift.Error, Equatable {
        case bridge(YLXStatus)
    }
}

private func lexborString(_ bytes: YLXBytes) -> String {
    guard let pointer = bytes.bytes else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: bytes.length), as: UTF8.self)
}

private func lexborElementCallback(_ snapshot: UnsafePointer<YLXElementSnapshot>?, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let snapshot, let raw else { return 0 }
    let context = Unmanaged<LexborHTMLSemanticAdapter.Context>.fromOpaque(raw).takeUnretainedValue()
    let value = snapshot.pointee
    let tag = lexborString(value.tag_name).lowercased()
    let namespace = lexborString(value.namespace_name)
    let path = "\(tag)[\(value.sibling_ordinal)]"
    context.parents[value.node_id] = value.parent_node_id
    context.elements[value.node_id] = HTMLDOMElementSnapshot(
        semanticPath: path, tagName: tag, namespace: namespace.isEmpty ? nil : namespace,
        attributes: [:], svgRenderability: nil
    )
    return 1
}

private func lexborAttributeCallback(_ nodeID: UInt64, _ name: YLXBytes, _ value: YLXBytes, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let context = Unmanaged<LexborHTMLSemanticAdapter.Context>.fromOpaque(raw).takeUnretainedValue()
    context.attributes[nodeID, default: [:]][lexborString(name).lowercased()] = lexborString(value)
    return 1
}

private func lexborTextCallback(_ nodeID: UInt64, _ text: YLXBytes, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let context = Unmanaged<LexborHTMLSemanticAdapter.Context>.fromOpaque(raw).takeUnretainedValue()
    context.textOrder.append((nodeID, lexborString(text)))
    return 1
}

private func lexborDeclarationCallback(_ nodeID: UInt64, _ declaration: UnsafePointer<YLXWinningDeclaration>?, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let declaration, let raw else { return 0 }
    let context = Unmanaged<LexborHTMLSemanticAdapter.Context>.fromOpaque(raw).takeUnretainedValue()
    let value = declaration.pointee
    context.declarations.append(FrontendWinningDeclaration(
        nodeID: nodeID, property: lexborString(value.property), value: lexborString(value.value),
        specificity: value.specificity, sourceOrder: value.source_order,
        origin: value.origin, important: value.important != 0
    ))
    return 1
}
