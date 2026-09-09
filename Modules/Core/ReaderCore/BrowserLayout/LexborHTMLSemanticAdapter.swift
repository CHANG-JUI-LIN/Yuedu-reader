import CLexbor
import Foundation

/// Copies the complete traversal before the document owner leaves the frontend.
final class LexborHTMLSemanticAdapter {
    final class Context {
        var elements: [UInt64: HTMLDOMElementSnapshot] = [:]
        var parents: [UInt64: UInt64] = [:]
        var attributes: [UInt64: [String: String]] = [:]
        var ordinals: [UInt64: UInt32] = [:]
        var textOrder: [LexborTextSnapshot] = []
        var declarations: [FrontendWinningDeclaration] = []
        var stylesheets: [UInt32: StylesheetIdentity] = [:]

        func finalizeElements() {
            var paths: [UInt64: String] = [:]
            let children = Dictionary(grouping: elements.keys, by: { parents[$0] ?? 0 })
            func descendants(_ id: UInt64) -> [UInt64] {
                (children[id] ?? []).flatMap { [$0] + descendants($0) }
            }
            for id in elements.keys.sorted() {
                guard let element = elements[id] else { continue }
                let attrs = attributes[id] ?? [:]
                let suffix = (attrs["id"] ?? "").isEmpty ? "" : "#\(attrs["id"]!)"
                let segment = "{\(element.namespace ?? "")}\(element.tagName)[\(ordinals[id] ?? 0)]\(suffix)"
                let prefix = paths[parents[id] ?? 0].map { $0 + "/" } ?? ""
                paths[id] = prefix + segment
                var svg: SVGRenderability?
                if element.tagName == "svg" {
                    let nested = descendants(id)
                    let images = nested.filter { elements[$0]?.tagName == "image" }
                    let drawable: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "textpath", "use", "g", "symbol", "marker", "pattern", "mask", "foreignobject"]
                    if images.count == 1, !nested.contains(where: { drawable.contains(elements[$0]?.tagName ?? "") }),
                       let imageID = images.first,
                       let source = [attributes[imageID]?["xlink:href"], attributes[imageID]?["href"]]
                        .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                        svg = .rasterWrapper(source: source)
                    } else {
                        svg = .unsupportedVector
                    }
                }
                elements[id] = HTMLDOMElementSnapshot(
                    semanticPath: paths[id]!, tagName: element.tagName,
                    namespace: element.namespace, attributes: attrs, svgRenderability: svg
                )
            }
        }
    }

    static func snapshot(owner: LexborDocumentOwner, input: CSSFrontendInput) throws -> LexborFrontendSnapshot {
        let context = Context()
        var diagnostics = input.diagnostics
        let status = owner.withDocument { document in
            for stylesheet in input.activeAuthorStylesheets {
                guard let order = UInt32(exactly: stylesheet.sourceOrder), context.stylesheets[order] == nil else {
                    return YLX_STATUS_INVALID_ARGUMENT
                }
                context.stylesheets[order] = stylesheet.identity
                let attachStatus = stylesheet.text.utf8CString.withUnsafeBytes { bytes in
                    ylx_document_attach_stylesheet(
                        document, bytes.bindMemory(to: UInt8.self).baseAddress,
                        max(0, bytes.count - 1), order
                    )
                }
                guard attachStatus == YLX_STATUS_OK else { return attachStatus }
            }
            let walkStatus = ylx_document_walk(
                document, lexborElementCallback, lexborAttributeCallback,
                lexborTextCallback, Unmanaged.passUnretained(context).toOpaque()
            )
            guard walkStatus == YLX_STATUS_OK else { return walkStatus }
            let unparsed = ylx_document_unparsed_declaration_count(document)
            if unparsed > 0 {
                diagnostics.append(CSSFrontendDiagnostic(stage: .css, stylesheet: nil, semanticPath: nil,
                    property: nil, message: "Lexbor rejected or cannot parse \(unparsed) declaration(s); classification required before cutover"))
            }
            let unsupportedRules = ylx_document_unsupported_rule_count(document)
            if unsupportedRules > 0 {
                diagnostics.append(CSSFrontendDiagnostic(stage: .css, stylesheet: nil, semanticPath: nil,
                    property: nil, message: "Lexbor bridge does not evaluate \(unsupportedRules) rule subtree(s); cutover blocked"))
            }
            return ylx_document_walk_winning_declarations(
                document, lexborDeclarationCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )
        }
        guard status == YLX_STATUS_OK else {
            switch status {
            case YLX_STATUS_INVALID_ARGUMENT: throw LexborDocumentOwner.Error.invalidInput
            case YLX_STATUS_OUT_OF_MEMORY: throw LexborDocumentOwner.Error.outOfMemory
            default: throw LexborDocumentOwner.Error.parseFailed
            }
        }
        context.finalizeElements()
        return LexborFrontendSnapshot(
            elements: context.elements, parentIDs: context.parents,
            textOrder: context.textOrder, winningDeclarations: context.declarations,
            diagnostics: diagnostics
        )
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
    context.parents[value.node_id] = value.parent_node_id
    context.ordinals[value.node_id] = value.sibling_ordinal
    context.elements[value.node_id] = HTMLDOMElementSnapshot(
        semanticPath: "", tagName: tag, namespace: namespace.isEmpty ? nil : namespace,
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

private func lexborTextCallback(_ nodeID: UInt64, _ parentID: UInt64, _ text: YLXBytes, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let context = Unmanaged<LexborHTMLSemanticAdapter.Context>.fromOpaque(raw).takeUnretainedValue()
    context.textOrder.append(LexborTextSnapshot(nodeID: nodeID, parentID: parentID, text: lexborString(text)))
    return 1
}

private func lexborDeclarationCallback(_ nodeID: UInt64, _ declaration: UnsafePointer<YLXWinningDeclaration>?, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let declaration, let raw else { return 0 }
    let context = Unmanaged<LexborHTMLSemanticAdapter.Context>.fromOpaque(raw).takeUnretainedValue()
    let value = declaration.pointee
    let selector = lexborString(value.selector)
    context.declarations.append(FrontendWinningDeclaration(
        nodeID: nodeID, property: lexborString(value.property), value: lexborString(value.value),
        specificity: value.specificity, sourceOrder: value.source_order,
        origin: value.origin, important: value.important != 0,
        selector: selector.isEmpty ? nil : selector,
        stylesheet: value.origin == 1 ? nil : context.stylesheets[value.source_order]
    ))
    return 1
}
