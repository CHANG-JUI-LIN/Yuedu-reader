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
        // The engine is the subject here: its own queue orders the two threads' calls.
        let sharedEngine = JSConfined(engine)
        DispatchQueue.global().async {
            started.wait()
            staleResult.value = sharedEngine.value.evaluate("source.put('stale', '1'); 'stale-ran'")
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

/// A script the timeout gave up on has to stop, not just stop being waited for. Crashlytics
/// 9c4b0a95 (3.0.1 build 150, background check of 1424 sources): MetricKit reported 90 s of CPU
/// in 93 s, 27 of 28 samples in a JavaScriptCore Yarr regex under `String.prototype.replace`
/// inside `evaluateRuleStep`. The reset moved the engine to a new queue and context and left
/// the script burning a core on the old one until the process died.
///
/// Each script here ends by itself at 50 s, so a failing run cannot bleed far into the next
/// test. A stopped script is quiet by 33 s: the timeout fires at 30 s, and the watchdog stops
/// the script within a tick plus the native call it is inside.
extension JSCoreEngineTimeoutResetTests {
    private func assertAbandonedScriptStops(_ name: String, script: (Double) -> String) {
        let engine = JSCoreEngine()
        let generationBefore = engine.generation
        let start = Date().timeIntervalSince1970 * 1000

        let result = engine.evaluateRuleStep(script(start), result: nil)
        let returnedAfter = Date().timeIntervalSince1970 * 1000 - start
        #expect(result == nil, "the rule step should have timed out")
        #expect(engine.generation == generationBefore + 1)
        // The reset used to wait for the abandoned script: building the new context wrote to
        // the old one, whose VM lock the script held.
        #expect(returnedAfter < 32_000, "the timeout returned after \(Int(returnedAfter)) ms")

        let quietFrom = start + 33_000
        let now = Date().timeIntervalSince1970 * 1000
        if now < quietFrom { Thread.sleep(forTimeInterval: (quietFrom - now) / 1000) }
        let busiest = RegexTimeoutCancellationTests.busiestThreadCPU()
        let window = RegexTimeoutCancellationTests.window
        print("⏱ \(name): timeout returned after \(Int(returnedAfter)) ms; busiest thread from 33 s: \(Int(busiest * 1000)) ms CPU of \(Int(window * 1000))")
        #expect(busiest < 0.7 * window, "the abandoned script kept a thread at \(busiest) s of CPU per \(window) s")

        // The engine still runs the next job.
        #expect(engine.evaluate("1 + 1") == "2")
    }

    @Test("a rule step looping over a backtracking regex stops when it times out", .timeLimit(.minutes(2)))
    func timedOutRegexLoopStops() {
        // Yarr gives up a single `(a+)+$` match at its own backtrack limit (about 0.5 s here),
        // so this shape is a rule calling such a replace again and again.
        assertAbandonedScriptStops("regex loop") { start in """
        var s = 'a'.repeat(40) + 'b';
        while (Date.now() < \(start) + 50000) { s = s.replace(/(a+)+$/g, 'x') || s; }
        s;
        """ }
    }

    @Test("a rule step inside one long replace stops when it times out", .timeLimit(.minutes(2)))
    func timedOutSingleReplaceStops() {
        // One `replace` call that runs about 45 s by itself: each of its matches is costly
        // but within Yarr's limit. The loop only keeps a fast machine busy until 50 s.
        assertAbandonedScriptStops("single replace") { start in """
        var s = ('a'.repeat(20) + '!c').repeat(330), n = 0;
        do { n += s.replace(/(a+)+b|c/g, 'x').length; } while (Date.now() < \(start) + 50000);
        n;
        """ }
    }
}
