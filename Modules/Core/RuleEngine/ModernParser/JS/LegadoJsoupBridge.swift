import Foundation
import JavaScriptCore
import SwiftSoup

// MARK: - JSExport Protocols

/// A single parsed node handed to JS. JavaScriptCore owns the lifetime: the JS wrapper holds
/// this object, and it holds the owning `Document` (SwiftSoup's `parentNode` is weak, so the
/// tree would otherwise be freed while JS still points into it).
///
/// The tree is the script's own: either parsed for this JSContext (`LegadoJsoupBridge.parse`)
/// or a copy of the page an element the rule engine selected is in (`init(detaching:trees:)`,
/// `LegadoScriptTrees`). Legado's
/// scripts edit jsoup trees before reading them — `doc.select(".ad").remove()` and then
/// `doc.html()` — so the mutators change the tree for real; a mutated document leaves this
/// context's parse cache, so the next parse of the same markup is a clean tree.
@objc protocol LegadoJsoupElementExport: JSExport {
    /// Lets the JS polyfill tell a native node from any other object.
    func isJsoupNode() -> Bool
    func select(_ query: String) -> [LegadoJsoupElement]
    func children() -> [LegadoJsoupElement]
    func parent() -> LegadoJsoupElement?
    func body() -> LegadoJsoupElement?
    func html() -> String
    func outerHtml() -> String
    func text() -> String
    func ownText() -> String
    func wholeText() -> String
    func data() -> String
    func attr(_ name: String) -> String
    func absUrl(_ name: String) -> String
    func hasAttr(_ name: String) -> Bool
    /// `[{key, value}, …]` in document order — jsoup's `Attributes` as the polyfill wraps it.
    func attributeList() -> [[String: String]]
    func tagName() -> String
    func id() -> String
    func className() -> String
    func title() -> String
    func matches(_ query: String) -> Bool
    func nextElementSibling() -> LegadoJsoupElement?
    func previousElementSibling() -> LegadoJsoupElement?
    func firstElementSibling() -> LegadoJsoupElement?
    func lastElementSibling() -> LegadoJsoupElement?
    func siblingElements() -> [LegadoJsoupElement]
    func elementSiblingIndex() -> Int
    /// jsoup `parents()`: the parent, its parent, and so on up to `<html>`; not the document.
    func parents() -> [LegadoJsoupElement]
    /// jsoup `closest(query)`: this element or its nearest ancestor that matches; `null` if none.
    func closest(_ query: String) -> LegadoJsoupElement?
    /// jsoup's `Node.equals`, which is identity: whether `other` reads this very node. Two
    /// reads of one node (`parent()` twice) are two wrappers of it.
    func isSameNode(_ other: JSValue) -> Bool
    /// jsoup `Element.clone()`: a deep copy in a tree of its own.
    func cloneElement() -> LegadoJsoupElement
    // jsoup mutators
    func remove()
    func setAttr(_ name: String, _ value: String)
    func removeAttr(_ name: String)
    func setText(_ text: String)
    func setHtml(_ html: String)
    func appendHtml(_ html: String)
    func prependHtml(_ html: String)
    func beforeHtml(_ html: String)
    func afterHtml(_ html: String)
    func empty()
}

/// Native backing for the `org.jsoup.*` JS polyfill (`JSCoreEngine.installJavaInterop`).
///
/// Legado runs on Rhino with real Java interop, so book-source JS can call
/// `org.jsoup.Jsoup.parse(html).select("body").html()` and get jsoup's own behaviour.
/// The polyfill used to answer every `select()` with an empty collection, which silently
/// produced empty content instead of failing loudly — 番茄酱's remote `to.js` extracts its
/// chapter body exactly that way. This delegates to SwiftSoup, the parser the rule engine
/// already uses, so the app keeps one HTML parser instead of two.
@objc protocol LegadoJsoupBridgeExport: JSExport {
    func parse(_ html: String, _ baseUri: JSValue) -> LegadoJsoupElement
    /// jsoup `new Element(tagName)`; `null` (and a thrown error) for a name jsoup rejects.
    func createElement(_ tagName: String) -> LegadoJsoupElement?
    func unescape(_ text: String) -> String
}

