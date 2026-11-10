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
        // Re-enters the engine from inside a script, as ModernParserBridge wires it: on the
        // current queue that must run inline, or it would wait on its own queue until the timeout.
        engine.sourceBridge.evalJSHandler = { [weak engine] js in engine?.evaluate(js) ?? "" }
        #expect(engine.evaluate("source.evalJS('1 + 1')") == "2")
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
        'leak=' + source.get('leak') + ' eval=' + source.evalJS('1 + 1');
        """)
        #expect(next == "leak= eval=2")
    }
}

extension JSCoreEngineTimeoutResetTests {
    /// Box for a value one thread writes and the test reads after joining it.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    @Test("the abandoned generation reaches none of the new context's bridges, jobs queued behind it never run, and its errors stay its own")
    func abandonedGenerationIsIsolated() {
        let engine = JSCoreEngine()
        engine.setBookBridge(LegadoBookBridge(tocUrl: "toc-before", variables: ["v": "before"]))
        engine.setChapterBridge(LegadoChapterBridge(title: "chapter-before"))
        engine.sourceBridge.evalJSHandler = { [weak engine] js in engine?.evaluate(js) ?? "" }

        // The hanging script tells the test it has started through `source.login()`, so the
        // job that queues behind it is queued while it runs.
        let started = DispatchSemaphore(value: 0)
        engine.sourceBridge.loginHandler = { started.signal(); return "" }

        let bridgesBefore = [
            ObjectIdentifier(engine.bridge), ObjectIdentifier(engine.sourceBridge),
            ObjectIdentifier(engine.bookBridge), ObjectIdentifier(engine.chapterBridge),
        ]
        let generationBefore = engine.generation
        let start = Date().timeIntervalSince1970 * 1000

        // A job queued on the old queue behind the hanging script: refresh.all queues many.
        let staleResult = Box<String?>()
        let staleDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.wait()
            staleResult.value = engine.evaluate("source.put('stale', '1'); 'stale-ran'")
            staleDone.signal()
        }

        let abandoned = engine.evaluate("""
        source.login();
        while (Date.now() < \(start) + 36000) {
            if (Date.now() > \(start) + 31000) {
                book.tocUrl = 'late';
                book.setVariable('v', 'late');
                chapter.title = 'late';
            }
        }
        throw new Error('abandoned-late');
        """)
        #expect(abandoned == nil, "the first script should have timed out")
        staleDone.wait()
        #expect(staleResult.value == .some(nil), "a job queued behind the abandoned script must not run")
        #expect(engine.generation == generationBefore + 1, "only the job that dispatched to the hung queue resets")

        let bridgesAfter = [
            ObjectIdentifier(engine.bridge), ObjectIdentifier(engine.sourceBridge),
            ObjectIdentifier(engine.bookBridge), ObjectIdentifier(engine.chapterBridge),
        ]
        for (before, after) in zip(bridgesBefore, bridgesAfter) {
            #expect(before != after, "every bridge must be the new context's own")
        }

        // Runs until the abandoned script has thrown and the stale job would have run.
        let next = engine.evaluate("""
        while (Date.now() < \(start) + 38000) {}
        [book.tocUrl, book.getVariable('v'), chapter.title, source.get('stale'), source.evalJS('1 + 1')].join('|');
        """)
        #expect(next == "toc-before|before|chapter-before||2")
        #expect(engine.lastError == nil, "the abandoned script's exception is not the new job's error")
    }
}

/// The runaway-script timeout counts a script's own time, not its waits on the network.
///
/// It checked only whether a wait was in progress at each 30 s mark, so a script whose waits had
/// all ended by then had them counted against it: 番茄听书 (YCK 1330 #31) downloads a chapter's
/// audio and then decrypts it, and a slow download put the 30 s mark in the decrypt.
extension JSCoreEngineTimeoutResetTests {
    /// A transport whose every request takes `seconds` to answer, as a slow server's would.
    private static func slowTransport(_ seconds: TimeInterval) -> SourceScriptTransport {
        { request, _ in
            Thread.sleep(forTimeInterval: seconds)
            return .bodyOnly(request: request, body: "answered")
        }
    }

    @Test("a slow request followed by the script's own work is not cut at the 30 s mark", .timeLimit(.minutes(2)))
    func slowRequestThenWorkFinishes() {
        let engine = JSCoreEngine()
        engine.networkHandler = Self.slowTransport(20)
        let generationBefore = engine.generation

        let result = engine.evaluate("""
        var body = java.ajax('https://slow.example/audio');
        var t = Date.now();
        while (Date.now() - t < 12000) {}
        body + ' and decrypted';
        """)

        #expect(result == "answered and decrypted")
        #expect(engine.generation == generationBefore, "the engine must not have been reset")
    }

    @Test("a script's own work past 30 s is still cut after a request", .timeLimit(.minutes(2)))
    func ownWorkPastTheLimitIsCut() {
        let engine = JSCoreEngine()
        engine.networkHandler = Self.slowTransport(2)
        let generationBefore = engine.generation

        let result = engine.evaluate("""
        var body = java.ajax('https://slow.example/audio');
        var t = Date.now();
        while (Date.now() - t < 33000) {}
        body;
        """)

        #expect(result == nil, "the script should have timed out")
        #expect(engine.generation == generationBefore + 1)
    }
}
