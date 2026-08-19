import Foundation
import Testing
@testable import yuedu_app

/// The capture points sit on the request path of every source fetch and on every
/// rule evaluation. `logParse` alone fires tens of thousands of times during an
/// aggregate search, so "off means genuinely off" is the load-bearing property here —
/// more than any of the formatting.
/// `.serialized` because every test drives the same singleton. Run in parallel they
/// clear each other's buffers and flip each other's gate mid-assertion.
@Suite("WebCrawlerDebugger", .serialized)
@MainActor
struct WebCrawlerDebuggerTests {

    /// Closes the gate, lets any append already in flight land, and only then clears —
    /// clearing first would leave a straggler to show up inside the next test.
    private func freshStart() async {
        WebCrawlerDebugger.shared.isRecording = false
        WebCrawlerDebugger.shared.includesParseEvents = false
        await settle()
        WebCrawlerDebugger.shared.clear()
    }

    /// Appends hop to the main actor, so an assertion has to wait for them. Polls for
    /// the expected state instead of sleeping a fixed amount: the hop is normally a
    /// single runloop turn, and a fixed delay would be both slower and flakier.
    private func wait(
        until condition: @MainActor () -> Bool,
        timeout: Duration = .milliseconds(2000)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets pending appends land when there is no specific condition to wait for.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("nothing is captured while recording is off")
    func offCapturesNothing() async {
        await freshStart()
        WebCrawlerDebugger.logRequest(url: "https://example.com", method: "GET", headers: [:])
        WebCrawlerDebugger.logResponse(url: "https://example.com", statusCode: 200, htmlBody: "hi")
        WebCrawlerDebugger.logParse(rule: "a@href", matchCount: 3, url: "https://example.com")
        WebCrawlerDebugger.logError(URLError(.timedOut), url: "https://example.com")
        await settle()
        #expect(WebCrawlerDebugger.shared.logs.isEmpty)
    }

    @Test("network exchanges are captured once recording is on")
    func networkIsCaptured() async {
        await freshStart()
        WebCrawlerDebugger.shared.isRecording = true
        WebCrawlerDebugger.logRequest(url: "https://example.com/s", method: "POST", headers: ["A": "b"])
        WebCrawlerDebugger.logResponse(url: "https://example.com/s", statusCode: 403, htmlBody: "denied")
        await wait { WebCrawlerDebugger.shared.logs.count == 2 }

        let logs = WebCrawlerDebugger.shared.logs
        #expect(logs.count == 2)
        #expect(logs.first?.type == .request)
        #expect(logs.first?.message == "POST")
        #expect(logs.last?.type == .response)
        #expect(logs.last?.message.contains("403") == true)
        await freshStart()
    }

    /// Rule matches outnumber requests by orders of magnitude, so they need their own
    /// opt-in on top of recording — otherwise one search evicts every request from
    /// the buffer before the user can look at it.
    @Test("rule matches need their own opt-in")
    func parseEventsAreSeparatelyGated() async {
        await freshStart()
        WebCrawlerDebugger.shared.isRecording = true
        WebCrawlerDebugger.logParse(rule: "a@href", matchCount: 3, url: "https://example.com")
        await settle()
        #expect(WebCrawlerDebugger.shared.logs.isEmpty)

        WebCrawlerDebugger.shared.includesParseEvents = true
        WebCrawlerDebugger.logParse(rule: "a@href", matchCount: 3, url: "https://example.com")
        await wait { WebCrawlerDebugger.shared.logs.count == 1 }
        #expect(WebCrawlerDebugger.shared.logs.count == 1)
        #expect(WebCrawlerDebugger.shared.logs.first?.type == .parseEvent)
        await freshStart()
    }

    @Test("rule matches stay off when recording is off, even if opted in")
    func parseRequiresRecording() async {
        await freshStart()
        WebCrawlerDebugger.shared.includesParseEvents = true
        WebCrawlerDebugger.logParse(rule: "a@href", matchCount: 1, url: "u")
        await settle()
        #expect(WebCrawlerDebugger.shared.logs.isEmpty)
        await freshStart()
    }

    @Test("response bodies are truncated so one chapter cannot hold megabytes")
    func bodiesAreTruncated() async {
        await freshStart()
        WebCrawlerDebugger.shared.isRecording = true
        WebCrawlerDebugger.logResponse(
            url: "u", statusCode: 200, htmlBody: String(repeating: "x", count: 200_000)
        )
        await wait { !WebCrawlerDebugger.shared.logs.isEmpty }

        guard case .body(let stored)? = WebCrawlerDebugger.shared.logs.first?.detail else {
            Issue.record("expected a body detail"); await freshStart(); return
        }
        #expect(stored.count <= 8 * 1024)
        // The reported size is still the real one — truncation must not lie about
        // what came back.
        #expect(WebCrawlerDebugger.shared.logs.first?.message.contains("200000") == true)
        await freshStart()
    }

    @Test("the buffer is bounded and keeps the newest entries")
    func bufferIsBounded() async {
        await freshStart()
        WebCrawlerDebugger.shared.isRecording = true
        for index in 0..<700 {
            WebCrawlerDebugger.logInfo("entry \(index)")
        }
        await wait { WebCrawlerDebugger.shared.logs.last?.message == "entry 699" }

        let logs = WebCrawlerDebugger.shared.logs
        #expect(logs.count <= 500)
        #expect(logs.last?.message == "entry 699")
        await freshStart()
    }

    @Test("clear empties the buffer")
    func clearEmpties() async {
        await freshStart()
        WebCrawlerDebugger.shared.isRecording = true
        WebCrawlerDebugger.logInfo("x")
        await wait { !WebCrawlerDebugger.shared.logs.isEmpty }
        #expect(!WebCrawlerDebugger.shared.logs.isEmpty)
        WebCrawlerDebugger.shared.clear()
        #expect(WebCrawlerDebugger.shared.logs.isEmpty)
        await freshStart()
    }
}