// MARK: - Element

@objc final class LegadoJsoupElement: NSObject, LegadoJsoupElementExport {

    /// Retained so the whole tree outlives any element JS is still holding.
    private let document: Document
    private let element: Element
    /// The parse cache that may hand `document` out again; told when a script changes it.
    private weak var cache: JsoupDocumentCache?

    init(document: Document, element: Element, cache: JsoupDocumentCache? = nil) {
        self.document = document
        self.element = element
        self.cache = cache
        super.init()
    }

    /// An element the rule engine selected, as a script reads it: inside the context's copy of
    /// its whole page (`LegadoScriptTrees`). The engine's tree belongs to the thread that parsed
    /// it (`RuleHTMLElement`).
    convenience init(detaching node: RuleHTMLElement, trees: LegadoScriptTrees) {
        let (document, element) = trees.copy(of: node.element)
        self.init(document: document, element: element)
    }

    /// This element copied out for the rule engine, when a script hands it back as a rule
    /// result. The copy is the engine's own; the script keeps this tree.
    func detachedRuleElement() -> RuleHTMLElement {
        RuleHTMLElement(RuleHTMLElement.detachedElement(element))
    }

    /// A rule-engine value as JS receives it: a selected element becomes a native node in the
    /// context's copy of its page (the polyfill's `__yueduJsoupWrap` makes it an `Element`), a
    /// list is converted item by item, anything else is unchanged.
    static func bridged(_ value: Any, trees: LegadoScriptTrees) -> Any {
        if let node = value as? RuleHTMLElement { return LegadoJsoupElement(detaching: node, trees: trees) }
        // jsoup's `Elements` even when empty; the key is what `__yueduJsoupWrap` reads.
        if let selection = value as? JsoupSelection {
            return ["__yueduJsoupSelection": selection.elements.map { bridged($0, trees: trees) }]
        }
        if let list = value as? [Any], list.contains(where: { $0 is RuleHTMLElement }) {
            return list.map { bridged($0, trees: trees) }
        }
        return value
    }

    /// The reverse, for a value a script hands the rule engine: a polyfill `Element` (or
    /// `Elements`) becomes a detached `RuleHTMLElement` (or a list of them); `nil` when
    /// `value` holds no element.
    static func ruleValue(from value: JSValue) -> Any? {
        guard value.isObject,
              let unwrap = value.context?.objectForKeyedSubscript("__yueduJsoupUnwrap"),
              !unwrap.isUndefined,
              let native = unwrap.call(withArguments: [value]),
              !native.isUndefined, !native.isNull
        else { return nil }
        if let node = native.toObject() as? LegadoJsoupElement { return node.detachedRuleElement() }
        if native.isArray, let nodes = native.toArray() as? [LegadoJsoupElement] {
            return nodes.map { $0.detachedRuleElement() }
        }
        return nil
    }

    private func wrap(_ other: Element?) -> LegadoJsoupElement? {
        other.map { LegadoJsoupElement(document: document, element: $0, cache: cache) }
    }

    private func wrap(_ others: [Element]) -> [LegadoJsoupElement] {
        others.map { LegadoJsoupElement(document: document, element: $0, cache: cache) }
    }

    func isJsoupNode() -> Bool { true }

    /// jsoup throws `Selector.SelectorParseException` for a query it cannot parse, and Rhino
    /// raises it in the script, where a source's `try`/`catch` can take another route. Answering
    /// it with an empty list instead turned a TOC whose script passed Legado rule syntax
    /// (`[id="ul_all_chapters"]@li`) to `select` into a silent 0 chapters with no JS error.
    func select(_ query: String) -> [LegadoJsoupElement] {
        do {
            return wrap(try element.select(query).array())
        } catch {
            raise(error, as: "org.jsoup.select.Selector$SelectorParseException", context: ["query": query])
            return []
        }
    }

