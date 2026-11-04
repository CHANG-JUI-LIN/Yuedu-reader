import Foundation
import Testing
@testable import yuedu_app

/// A JS timeout resets the engine onto a new queue and context, and abandons the old ones with
/// the script still running on them. That script must not share mutable state with the jobs the
/// new queue runs: Crashlytics 61eb93e6… / MetricKit 19a2093d… (3.0.1 build 144, background
/// `refresh.all books=273`) died in `objc_release` inside `LegadoSourceBridge.put` — the old
/// script and a new job writing `source.put` on the same bridge from two threads at once.
@Suite("JSCoreEngine timeout reset", .serialized)
struct JSCoreEngineTimeoutResetTests {
    @Test("a script abandoned by the timeout writes source.put to its own bridge, not the next job's")
    func abandonedScriptDoesNotShareSourceBridge() {
        let engine = JSCoreEngine()
        let bridgeBefore = ObjectIdentifier(engine.sourceBridge)
        let generationBefore = engine.generation
        let start = Date().timeIntervalSince1970 * 1000

        // Runs past the 30 s timeout, then keeps writing for a few seconds on the abandoned queue
        // while the next job writes the same keys on the new one. No handlers are wired, so `put`
        // lands in the bridge's own key-value store — the store the crash was in.
        let abandoned = engine.evaluate("""
        var i = 0;
        while (Date.now() < \(start) + 36000) {
            source.put('k' + (i % 256), 'old-' + i + '-' + 'x'.repeat(i % 64));
            if (Date.now() > \(start) + 31000) source.put('leak', '1');
            i++;
        }
        'finished';
        """)
        #expect(abandoned == nil, "the first script should have timed out")
        #expect(engine.generation == generationBefore + 1, "the timeout should have reset the engine")
        #expect(ObjectIdentifier(engine.sourceBridge) != bridgeBefore,
                "the new context must get its own source bridge")

        // The next job: writes the same keys until the abandoned script has stopped, then reads
        // back what only the abandoned script wrote.
        let next = engine.evaluate("""
        var j = 0;
        while (Date.now() < \(start) + 38000) {
            source.put('k' + (j % 256), 'new-' + j + '-' + 'y'.repeat(j % 64));
            j++;
        }
        'leak=' + source.get('leak');
        """)
        #expect(next == "leak=")
    }
}
