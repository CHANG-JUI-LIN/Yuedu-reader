import Foundation
import Testing
import os.log
@testable import yuedu_app

@Suite("DiagnosticLog")
struct DiagnosticLogTests {

    /// Each test gets its own directory: the shared instance writes to the real
    /// device log, which a test must neither read nor destroy.
    private func makeLog(verbose: Bool = true) -> (DiagnosticLog, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-log-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DiagnosticLog(directory: dir, verboseOverride: verbose), dir)
    }

    @Test("records survive a flush and come back newest first")
    func recordsRoundTrip() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        log.record(severity: .info, category: .reader, message: "first")
        log.record(severity: .error, category: .network, message: "second")

        let entries = log.snapshot()
        #expect(entries.count == 2)
        #expect(entries.first?.message == "second")
        #expect(entries.last?.message == "first")
        #expect(entries.first?.category == .network)
    }

    @Test("detail is preserved")
    func detailRoundTrips() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        log.record(severity: .anomaly, category: .reader, message: "m", detail: "line1\nline2")
        #expect(log.snapshot().first?.detail == "line1\nline2")
    }

    // MARK: - Verbose gate

    @Test("trace lines are dropped when verbose is off, everything else is kept")
    func verboseGateDropsOnlyTrace() {
        let (log, dir) = makeLog(verbose: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        log.record(severity: .trace, category: .reader, message: "chatter")
        log.record(severity: .info, category: .reader, message: "milestone")
        log.record(severity: .anomaly, category: .reader, message: "problem")

        let messages = log.snapshot().map(\.message)
        #expect(!messages.contains("chatter"))
        #expect(messages.contains("milestone"))
        #expect(messages.contains("problem"))
    }

    @Test("turning verbose on starts keeping trace lines")
    func verboseCanBeTurnedOn() {
        let (log, dir) = makeLog(verbose: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        log.record(severity: .trace, category: .reader, message: "before")
        log.isVerboseEnabled = true
        log.record(severity: .trace, category: .reader, message: "after")

        let messages = log.snapshot().map(\.message)
        #expect(!messages.contains("before"))
        #expect(messages.contains("after"))
    }

    // MARK: - Reportable counting

    @Test("anomalies and faults are counted, quieter levels are not")
    func reportableCounting() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        log.record(severity: .error, category: .reader, message: "e")
        log.record(severity: .anomaly, category: .reader, message: "a")
        log.record(severity: .fault, category: .crash, message: "f")

        #expect(log.reportableCountThisSession == 2)
    }

    // MARK: - Bounds

    @Test("the file rotates and the log stays bounded")
    func rotationKeepsTheLogBounded() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Each entry carries ~1 KB of detail, so this pushes well past the 2 MB
        // rotation threshold and into the second generation.
        let padding = String(repeating: "x", count: 1024)
        for index in 0..<3000 {
            log.record(severity: .info, category: .reader, message: "entry \(index)", detail: padding)
        }
        log.flush(wait: true)

        let bytes = log.diskUsageBytes()
        #expect(bytes > 0)
        // Two generations of 2 MB each, plus the batch that tipped the last rotation.
        #expect(bytes < 6 * 1024 * 1024)

        // The most recent entries are the ones that survived.
        let entries = log.snapshot()
        #expect(entries.first?.message == "entry 2999")
    }

    @Test("snapshot is capped so a huge file cannot stall the screen")
    func snapshotIsCapped() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<7000 {
            log.record(severity: .info, category: .reader, message: "entry \(index)")
        }
        #expect(log.snapshot().count <= 6000)
    }

    @Test("clear empties the log")
    func clearEmptiesTheLog() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        log.record(severity: .info, category: .reader, message: "x")
        log.flush(wait: true)
        log.clear()

        #expect(log.snapshot().isEmpty)
        #expect(log.reportableCountThisSession == 0)
    }

    // MARK: - Sessions

    /// A session only counts as clean once the app reaches the background. Marking on
    /// `willTerminate` instead would label almost every ordinary launch a crash,
    /// because iOS rarely calls it.
    @Test("a session is unclean until it reaches the background")
    func sessionCleanlinessFollowsBackgrounding() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        log.beginSession()
        #expect(log.currentSession.endedCleanly == false)

        log.noteEnteredBackground()
        #expect(log.currentSession.endedCleanly == true)

        log.noteBecameActive()
        #expect(log.currentSession.endedCleanly == false)
    }

    @Test("the current session is never listed as a previous unclean one")
    func currentSessionIsExcluded() {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        log.beginSession()
        log.flush(wait: true)
        #expect(log.uncleanPreviousSessions().isEmpty)
    }
}

@Suite("AppLogger severity classification")
struct DiagnosticSeverityClassifierTests {