    func matches(_ query: String) -> Bool {
        do {
            return try element.iS(query)
        } catch {
            raise(error, as: "org.jsoup.select.Selector$SelectorParseException", context: ["query": query])
            return false
        }
    }

    /// Raises `error` in the calling script, as Rhino raises a Java exception there.
    private func raise(_ error: Error, as javaClass: String, context: [String: String]) {
        var logContext = context
        logContext["error"] = "\(error)"
        AppLogger.parse("jsoup bridge call failed", context: logContext)
        if let jsContext = JSContext.current() {
            jsContext.exception = JSValue(
                newErrorFromMessage: "\(javaClass): \(Self.message(of: error))",
                in: jsContext
            )
        }
    }

    private static func message(of error: Error) -> String {
        guard case Exception.Error(_, let message) = error else { return "\(error)" }
        return message
    }

    func children() -> [LegadoJsoupElement] { wrap(element.children().array()) }

    func parent() -> LegadoJsoupElement? { wrap(element.parent()) }

    func body() -> LegadoJsoupElement? { wrap(document.body()) }

    func html() -> String { (try? element.html()) ?? "" }
    func outerHtml() -> String { (try? element.outerHtml()) ?? "" }
    func text() -> String { (try? element.text()) ?? "" }
    func ownText() -> String { element.ownText() }
    /// jsoup `Element.wholeText()`: every descendant text node as written, whitespace kept.
    func wholeText() -> String {
        var text = ""
        func collect(_ node: Node) {
            if let textNode = node as? TextNode { text += textNode.getWholeText() }
            node.getChildNodes().forEach(collect)
        }
        collect(element)
        return text
    }
    /// jsoup `Element.data()`: the contents of `<script>`/`<style>` data nodes, which `text()`
    /// leaves out. Sources read inline script variables this way (`java.getElement("script")`).
    func data() -> String { element.data() }
    func attr(_ name: String) -> String {
        if name.lowercased().hasPrefix("abs:") { return absUrl(String(name.dropFirst(4))) }
        return (try? element.attr(name)) ?? ""
    }
    func absUrl(_ name: String) -> String { (try? element.absUrl(name)) ?? "" }
    func hasAttr(_ name: String) -> Bool { element.hasAttr(name) }
    func attributeList() -> [[String: String]] {
        guard let attributes = element.getAttributes() else { return [] }
        return attributes.map { ["key": $0.getKey(), "value": $0.getValue()] }
    }
    func tagName() -> String { element.tagName() }
    func id() -> String { element.id() }
    func className() -> String { (try? element.className()) ?? "" }
    func title() -> String { (try? document.title()) ?? "" }

    func nextElementSibling() -> LegadoJsoupElement? { wrap(try? element.nextElementSibling()) }
    func previousElementSibling() -> LegadoJsoupElement? { wrap(try? element.previousElementSibling()) }
    func firstElementSibling() -> LegadoJsoupElement? { wrap(element.firstElementSibling()) }
    func lastElementSibling() -> LegadoJsoupElement? { wrap(element.lastElementSibling()) }
    func siblingElements() -> [LegadoJsoupElement] { wrap(element.siblingElements().array()) }
    func elementSiblingIndex() -> Int { (try? element.elementSiblingIndex()) ?? 0 }
    func parents() -> [LegadoJsoupElement] { wrap(element.parents().array()) }

    func closest(_ query: String) -> LegadoJsoupElement? {
        do {
            var current: Element? = element
            while let candidate = current {
                if try candidate.iS(query) { return wrap(candidate) }
                current = candidate.parent()
            }
            return nil
        } catch {
            raise(error, as: "org.jsoup.select.Selector$SelectorParseException", context: ["query": query])
            return nil
        }
    }

