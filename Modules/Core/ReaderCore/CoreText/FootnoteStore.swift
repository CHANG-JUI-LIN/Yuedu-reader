import Foundation

/// Per-chapter index of duokan-style popup footnotes.
///
/// 多看 EPUBs mark a footnote reference as `<sup><a class="duokan-footnote" href="#note_1">
/// <img/></a></sup>` and place the note body in `<ol class="duokan-footnote-content">
/// <li class="duokan-footnote-item" id="note_1">…</li></ol>` at the end of the chapter. The
/// reader follows the convention of showing the note in a popup instead of yanking the reader to
/// the chapter tail. This store holds `noteID → text`, populated while a chapter's AST is built
/// and queried when a footnote link is tapped.
enum FootnoteStore {
    private static let lock = NSLock()
    private static var bySpine: [Int: [String: String]] = [:]

    /// Walks a freshly built chapter body and records every footnote item it finds.
    static func index(body: HTMLAttributedStringBuilder.ElementNode, spineIndex: Int) {
        var map: [String: String] = [:]
        collect(node: body, into: &map)
        lock.lock()
        bySpine[spineIndex] = map.isEmpty ? nil : map
        lock.unlock()
    }

    /// Footnote body text for a tapped href (`#note_1`) within a given spine, or nil if the href
    /// is not a known footnote (callers then fall back to ordinary internal-link navigation).
    static func text(spineIndex: Int, href: String) -> String? {
        let id = noteID(fromHref: href)
        guard !id.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return bySpine[spineIndex]?[id]
    }

    /// The fragment id of a same-document link (`Text/00.xhtml#note_1` → `note_1`).
    static func noteID(fromHref href: String) -> String {
        guard let hash = href.lastIndex(of: "#") else { return "" }
        return String(href[href.index(after: hash)...])
    }

    private static func collect(node: HTMLAttributedStringBuilder.ElementNode, into map: inout [String: String]) {
        if node.tag == "li",
           !node.id.isEmpty,
           node.classes.contains(where: { $0.contains("footnote") }) {
            let body = normalizedText(of: node)
            if !body.isEmpty {
                map[node.id] = body
            }
        }
        for child in node.children {
            if case .element(let element) = child {
                collect(node: element, into: &map)
            }
        }
    }

    private static func normalizedText(of node: HTMLAttributedStringBuilder.ElementNode) -> String {
        let raw = plainText(of: node)
        let collapsed = raw.replacingOccurrences(
            of: "[ \\t\\r\\n\\x{000C}]+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainText(of node: HTMLAttributedStringBuilder.ElementNode) -> String {
        var result = ""
        for child in node.children {
            switch child {
            case .text(let text):
                result += text.text
            case .lineBreak:
                result += "\n"
            case .pageBreak:
                break
            case .element(let element):
                result += plainText(of: element)
            }
        }
        return result
    }
}
