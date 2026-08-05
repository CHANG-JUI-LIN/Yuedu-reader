import Foundation
import JavaScriptCore
import SwiftSoup

// MARK: - JSExport Protocols

/// A single parsed node handed to JS. JavaScriptCore owns the lifetime: the JS wrapper holds
/// this object, and it holds the owning `Document` (SwiftSoup's `parentNode` is weak, so the
/// tree would otherwise be freed while JS still points into it).
///
/// Read-only by design — documents come from the shared `JsoupDocumentCache`, so mutating one
/// here would corrupt every other reader of the same markup.
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

    func select(_ query: String) -> [LegadoJsoupElement] {
        do {
            return try element.select(query).map { LegadoJsoupElement(document: document, element: $0) }
        } catch {
            AppLogger.parse(
                "jsoup bridge select failed",
                context: ["query": query, "error": "\(error)"]
            )
            return []
        }
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

    /// `org.jsoup.Jsoup.parse(html[, baseUri])` — returns the document node.
    /// Never returns null: a parse failure yields an empty document so source JS fails on
    /// missing content rather than on a null dereference deep inside obfuscated code.
    func parse(_ html: String, _ baseUri: JSValue) -> LegadoJsoupElement {
        let base = (baseUri.isUndefined || baseUri.isNull) ? "" : (baseUri.toString() ?? "")
        let document: Document
        do {
            // Per-thread cache (see `JsoupDocumentCache`): source JS that parses the same
            // response twice on the JS queue reuses one DOM, but the rule engine's
            // extractors — running on a different thread — get their own. That separation
            // is deliberate and load-bearing: SwiftSoup writes node state during reads, and
            // this bridge racing an extractor over one shared Document is what crashed in
            // `Attributes.getIgnoreCaseSlice`.
            document = try JsoupDocumentCache.current.document(for: html, baseURL: base)
        } catch {
            AppLogger.parse("jsoup bridge parse failed", context: ["error": "\(error)"])
            document = Document(base)
        }
        return LegadoJsoupElement(document: document, element: document)
    }
}
