import Foundation
import JavaScriptCore
import SwiftSoup

// MARK: - JSExport Protocols

/// A single parsed node handed to JS. JavaScriptCore owns the lifetime: the JS wrapper holds
/// this object, and it holds the owning `Document` (SwiftSoup's `parentNode` is weak, so the
/// tree would otherwise be freed while JS still points into it).
///
/// Read-only by design — one JSContext reuses its parsed documents, so mutating one
/// here would change other wrappers that source JS still holds for the same markup.
@objc protocol LegadoJsoupElementExport: JSExport {
    func select(_ query: String) -> [LegadoJsoupElement]
    func children() -> [LegadoJsoupElement]
    func parent() -> LegadoJsoupElement?
    func body() -> LegadoJsoupElement?
    func html() -> String
    func outerHtml() -> String
    func text() -> String
    func ownText() -> String
    func attr(_ name: String) -> String
    func hasAttr(_ name: String) -> Bool
    func tagName() -> String
    func id() -> String
    func className() -> String
    func title() -> String
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
}

// MARK: - Element

@objc final class LegadoJsoupElement: NSObject, LegadoJsoupElementExport {

    /// Retained so the whole tree outlives any element JS is still holding.
    private let document: Document
    private let element: Element

    init(document: Document, element: Element) {
        self.document = document
        self.element = element
        super.init()
    }

    /// jsoup throws `Selector.SelectorParseException` for a query it cannot parse, and Rhino
    /// raises it in the script, where a source's `try`/`catch` can take another route. Answering
    /// it with an empty list instead turned a TOC whose script passed Legado rule syntax
    /// (`[id="ul_all_chapters"]@li`) to `select` into a silent 0 chapters with no JS error.
    func select(_ query: String) -> [LegadoJsoupElement] {
        do {
            return try element.select(query).map { LegadoJsoupElement(document: document, element: $0) }
        } catch {
            AppLogger.parse(
                "jsoup bridge select failed",
                context: ["query": query, "error": "\(error)"]
            )
            if let context = JSContext.current() {
                context.exception = JSValue(
                    newErrorFromMessage: "org.jsoup.select.Selector$SelectorParseException: \(Self.message(of: error))",
                    in: context
                )
            }
            return []
        }
    }

    private static func message(of error: Error) -> String {
        guard case Exception.Error(_, let message) = error else { return "\(error)" }
        return message
    }

    func children() -> [LegadoJsoupElement] {
        element.children().map { LegadoJsoupElement(document: document, element: $0) }
    }

    func parent() -> LegadoJsoupElement? {
        guard let parent = element.parent() else { return nil }
        return LegadoJsoupElement(document: document, element: parent)
    }

    func body() -> LegadoJsoupElement? {
        guard let body = document.body() else { return nil }
        return LegadoJsoupElement(document: document, element: body)
    }

    func html() -> String { (try? element.html()) ?? "" }
    func outerHtml() -> String { (try? element.outerHtml()) ?? "" }
    func text() -> String { (try? element.text()) ?? "" }
    func ownText() -> String { element.ownText() }
    func attr(_ name: String) -> String { (try? element.attr(name)) ?? "" }
    func hasAttr(_ name: String) -> Bool { element.hasAttr(name) }
    func tagName() -> String { element.tagName() }
    func id() -> String { element.id() }
    func className() -> String { (try? element.className()) ?? "" }
    func title() -> String { (try? document.title()) ?? "" }
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
        return LegadoJsoupElement(document: document, element: document)
    }
}
