import Testing
import Foundation
import JavaScriptCore
@testable import yuedu_app

/// With 以 Android 身分回報 off — the correct default — sources that use
/// `java.androidId()` as a real device key have their requests refused, and the
/// toggle that fixes it is three screens away in 書源編輯 → 基本.
/// `AndroidIdentityRecovery` decides when a failure surface should offer that
/// toggle, and the point of these tests is the *narrowness* of that offer:
/// proposing it to a source that only probes for the platform would break the
/// source instead of fixing it.
@Suite("Android identity recovery offer")
struct AndroidIdentityRecoveryTests {

    /// A source whose JS asks for a device id, the way 知秋's family does.
    private func deviceKeySource(
        url: String,
        optedIn: Bool = false
    ) -> BookSource {
        var source = BookSource(bookSourceUrl: url, bookSourceName: "device-key")
        source.jsLib = "function deviceKey(){ return java.androidId() }"
        source.presentsAndroidIdentity = optedIn
        return source
    }

    @Test("offered when the source wants a device id and the API says it is missing")
    func offersForDeviceKeySource() {
        let source = deviceKeySource(url: "https://a.example.com")
        #expect(AndroidIdentityRecovery.canRepair(source, failureMessage: "缺少设备信息"))
    }

    /// Nothing to turn on.
    @Test("not offered once the source has opted in")
    func notOfferedWhenAlreadyOn() {
        let source = deviceKeySource(url: "https://b.example.com", optedIn: true)
        #expect(!AndroidIdentityRecovery.canRepair(source, failureMessage: "缺少设备信息"))
    }

    /// The narrowing that matters: a source that never calls `androidId()` cannot be
    /// repaired by handing it one, however device-shaped its error text reads.
    @Test("not offered to a source that never asks for a device id")
    func notOfferedWhenSourceNeverAsks() {
        var source = BookSource(bookSourceUrl: "https://c.example.com", bookSourceName: "plain")
        source.jsLib = "function id(){ return java.deviceID() }"
        #expect(!AndroidIdentityRecovery.canRepair(source, failureMessage: "缺少设备信息"))
    }

    /// 书山聚合 calls `androidId()` too, but only to ask which platform it is on —
    /// answering it is what broke its chapter loading. Its failures don't name a
    /// device identifier, and that is the whole reason the message is consulted.
    @Test("not offered for a failure that says nothing about a device")
    func notOfferedForUnrelatedFailure() {
        let source = deviceKeySource(url: "https://d.example.com")
        #expect(!AndroidIdentityRecovery.canRepair(source, failureMessage: "HTTP 503 · 連線逾時"))
    }

    @Test("no failure text at all is not an offer")
    func notOfferedWithoutAnyMessage() {
        let source = deviceKeySource(url: "https://e.example.com")
        #expect(!AndroidIdentityRecovery.canRepair(source, failureMessage: nil))
    }

    /// The reader passes `error.localizedDescription`, which wraps the server's own
    /// words — the match has to survive that envelope.
    @Test("matches the server's words inside the reader's failure reason")
    func matchesWrappedReason() {
        let source = deviceKeySource(url: "https://f.example.com")
        #expect(AndroidIdentityRecovery.canRepair(
            source, failureMessage: "Source API error: 缺少设备信息"))
    }

    @Test("matches traditional and English phrasings", arguments: [
        "缺少裝置資訊", "设备标识为空", "missing device id", "androidId required",
    ])
    func matchesPhrasing(_ message: String) {
        let source = deviceKeySource(url: "https://g-\(message.hashValue).example.com")
        #expect(AndroidIdentityRecovery.canRepair(source, failureMessage: message))
    }

    /// The `androidId` scan reads the whole encoded source, not one field: sources
    /// put the call in `jsLib`, in a rule, or in the header.
    @Test("finds the call in a content rule, not only jsLib")
    func findsCallInRule() {
        var source = BookSource(bookSourceUrl: "https://h.example.com", bookSourceName: "rule")
        source.ruleContent.content = "@js:java.androidId()"
        #expect(AndroidIdentityRecovery.canRepair(source, failureMessage: "缺少设备信息"))
    }
}

/// What the source's JS actually observes when it asks for a device id.
///
/// `androidId()` answers with a string and NEVER raises. Raising for sources that
/// look like they wrap the call in a `try` was tried and reverted — whether a throw
/// can be absorbed is a property of the call site, not of the source, and a bare
/// `java.androidId()` inside a `<js>` searchUrl aborts the whole script, leaving the
/// URL unevaluated and every search failing with `Invalid URL`. These tests exist to
/// keep it that way.
@Suite("Android identity as JS sees it")
struct AndroidIdentityJSBehaviorTests {

    private func context(optedIn: Bool) -> JSContext {
        let context = JSContext()!
        let bridge = LegadoJSBridge()
        bridge.presentsAndroidIdentityProvider = { optedIn }
        context.setObject(bridge, forKeyedSubscript: "java" as NSString)
        return context
    }

    @Test("a bare call gets an empty string, never an exception")
    func bareCallStaysEmpty() {
        let result = context(optedIn: false).evaluateScript("""
        var out = 'threw';
        try { out = java.androidId() === '' ? 'empty' : 'value'; } catch (e) {}
        out
        """)
        #expect(result?.toString() == "empty")
    }

    /// The `Invalid URL` shape: a `<js>` searchUrl that calls `androidId()` bare. If
    /// the bridge raised there, the assignment would never happen, the script would
    /// abort, and the URL would come back empty.
    @Test("a bare call inside a searchUrl script still produces a URL")
    func bareCallInSearchUrlScriptStillResolves() {
        let result = context(optedIn: false).evaluateScript("""
        var url = '';
        var id = java.androidId();
        url = 'https://example.com/search?device=' + id;
        url
        """)
        #expect(result?.toString() == "https://example.com/search?device=")
    }

    /// A source that wrapped the call in `try` must still reach the line after it —
    /// its `catch` is for a platform that raises, and this one does not.
    @Test("a guarded call does not enter its catch branch")
    func guardedCallDoesNotThrow() {
        let result = context(optedIn: false).evaluateScript("""
        var branch = 'none';
        try { java.androidId(); branch = 'try'; } catch (e) { branch = 'catch'; }
        branch
        """)
        #expect(result?.toString() == "try")
    }

    @Test("an opted-in source gets a 16-character lowercase hex id")
    func optedInGetsId() {
        let result = context(optedIn: true).evaluateScript("java.androidId()")
        let id = result?.toString() ?? ""
        #expect(id.count == 16)
        #expect(id == id.lowercased())
        #expect(id.allSatisfy { $0.isHexDigit })
    }
}
