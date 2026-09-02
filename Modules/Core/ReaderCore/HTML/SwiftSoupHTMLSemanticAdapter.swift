import SwiftSoup

/// Current DOM adapter for frontend-neutral HTML semantics. A future Lexbor
/// frontend supplies its own adapter and reuses `HTMLPresentationalHintExtractor`.
enum SwiftSoupHTMLSemanticAdapter {
    static func adapt(_ element: Element) -> HTMLSemanticElement {
        var attributes: [String: String] = [:]
        for name in ["width", "height"] where element.hasAttr(name) {
            if let value = try? element.attr(name) {
                attributes[name] = value
            }
        }
        return HTMLSemanticElement(
            tagName: element.tagName(),
            attributes: attributes
        )
    }
}
