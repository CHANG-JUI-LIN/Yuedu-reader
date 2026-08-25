import Foundation

enum RubyAlignment: Equatable {
    case center
    case unsupported(String)

    static func parse(_ raw: String) -> RubyAlignment {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "center" ? .center : .unsupported(value)
    }
}

enum RubyPosition: Equatable {
    case over
    case unsupported(String)

    static func parse(_ raw: String) -> RubyPosition {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "over" ? .over : .unsupported(value)
    }
}

enum RubyMerge: Equatable {
    case separate
    case unsupported(String)

    static func parse(_ raw: String) -> RubyMerge {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "separate" ? .separate : .unsupported(value)
    }
}

struct HorizontalRubyStructure {
    let ruby: ComputedStyleNode
    let baseChildren: [StyleTreeChild]
    let annotation: ComputedStyleNode
}

struct HorizontalRubyValidation {
    let structures: [HorizontalRubyStructure]
    let isSupported: Bool
}

/// The single source of truth for Phase 4D's deliberately small horizontal
/// Ruby subset. Both layout admission and the capability scanner consume this
/// predicate so parsing support cannot drift from geometry support.
enum HorizontalRubySupport {
    private static let structuralTags: Set<String> = [
        "ruby", "rt", "rp", "rb", "rtc", "br", "img", "svg",
    ]

    static func validate(
        _ root: ComputedStyleNode,
        writingMode: ReaderWritingMode = .horizontal
    ) -> HorizontalRubyValidation {
        let hasRubyMarkup = containsTag(
            root,
            names: ["ruby", "rt", "rp", "rb", "rtc"],
            excludingRoot: false
        )
        guard hasRubyMarkup else {
            return HorizontalRubyValidation(structures: [], isSupported: true)
        }
        guard writingMode == .horizontal else {
            return HorizontalRubyValidation(structures: [], isSupported: false)
        }

        var structures: [HorizontalRubyStructure] = []
        var valid = true
        walk(root, insideRuby: false, structures: &structures, valid: &valid)
        return HorizontalRubyValidation(structures: structures, isSupported: valid)
    }

    static func rubyNodes(in root: ComputedStyleNode) -> [ComputedStyleNode] {
        validate(root).structures.map(\.ruby)
    }

    static func structure(for node: ComputedStyleNode) -> HorizontalRubyStructure? {
        guard node.tag == "ruby",
              node.style.display == .inline,
              node.style.rubyAlign == .center,
              node.style.rubyPosition == .over,
              node.style.rubyMerge == .separate else {
            return nil
        }

        let directRT = node.children.compactMap(\.elementNode).filter { $0.tag == "rt" }
        guard directRT.count == 1,
              let rt = directRT.first,
              rt.style.display == .inline,
              !rt.style.isFloated else {
            return nil
        }
        guard !containsTag(node, names: ["ruby", "rb", "rtc"], excludingRoot: true) else {
            return nil
        }
        guard let rtIndex = node.children.firstIndex(where: { $0.elementNode === rt }) else {
            return nil
        }

        let before = Array(node.children[..<rtIndex]).filter { $0.elementNode?.tag != "rp" }
        let after = node.children[node.children.index(after: rtIndex)...]
        guard after.allSatisfy({ child in
            if let element = child.elementNode { return element.tag == "rp" }
            if case .text(let text) = child {
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }),
        containsVisibleBase(before),
        supportedInlineBase(before),
        containsVisibleBase(rt.children),
        supportedInlineBase(rt.children) else {
            return nil
        }

        return HorizontalRubyStructure(ruby: node, baseChildren: before, annotation: rt)
    }

    private static func walk(
        _ node: ComputedStyleNode,
        insideRuby: Bool,
        structures: inout [HorizontalRubyStructure],
        valid: inout Bool
    ) {
        guard valid else { return }
        if node.tag == "ruby" {
            guard !insideRuby, let accepted = structure(for: node) else {
                valid = false
                return
            }
            structures.append(accepted)
            return
        }
        if ["rt", "rp", "rb", "rtc"].contains(node.tag) {
            valid = false
            return
        }
        for child in node.children {
            guard case .element(let element) = child else { continue }
            walk(element, insideRuby: false, structures: &structures, valid: &valid)
        }
    }

    private static func containsVisibleBase(_ children: [StyleTreeChild]) -> Bool {
        children.contains { child in
            switch child {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .element(let element):
                return containsVisibleBase(element.children)
            }
        }
    }

    private static func supportedInlineBase(_ children: [StyleTreeChild]) -> Bool {
        children.allSatisfy { child in
            switch child {
            case .text:
                return true
            case .element(let element):
                guard element.style.display == .inline,
                      !element.style.isFloated,
                      !structuralTags.contains(element.tag) else {
                    return false
                }
                return supportedInlineBase(element.children)
            }
        }
    }

    private static func containsTag(
        _ node: ComputedStyleNode,
        names: Set<String>,
        excludingRoot: Bool
    ) -> Bool {
        if !excludingRoot, names.contains(node.tag) { return true }
        for child in node.children {
            guard case .element(let element) = child else { continue }
            if names.contains(element.tag)
                || containsTag(element, names: names, excludingRoot: true) {
                return true
            }
        }
        return false
    }
}

private extension StyleTreeChild {
    var elementNode: ComputedStyleNode? {
        guard case .element(let node) = self else { return nil }
        return node
    }
}

struct RubyInlinePiece {
    let text: String
    let style: ComputedStyle
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
}

struct RubyAnnotationPiece {
    let text: String
    let style: ComputedStyle
    let nodeID: Int
    let linkTarget: String?
}

struct RubyAnnotation {
    let pieces: [RubyAnnotationPiece]

    var text: String {
        pieces.map(\.text).joined()
    }
}

/// Semantic Ruby content before shaping. The base remains in the chapter's
/// source coordinate space; the annotation deliberately has no independent
/// source range and maps back to the complete base range later.
struct RubyInlineUnit {
    let base: [RubyInlinePiece]
    let annotation: RubyAnnotation
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let alignment: RubyAlignment
    let position: RubyPosition
}