    func isSameNode(_ other: JSValue) -> Bool {
        (other.toObject() as? LegadoJsoupElement).map { $0.element === element } ?? false
    }

    /// A script cleans the copy (`c.select('a,script,style').remove()`) and reads it, leaving
    /// the page it came from as it was — 桔纸书屋 (YCK1330) builds every chapter that way, and
    /// without `clone` its content rule threw `box.clone is not a function`.
    func cloneElement() -> LegadoJsoupElement {
        let copy = RuleHTMLElement.detachedElement(element)
        return LegadoJsoupElement(document: copy.ownerDocument() ?? Document(copy.getBaseUri()), element: copy)
    }

    // MARK: Mutators

    private func mutate(_ name: String, _ change: () throws -> Void) {
        cache?.evict(document)
        do {
            try change()
        } catch {
            raise(error, as: "java.lang.IllegalArgumentException", context: ["call": name])
        }
    }

    func remove() { mutate("remove") { try element.remove() } }
    func setAttr(_ name: String, _ value: String) { mutate("attr") { _ = try element.attr(name, value) } }
    func removeAttr(_ name: String) { mutate("removeAttr") { _ = try element.removeAttr(name) } }
    func setText(_ text: String) { mutate("text") { _ = try element.text(text) } }
    func setHtml(_ html: String) { mutate("html") { _ = try element.html(html) } }
    func appendHtml(_ html: String) { mutate("append") { _ = try element.append(html) } }
    func prependHtml(_ html: String) { mutate("prepend") { _ = try element.prepend(html) } }
    func beforeHtml(_ html: String) { mutate("before") { _ = try element.before(html) } }
    func afterHtml(_ html: String) { mutate("after") { _ = try element.after(html) } }
    func empty() { mutate("empty") { _ = element.empty() } }
}

// MARK: - Bridge

@objc final class LegadoJsoupBridge: NSObject, LegadoJsoupBridgeExport {
    /// Owned by one JSContext and accessed on that context's serial queue. Its nodes
    /// may outlive an evaluation, so a thread-local extractor cache is not an owner.
    private let documentCache = JsoupDocumentCache()

    /// `org.jsoup.Jsoup.parse(html[, baseUri])` — returns the document node.
    /// Never returns null: a parse failure yields an empty document so source JS fails on
    /// missing content rather than on a null dereference deep inside obfuscated code.
    func parse(_ html: String, _ baseUri: JSValue) -> LegadoJsoupElement {
        let base = (baseUri.isUndefined || baseUri.isNull) ? "" : (baseUri.toString() ?? "")
        let document: Document
        do {
            // SwiftSoup also writes indexes during reads. A retained JS wrapper must not
            // share those indexes with an extractor or another context, even when their
            // queues happen to execute on the same thread during the initial parse.
            document = try documentCache.document(for: html, baseURL: base)
        } catch {
            AppLogger.parse("jsoup bridge parse failed", context: ["error": "\(error)"])
            document = Document(base)
        }
        return LegadoJsoupElement(document: document, element: document, cache: documentCache)
    }

    /// jsoup `new Element(tagName)`: an element of its own, in no document. 黄区 (YCK1330)
    /// builds its play list from `new org.jsoup.nodes.Element('a')`.
    func createElement(_ tagName: String) -> LegadoJsoupElement? {
        let document = Document("")
        do {
            return LegadoJsoupElement(document: document, element: try document.createElement(tagName))
        } catch {
            if let context = JSContext.current() {
                context.exception = JSValue(newErrorFromMessage: "jsoup Element(\(tagName)): \(error)", in: context)
            }
            return nil
        }
    }

    /// `org.jsoup.parser.Parser.unescapeEntities(string, inAttribute)`: HTML entities decoded.
    /// 格格党网 decodes every field this way.
    func unescape(_ text: String) -> String {
        do {
            return try Entities.unescape(text)
        } catch {
            AppLogger.parse("jsoup unescapeEntities failed", context: ["error": "\(error)"])
            return text
        }
    }
}
