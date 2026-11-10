import Foundation
import Testing
@testable import yuedu_app

/// A TTS source's login menu runs its scripts on `SourceScriptThread`, as Legado's
/// `SourceLoginDialog` runs them on its IO dispatcher. The form used to evaluate them on the
/// main thread, where a button that opened a verification page (`java.startBrowserAwait`)
/// held the thread the page is presented on: the form froze for the engine's 30 s timeout and
/// the page's answer was lost.
@MainActor
@Suite("TTS source login scripts", .serialized)
struct TTSLoginScriptTests {
    @Test("a login button that waits on a verification page gets the page's answer")
    func buttonWaitingOnPageGetsAnswer() async throws {
        let previous = LegadoJSBridge.sharedBrowserPresenter
        // Like SourceBrowserPresenter: the page appears, and answers, on the main thread.
        LegadoJSBridge.sharedBrowserPresenter = { _, completion in
            Task { @MainActor in completion("<html>verified</html>") }
        }
        defer { LegadoJSBridge.sharedBrowserPresenter = previous }

        let source = Self.source(loginUrl: """
        function verify() {
            var page = java.startBrowserAwait('https://tts.example/verify', '驗證', false);
            source.putLoginInfo(JSON.stringify({ page: String(page.body()) }));
        }
        """)
        defer { LoginManager.shared.clearLogin(sourceUrl: source.id) }

        let shown = ShownLoginInfo()
        let script = TTSLoginScript(source: source) { shown.record($0) }
        let started = Date()
        await script.run(action: "verify()", values: [:])

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: source.id)?["page"] == "<html>verified</html>")
        #expect(shown.last?["page"] == "<html>verified</html>")
    }

    /// Legado's `SourceLoginDialog.handleButtonClick` binds `result` to the form
    /// (`getLoginData`, a `HashMap`). A TTS button used to run with no `result` at all.
    @Test("a login button reads the form through result.get")
    func buttonReadsFormAsJavaMap() async throws {
        let source = Self.source(loginUrl: """
        function verify() {
            source.putLoginInfo(JSON.stringify({ key: String(result.get('密鑰')) }));
        }
        """)
        defer { LoginManager.shared.clearLogin(sourceUrl: source.id) }
        let script = TTSLoginScript(source: source) { _ in }

        await script.run(action: "verify()", values: ["密鑰": "abc123"])

        #expect(LoginManager.shared.getLoginInfo(sourceUrl: source.id)?["key"] == "abc123")
    }

    @Test("dynamic labels resolve in the engine that loaded loginUrl")
    func labelsUseLoginUrlFunctions() async throws {
        let source = Self.source(loginUrl: "function status() { return '已登入'; }")
        let fields = LoginManager.shared.parseLoginUi(
            #"[{"name":"狀態","type":"button","action":"status()","viewName":"status()"},{"name":"說明","type":"button","viewName":"'固定文字'"}]"#
        )
        let script = TTSLoginScript(source: source) { _ in }

        let labels = await script.labels(for: fields, values: [:])

        #expect(labels == ["狀態": "已登入"])
    }

    private static func source(loginUrl: String) -> ImportedTTSSource {
        ImportedTTSSource(
            name: "tts login fixture",
            urlTemplate: "https://tts.example/speak",
            sourceID: "tts-login-\(UUID().uuidString)",
            loginUi: #"[{"name":"驗證","type":"button","action":"verify()"}]"#,
            loginUrl: loginUrl
        )
    }
}

private final class ShownLoginInfo: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: String]] = []

    func record(_ info: [String: String]) {
        lock.lock()
        values.append(info)
        lock.unlock()
    }

    var last: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}
