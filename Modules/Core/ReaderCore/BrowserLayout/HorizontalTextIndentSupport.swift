import Foundation

/// Admission result for the Phase 4E1 horizontal `text-indent` subset.
enum HorizontalTextIndentUsage: Equatable {
    case none
    case supportedNonZero
    case unsupported
}

/// Shared resolved-style predicate used by both the scanner and production
/// document admission. It intentionally judges only block containers that
/// actually own inline formatting content. An inherited unsupported value on
/// a grouping block with only block children has no geometry effect; the child
/// formatting owner is judged using its own final cascaded value instead.
enum HorizontalTextIndentSupport {
    static func usage(in root: ComputedStyleNode) -> HorizontalTextIndentUsage {
        var foundSupportedNonZero = false
        var foundUnsupported = false
        walk(
            root,
            foundSupportedNonZero: &foundSupportedNonZero,
            foundUnsupported: &foundUnsupported
        )
        if foundUnsupported { return .unsupported }
        return foundSupportedNonZero ? .supportedNonZero : .none
    }

    private static func walk(
        _ node: ComputedStyleNode,
        foundSupportedNonZero: inout Bool,
        foundUnsupported: inout Bool
    ) {
        guard !foundUnsupported else { return }

        if node.style.display == .block,
           ownsInlineFormattingContent(node.children, whiteSpace: node.style.whiteSpace) {
            switch node.style.textIndent {
            case .unsupported:
                foundUnsupported = true
                return
            case .length:
                foundSupportedNonZero = foundSupportedNonZero
                    || node.style.textIndent.hasPositiveSpecifiedValue
            }
        }

        for child in node.children {
            guard case .element(let childNode) = child else { continue }
            walk(
                childNode,
                foundSupportedNonZero: &foundSupportedNonZero,
                foundUnsupported: &foundUnsupported
            )
        }
    }

    /// Mirrors the BoxTreeBuilder boundary: direct text and descendants of
    /// ordinary inline elements belong to this block's inline formatting
    /// context; nested blocks/floats establish a different owner.
    private static func ownsInlineFormattingContent(
        _ children: [StyleTreeChild],
        whiteSpace: WhiteSpaceMode
    ) -> Bool {
        children.contains { child in
            switch child {
            case .text(let text):
                switch whiteSpace {
                case .pre, .preWrap:
                    return !text.isEmpty
                case .normal, .nowrap, .preLine:
                    let collapsed = InlineLayout.collapseText(text, mode: whiteSpace)
                    return collapsed.contains { character in
                        character != " " && character != "\t"
                    }
                }
            case .element(let element):
                guard element.style.display != .none,
                      element.style.display != .block,
                      !element.style.isFloated else {
                    return false
                }
                if ["br", "img", "svg", "ruby"].contains(element.tag) {
                    return true
                }
                return ownsInlineFormattingContent(
                    element.children,
                    whiteSpace: element.style.whiteSpace
                )
            }
        }
    }
}
