import Testing
import Foundation
import JavaScriptCore
@testable import yuedu_app

/// 晴天起点 (`🔅企点小说`) writes its own recovery around the call, and that shape is
/// what decides whether `androidId()` answers empty or raises. Verbatim from the
/// source's `request()` wrapper.
private let sourceSideFallbackJS = """
const { java } = this;
let device = '';
try {
    device = java.androidId();
} catch {
    try {
        device = java.deviceID();
    } catch {}
}
"""

/// What 知秋's `requestApiUrl` does: nothing catches this, so an exception here
/// would take the whole request down.
private let bareCallJS = "let device = java.androidId();"

/// With 以 Android 身分回報 off — the correct default — sources that use
/// `java.androidId()` as a real device key have their requests refused with
/// 「缺少设备信息」, and the toggle that fixes it is three screens away in
/// 書源編輯 → 基本. `AndroidIdentityRecovery` decides when a failure surface should
/// offer that toggle, and the point of these tests is the *narrowness* of that
/// offer: proposing it to a source that only probes for the platform would break
/// the source instead of fixing it.
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

/// The empty string `androidId()` returns is a *false success* for a source that
/// wrapped the call in `try`: its `catch` never fires, so the `deviceID()` recovery
/// it wrote is dead code and the request goes out with an empty device — which is
/// what 晴天起点's server refuses with 「缺少设备信息」. Sources that wrote that
/// recovery get an exception instead; everyone else must keep getting the empty
/// string, because a bare call cannot absorb a throw.
@Suite("Android identity source-side fallback")
struct AndroidIdentityFallbackShapeTests {

    private func source(url: String, js: String) -> BookSource {
        var source = BookSource(bookSourceUrl: url, bookSourceName: "shape")
        source.jsLib = js
        return source
    }

    @Test("recognises the try/catch → deviceID recovery")
    func recognisesFallback() {
        #expect(AndroidIdentityRecovery.handlesMissingAndroidId(
            source(url: "https://sf1.example.com", js: sourceSideFallbackJS)))
    }

    @Test("a bare call is not a recovery")
    func bareCallIsNotFallback() {
        #expect(!AndroidIdentityRecovery.handlesMissingAndroidId(
            source(url: "https://sf2.example.com", js: bareCallJS)))
    }

    /// The two have to belong to the same recovery. A source that merely mentions
    /// both somewhere in 250KB of rules must not be handed exceptions.
    @Test("an unrelated deviceID call elsewhere is not a recovery")
    func distantDeviceIDIsNotFallback() {
        let js = """
        let device = java.androidId();
        \(String(repeating: "// filler\n", count: 80))
        try { java.deviceID() } catch {}
        """
        #expect(!AndroidIdentityRecovery.handlesMissingAndroidId(
            source(url: "https://sf3.example.com", js: js)))
    }

    /// `catch` without a `deviceID` recovery is 晴天起点's *platform* probe
    /// (`try { java.deviceID(); deviceType = '苹果' } catch {}`), not this one.
    @Test("a catch that does not reach for deviceID is not a recovery")
    func catchWithoutDeviceIDIsNotFallback() {
        let js = "try { device = java.androidId() } catch { device = '' }"
        #expect(!AndroidIdentityRecovery.handlesMissingAndroidId(
            source(url: "https://sf4.example.com", js: js)))
    }
}

/// What the source's JS actually observes. These run the real bridge inside a real
/// `JSContext`, because the whole point of the change is a JS-visible difference
/// that a Swift-level return value cannot express.
@Suite("Android identity as JS sees it")
struct AndroidIdentityJSBehaviorTests {

    private func context(handlesMissing: Bool, optedIn: Bool = false) -> JSContext {
        let context = JSContext()!
        let bridge = LegadoJSBridge()
        bridge.presentsAndroidIdentityProvider = { optedIn }
        bridge.handlesMissingAndroidIdProvider = { handlesMissing }
        context.setObject(bridge, forKeyedSubscript: "java" as NSString)
        return context
    }

    @Test("a source that wrote a recovery sees a thrown error")
    func throwsForRecoveringSource() {
        let result = context(handlesMissing: true).evaluateScript("""
        var out = 'no-throw';
        try { java.androidId(); } catch (e) { out = 'threw'; }
        out
        """)
        #expect(result?.toString() == "threw")
    }

    /// The regression this whole change is about: 晴天起点's wrapper has to come out
    /// of that `catch` holding a real device id, not an empty string.
    @Test("the source's own recovery yields a device id")
    func recoveryProducesDeviceId() {
        let result = context(handlesMissing: true).evaluateScript("""
        let device = '';
        try { device = java.androidId(); }
        catch { try { device = java.deviceID(); } catch {} }
        device
        """)
        #expect(result?.toString().isEmpty == false)
    }

    /// Unchanged for everyone else: a bare call must not raise, or 知秋's
    /// `requestApiUrl` loses the entire request.
    @Test("a bare call still gets an empty string, never an exception")
    func bareCallStaysEmpty() {
        let result = context(handlesMissing: false).evaluateScript("""
        var out = java.androidId();
        out === '' ? 'empty' : 'value'
        """)
        #expect(result?.toString() == "empty")
    }

    /// Opting in wins over the shape: the source asked for an Android id, so it gets
    /// one rather than an exception.
    @Test("an opted-in source is answered even when it wrote a recovery")
    func optedInBeatsShape() {
        let result = context(handlesMissing: true, optedIn: true).evaluateScript("""
        var out = 'threw';
        try { out = java.androidId(); } catch (e) {}
        out
        """)
        #expect(result?.toString().count == 16)
    }
}
