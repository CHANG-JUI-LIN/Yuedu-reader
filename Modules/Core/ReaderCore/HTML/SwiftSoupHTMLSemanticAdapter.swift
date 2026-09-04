import SwiftSoup

/// Current DOM adapter for frontend-neutral HTML semantics. A future Lexbor
/// frontend supplies its own adapter and reuses `HTMLPresentationalHintExtractor`.
enum SwiftSoupHTMLSemanticAdapter {
    static func adapt(_ element: Element) -> HTMLSemanticElement {
        snapshot(element).htmlSemanticElement
    }

    /// Copies every authored attribute and the small amount of semantic DOM
    /// identity required after the frontend returns. The returned value owns no
    /// SwiftSoup node or pointer.
    static func snapshot(_ element: Element) -> HTMLDOMElementSnapshot {
        let attributes = authoredAttributes(of: element)
        return HTMLDOMElementSnapshot(
            semanticPath: semanticPath(of: element),
            tagName: element.tagName(),
            namespace: namespaceURI(of: element),
            attributes: attributes,
            svgRenderability: svgRenderability(of: element)
        )
    }

    private static func authoredAttributes(of element: Element) -> [String: String] {
        guard let source = element.getAttributes() else { return [:] }
        var attributes: [String: String] = [:]
        for attribute in source {
            attributes[attribute.getKey()] = attribute.getValue()
        }
        return attributes
    }

    private static func namespaceURI(of element: Element) -> String? {
        var current: Element? = element
        while let candidate = current {
            if candidate.hasAttr("xmlns"),
               let namespace = try? candidate.attr("xmlns"),
               !namespace.isEmpty {
                return namespace
            }
            current = candidate.parent()
        }

        // XHTML parsed as HTML commonly omits an explicit namespace. Keep that
        // absence observable instead of manufacturing frontend-specific state.
        return nil
    }

    private static func semanticPath(of element: Element) -> String {
        var segments: [String] = []
        var current: Element? = element
        while let candidate = current {
            let ordinal = (try? candidate.elementSiblingIndex()) ?? 0
            let id = ((try? candidate.attr("id")) ?? "")
            let suffix = id.isEmpty ? "" : "#\(id)"
            segments.append("\(candidate.tagName().lowercased())[\(ordinal)]\(suffix)")
            current = candidate.parent()
        }
        return segments.reversed().joined(separator: "/")
    }

    private static func svgRenderability(of element: Element) -> SVGRenderability? {
        guard element.tagName().lowercased() == "svg" else { return nil }
        guard let images = try? element.select("image").array(), images.count == 1,
              let image = images.first else {
            return .unsupportedVector
        }
        let drawable = (try? element.select(
            "path, rect, circle, ellipse, line, polyline, polygon, text, textPath, use, g, symbol, marker, pattern, mask, foreignObject"
        ).array()) ?? []
        guard drawable.isEmpty else { return .unsupportedVector }
        for attribute in ["xlink:href", "href"] {
            if let href = try? image.attr(attribute), !href.isEmpty {
                return .rasterWrapper(source: href)
            }
        }
        return .unsupportedVector
    }
}
