import Foundation
import Testing
@testable import yuedu_app

/// The monitor names what the main thread was doing when it stopped answering — the
/// question every field hang report so far left open.
@Suite("Main-thread monitor", .serialized)
struct MainThreadMonitorTests {
    @Test("a blocked main thread is recorded with the span it was inside")
    @MainActor
    func stallRecordedWithActivity() async throws {
        let stage = "test.stall.\(UUID().uuidString.prefix(8))"
        // The app delegate has already started it in the test host; starting again is a no-op.
        MainThreadMonitor.shared.start()

        SourcePerfTrace.span(stage, thresholdMs: 60_000) {
            Thread.sleep(forTimeInterval: 0.6)
        }

        // The record is written when the main thread answers the overdue question, which
        // needs the main queue to run: yield to it, checking for the line, up to 3 s.
        var found: DiagnosticEntry?
        for _ in 0..<30 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            // The monitor's own line; a stall this long is also echoed as a 🍞 breadcrumb.
            found = DiagnosticLog.shared.snapshot().first { $0.message.hasPrefix("⟐") && $0.message.contains(stage) }
        }
        let entry = try #require(found)
        #expect(entry.message.contains("main thread blocked"))
        #expect(entry.severity == .warning)
    }

    @Test("an activity outside any span is not reported as one")
    func activityStackIsBalanced() {
        let before = MainThreadActivity.snapshot()
        SourcePerfTrace.span("test.balanced", thresholdMs: 60_000) {}
        #expect(MainThreadActivity.snapshot() == before)
    }
}