    @Test("timing and *Trace / *Debug tags are narration, not errors")
    func traceFamiliesAreDetected() {
        #expect(AppLogger.resolvedSeverity(message: "⏱ toc.parse 12ms", default: .notice) == .trace)
        #expect(AppLogger.resolvedSeverity(message: "[FlipTrace] pageForward", default: .notice) == .trace)
        #expect(AppLogger.resolvedSeverity(message: "[ProgressTrace][ScrollVC] commit", default: .notice) == .trace)
        // Matching on the suffix keeps the next one somebody adds classified without a
        // code change — these three were all missed by an explicit list.
        #expect(AppLogger.resolvedSeverity(message: "[StartupTrace][Engine] byteScan", default: .notice) == .trace)
        #expect(AppLogger.resolvedSeverity(message: "[CurlTrace] didFinish", default: .notice) == .trace)
        #expect(AppLogger.resolvedSeverity(message: "[StateDebug] applyRefreshAction", default: .notice) == .trace)
    }

    /// The one signal here that is not a naming convention: the caller handed us an
    /// `Error`, which is them saying something failed.
    @Test("an attached Error outranks the subsystem default")
    func attachedErrorEscalates() {
        #expect(AppLogger.resolvedSeverity(message: "could not fetch", default: .notice, carriesError: true) == .error)
        #expect(AppLogger.resolvedSeverity(message: "keychain unreadable", default: .fault, carriesError: true) == .fault)
    }

    /// A subsystem line with nothing attached is not an error just because it went
    /// through `AppLogger.render`. Before this, ~300 call sites read as errors and the
    /// severity filter meant nothing.
    @Test("a bare subsystem line is not an error")
    func bareSubsystemLineIsNotAnError() {
        #expect(AppLogger.resolvedSeverity(message: "[CoreTextEngine] laid out 12 pages", default: .notice) == .notice)
        #expect(AppLogger.resolvedSeverity(message: "scrollEngine created", default: .notice) == .notice)
    }

    @Test("structured probes are notices")
    func probeMarkerIsNotice() {
        #expect(AppLogger.resolvedSeverity(message: "⟐ scrollEngine created #2", default: .notice) == .notice)
        // A probe marker never downgrades something already more severe.
        #expect(AppLogger.resolvedSeverity(message: "⟐ something bad", default: .error) == .error)
    }

    @Test("functions that name a severity keep it")
    func severityNamingFunctionsKeepTheirLevel() {
        #expect(AppLogger.resolvedSeverity(message: "book opened", default: .info) == .info)
        #expect(AppLogger.resolvedSeverity(message: "generic failure", default: .error) == .error)
        #expect(AppLogger.resolvedSeverity(message: "tampering detected", default: .fault) == .fault)
    }

    @Test("leading whitespace does not hide a marker")
    func leadingWhitespaceIsTolerated() {
        #expect(AppLogger.resolvedSeverity(message: "  [FlipTrace] x", default: .notice) == .trace)
    }

    @Test("TTS lines are filed under their own category wherever they are logged from")
    func ttsPrefixOverridesCategory() {
        #expect(AppLogger.resolvedCategory(message: "[TTS][Provider] rejected", declared: .reader) == .tts)
        #expect(AppLogger.resolvedCategory(message: "⟐ something else", declared: .reader) == .reader)
    }
}

@Suite("DiagnosticRedactor")
struct DiagnosticRedactorTests {

    /// The load-bearing rule. `SourceAPIErrorLog` documents why: these book-source
    /// APIs carry the user's token in the query string.
    @Test("URL query strings are stripped")
    func queryStringsAreStripped() {
        let redacted = DiagnosticRedactor.redact("GET https://api.example.com/book?token=abc123&uid=9")
        #expect(!redacted.contains("abc123"))
        #expect(redacted.contains("https://api.example.com/book"))
    }

    @Test("credential-shaped key/value pairs are masked")
    func credentialPairsAreMasked() {
        let cases = [
            "Cookie: session=deadbeef",
            "authorization=Basic Zm9vOmJhcg==",
            "\"access_token\": \"ya29.longvalue\"",
            "password=hunter2",
            "api_key = k-9f8e7d",
        ]
        for line in cases {
            let redacted = DiagnosticRedactor.redact(line)
            #expect(redacted.contains("<redacted>"), "not redacted: \(line) -> \(redacted)")
        }
    }

    @Test("quoted JSON cookie values are masked in exported source context")
    func quotedJSONCookiesAreMasked() {
        let raw = #"context={"source":{"cookie":"session=deadbeef; user=42","name":"Example"}}"#

        let redacted = DiagnosticRedactor.redact(raw)

        #expect(!redacted.contains("deadbeef"))
        #expect(!redacted.contains("user=42"))
        #expect(redacted.contains(#""cookie":"<redacted>""#))
        #expect(redacted.contains(#""name":"Example""#))
    }

    @Test("bearer tokens are masked")
    func bearerTokensAreMasked() {
        let redacted = DiagnosticRedactor.redact("Authorization header sent as Bearer eyJhbGciOi.J9")
        #expect(!redacted.contains("eyJhbGciOi.J9"))
    }

    /// Redaction must not eat the content of the report. A hostname and a chapter
    /// index are usually the whole point of the log line.
    @Test("ordinary diagnostic text is left alone")
    func ordinaryTextSurvives() {
        let line = "[FlipTrace] pageForward from=(ch3,off100) to=(ch3,off200) host=www.example.com"
        #expect(DiagnosticRedactor.redact(line) == line)
    }
}
