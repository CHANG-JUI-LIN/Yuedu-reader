import Foundation
import os
import SwiftSoup

/// The rule-engine trees one JSContext's scripts read, each copied once, whole.
///
/// Legado hands a script the element a rule selected as it is, inside its page: 轻之文库
/// (YCK1331) names a chapter by walking `result.parentNode()` up to its volume's `<h2>`, and
/// 掌阅书城 (YCK1329) drops nested matches with `lr.get(v).parents().contains(c)`. The engine's
/// tree belongs to the thread that parsed it (`RuleHTMLElement`), so a script reads a copy; a
/// copy of the element alone had no parent, no siblings and no page (Rhino + jsoup answers:
/// `scripts/legado-compat/oracle/cases/attached-element.json`). One copy per tree, not per
/// element, so a chapter list of 2,000 items copies its page once. Scripts change the copy as
/// Legado's change the page, and later items see the change, as there; the engine's own tree
/// is not changed, so a rule step after the script reads the page as parsed.
///
/// The copies go when the parse that made them ends (`ModernParserBridge.endParse`), as the
/// engine's own documents do (`JsoupDocumentCache`): copies kept per JSContext would keep a
/// page alive in each of the 32 sessions `BookSourceSession` holds. Until then each copy holds
/// its original too, which the parse holds anyway: the identity map's keys stay those
/// elements', and a strong reference costs nothing where a weak one allocates a side table per
/// element (a 2000-chapter page has 10,000).
final class LegadoScriptTrees: @unchecked Sendable {
    private struct Tree {
        let original: Node
        let document: Document
        /// Each element of the original's tree, by identity, and its copy.
        let copies: [ObjectIdentifier: Copy]
    }

    private struct Copy {
        let original: Element
        let element: Element
    }

    /// By the original tree's root. Read and written on the context's queue; emptied from
    /// the parsing thread once the parse ends (`removeAll`).
    private let trees = OSAllocatedUnfairLock<[ObjectIdentifier: Tree]>(uncheckedState: [:])

    /// `element`'s copy, and the document holding it. The JS queue only, while the thread that
    /// owns `element`'s tree waits for the script (as every script call does).
    func copy(of element: Element) -> (document: Document, element: Element) {
        var root: Node = element
        while let parent = root.parent() { root = parent }
        let rootKey = ObjectIdentifier(root)
        let key = ObjectIdentifier(element)
        let known = trees.withLockUnchecked { $0[rootKey] }
        if let known, known.original === root, let copy = known.copies[key], copy.original === element {
            return (known.document, copy.element)
        }
        // A tree not copied yet, or one that holds an element the copy lacks: copy it as it is.
        let made = Self.copy(root: root, baseUri: element.getBaseUri())
        trees.withLockUnchecked { $0[rootKey] = made }
        guard let copy = made.copies[key] else {
            // `element` is in `root`'s tree by construction: `root` is its topmost ancestor.
            AppLogger.parse("Script tree copy lacks the element it was made for", level: .anomaly)
            let detached = RuleHTMLElement.detachedElement(element)
            return (detached.ownerDocument() ?? Document(detached.getBaseUri()), detached)
        }
        return (made.document, copy.element)
    }

    /// Forgets the copies; each tree goes once no script holds an element of it.
    func removeAll() {
        trees.withLockUnchecked { $0.removeAll() }
    }

    /// How many pages are held now.
    var count: Int {
        trees.withLockUnchecked { $0.count }
    }

    private static func copy(root: Node, baseUri: String) -> Tree {
        let copiedRoot = root.copy() as? Node ?? Document(baseUri)
        let document: Document
        if let copiedDocument = copiedRoot as? Document {
            document = copiedDocument
        } else {
            // A tree under no document (an element a script made, handed back to the engine):
            // placed under one, as `RuleHTMLElement.detachedElement` does.
            document = Document(baseUri)
            do {
                try document.appendChild(copiedRoot)
            } catch {
                AppLogger.parse("Script tree copy could not be placed in a document", context: ["error": "\(error)"])
            }
        }
        // `copy()` keeps every node's children in order, so the two trees walk in step.
        var copies: [ObjectIdentifier: Copy] = [:]
        var pending: [(Node, Node)] = [(root, copiedRoot)]
        while let (original, copied) = pending.popLast() {
            if let originalElement = original as? Element, let copiedElement = copied as? Element {
                copies[ObjectIdentifier(originalElement)] = Copy(original: originalElement, element: copiedElement)
            }
            let originalChildren = original.getChildNodes()
            let copiedChildren = copied.getChildNodes()
            for index in 0..<min(originalChildren.count, copiedChildren.count) {
                pending.append((originalChildren[index], copiedChildren[index]))
            }
        }
        return Tree(original: root, document: document, copies: copies)
    }
}
