import Foundation
import Testing
@testable import yuedu_app

/// `java.ajaxAll(list)` with a list whose elements are not all
/// strings. Every Legado fork declares the parameter `Array<String>`, and Rhino converts each
/// element with JS ToString — an object becomes `"[object Object]"`, a number its digits — so the
/// call answers one response per element and never throws. Our bridge used to take `[String]`:
/// JavaScriptCore bridged the list to an `NSArray` of `NSDictionary`/`NSNumber`, and Swift's forced
/// bridging cast aborted the app before the method ran (Crashlytics 730ebcbc, 3.0.0 (143)).
@Suite("java.ajaxAll argument coercion")
struct AjaxAllArgumentCoercionTests {
    private static func bridge() -> ModernParserBridge {
        let source = BookSource(
            bookSourceUrl: "https://ajaxall-coercion-\(UUID().uuidString).invalid",
            bookSourceName: "ajaxAll coercion"
        )
        let bridge = ModernParserBridge(source: source)
        // Called from ajaxAll's workers, several at once: derive the answer from the request only.
        bridge.sourceScriptNetworkHandler = { request, _ in
            .bodyOnly(request: request, body: request.url?.lastPathComponent ?? "?")
        }
        return bridge
    }

    @Test("An array of objects answers one response per element instead of aborting")
    func objectElements() {
        let bridge = Self.bridge()
        let value = bridge.evaluateSourceScript(
            "var r = java.ajaxAll([{url:'http://127.0.0.1:1/x'}, {url:'http://127.0.0.1:1/y'}]);"
                + " r.length + ':' + r.map(function (x) { return typeof x.body(); }).join(',')"
        )
        #expect(value == "2:string,string")
    }

    @Test("A mixed array keeps its order: strings are fetched, the rest are coerced like Rhino")
    func mixedElements() {
        let bridge = Self.bridge()
        let value = bridge.evaluateSourceScript(
            "var r = java.ajaxAll(['https://ajaxall.invalid/a', 42, {url:'x'}, null, 'https://ajaxall.invalid/b']);"
                + " r.length + ':' + r[0].body() + '|' + r[4].body()"
        )
        #expect(value == "5:a|b")
    }

    @Test("A list that is not an array answers no responses")
    func notAnArray() {
        let bridge = Self.bridge()
        let value = bridge.evaluateSourceScript("String(java.ajaxAll({url:'x'}).length)")
        #expect(value == "0")
    }
}
