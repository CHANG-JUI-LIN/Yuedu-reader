import Foundation
import SwiftSoup

/// A jsoup element a rule step selected, carried to the next step as the element itself.
///
/// Legado's `AnalyzeByJSoup(doc)` uses an `Element` it is handed as it is, and parses
/// anything else — a page string, or an `Elements` list's joined outer HTML. Every fork
/// agrees (legado-E/MD3 `AnalyzeByJSoup.parse`, upstream `AnalyzeByJSoup`). The rule
/// engine used to hand each list item to the next rule as its outer HTML, and every field
/// rule re-parsed that string as a page:
///
/// - The HTML parser drops a `<tr>`/`<td>` outside a table, so a search list of table rows
///   came back with no cells and every book was discarded (全本小說網 `www.qbxs.net`:
///   100 rows, 6 `td` each, 0 after the round trip — YCK1330 report, 2026-11-05).
/// - `children`, an index step or an attribute read ran against the synthetic
///   `<html><body>` wrapper instead of the element.
/// - Source JS received a string where Legado hands it the Element, so `result.attr(…)`,
///   `result.select(…)` and `list[i].text()` threw.
///
/// # Ownership
///
/// SwiftSoup mutates nodes while it reads them (see `JsoupDocumentCache`), so a tree
/// belongs to the thread that parsed it. A `RuleHTMLElement` is only read by the rule
/// engine call that produced it. A script reads the context's copy of the element's whole
/// tree (`LegadoScriptTrees`), and an element a script hands back is copied out
/// (`detachedCopy()`), so no tree is ever reachable from two owners.
final class RuleHTMLElement: CustomStringConvertible {
    let element: Element
    /// SwiftSoup's parent links are weak: holding the root keeps the element's ancestors —
    /// and with them `parent()` and the document's output settings — alive.
    private let root: Node

    init(_ element: Element) {
        self.element = element
        var top: Node = element
        while let parent = top.parent() { top = parent }
        self.root = top
    }

    /// The element's outer HTML — its string form in Legado (`Element.toString()`), and
    /// what every non-jsoup reader (XPath, JSONPath, regex) receives.
    var outerHTML: String {
        do {
            return try element.outerHtml()
        } catch {
            AppLogger.parse("RuleHTMLElement outerHtml failed", context: ["error": "\(error)"])
            return ""
        }
    }

    var description: String { outerHTML }

    /// A deep copy in a tree of its own, under a document of its own: nothing it holds is
    /// reachable from the original's owner. The copy keeps the element's own structure —
    /// it is not re-parsed — so a `<td>` stays a `<td>`.
    func detachedCopy() -> RuleHTMLElement {
        RuleHTMLElement(Self.detachedElement(element))
    }

    /// `element` copied under a fresh document.
    static func detachedElement(_ element: Element) -> Element {
        // Default output settings, like every document the rule engine parses; sharing the
        // source document's settings object would share mutable state across owners.
        let document = Document(element.getBaseUri())
        guard let clone = element.copy() as? Element else { return document }
        do {
            try document.appendChild(clone)
        } catch {
            AppLogger.parse("RuleHTMLElement detach failed", context: ["error": "\(error)"])
        }
        return clone
    }
}
