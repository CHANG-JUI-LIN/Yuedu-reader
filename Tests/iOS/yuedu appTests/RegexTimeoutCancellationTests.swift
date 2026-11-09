import Foundation
import Testing
@testable import yuedu_app

/// A regex that backtracks catastrophically has to stop at its deadline, not just stop being
/// waited for. Crashlytics 58c94021 (build 143, iPhone 13 mini, 996 sources, `refresh.all` in
/// the background): MetricKit reported 90 s of CPU in 93.6 s inside
/// `RegexReplacer.replaceRegex` → `icu::RegexMatcher::find` on a detached thread. The old
/// `RegexSanitizer.withTimeout` handed the caller its fallback after the timeout and left the
/// match running on that thread for as long as it took — one more saturated core per
/// timed-out call.
@Suite("Regex timeout cancels the match", .serialized)
struct RegexTimeoutCancellationTests {

    /// `(a+)+$` on a run of `a` that ends in `!` cannot match and backtracks 2^n ways.
    private static let pattern = "(a+)+$"
    private static let input = String(repeating: "a", count: 40) + "!"
    private static let timeout: TimeInterval = 0.2
    /// How long CPU use is watched after the call has returned.
    private static let window: TimeInterval = 1.0

    /// CPU time each live thread of the process has used, in seconds, keyed by thread id.
    private static func threadCPUSeconds() -> [UInt64: Double] {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return [:] }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        func seconds(_ time: time_value_t) -> Double { Double(time.seconds) + Double(time.microseconds) / 1_000_000 }
        var result: [UInt64: Double] = [:]
        for i in 0..<Int(count) {
            var ident = thread_identifier_info()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
            let identOK = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            }
            var basic = thread_basic_info()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let basicOK = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }
            guard identOK == KERN_SUCCESS, basicOK == KERN_SUCCESS else { continue }
            result[ident.thread_id] = seconds(basic.user_time) + seconds(basic.system_time)
        }
        return result
    }

    /// The most CPU any single thread used during `window` seconds of the test doing nothing.
    /// A match still backtracking keeps one thread at a full core (≈ `window`); the test host's
    /// own startup work is spread over several threads (busiest seen: 473 ms of 1000).
    private static func busiestThreadCPU() -> Double {
        let before = threadCPUSeconds()
        Thread.sleep(forTimeInterval: window)
        let after = threadCPUSeconds()
        return after.map { id, cpu in cpu - (before[id] ?? 0) }.max() ?? 0
    }

    /// `limit`: how long the call may take — its timeout plus slack.
    private func assertStops(_ name: String, limit: TimeInterval = 0.5, _ call: () -> Void) {
        let noise = Self.busiestThreadCPU()

        let t0 = ProcessInfo.processInfo.systemUptime
        call()
        let elapsed = ProcessInfo.processInfo.systemUptime - t0

        let after = Self.busiestThreadCPU()
        print("⏱ \(name): returned in \(Int(elapsed * 1000)) ms; busiest thread in the \(Int(Self.window * 1000)) ms after: \(Int(after * 1000)) ms CPU (idle control \(Int(noise * 1000)) ms)")

        #expect(elapsed < limit, "\(name) took \(elapsed) s, over its \(limit) s limit")
        #expect(after < 0.7 * Self.window, "\(name) left a thread at \(after) s of CPU per \(Self.window) s after it returned")
    }

    /// The measurement catches the shape that shipped: a detached thread whose caller stopped
    /// waiting at the timeout while the match kept going. The leftover match here ends by
    /// itself after 2.5 s so it cannot bleed into the other tests.
    @Test func detachedThreadShapeIsCaught() throws {
        let regex = try #require(RegexCache.shared.regex(for: Self.pattern))
        let input = Self.input
        let noise = Self.busiestThreadCPU()
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            let deadline = ProcessInfo.processInfo.systemUptime + 2.5
            regex.enumerateMatches(in: input, options: [.reportProgress],
                                   range: NSRange(location: 0, length: (input as NSString).length)) { _, _, stop in
                if ProcessInfo.processInfo.systemUptime >= deadline { stop.pointee = true }
            }
            done.signal()
        }
        worker.start()
        Thread.sleep(forTimeInterval: Self.timeout)   // the caller "times out" and leaves
        let after = Self.busiestThreadCPU()
        print("⏱ detached-thread shape: busiest thread in the \(Int(Self.window * 1000)) ms after: \(Int(after * 1000)) ms CPU (idle control \(Int(noise * 1000)) ms)")
        #expect(after >= 0.7 * Self.window)
        done.wait()
    }

    @Test func replaceAllStopsAtTheDeadline() {
        assertStops("replaceRegex") {
            let out = RegexReplacer.replaceRegex(
                result: Self.input, pattern: Self.pattern, replacement: "x",
                replaceFirst: false, timeout: Self.timeout
            )
            #expect(out == Self.input)
        }
    }

    @Test func replaceFirstStopsAtTheDeadline() {
        assertStops("replaceRegex ###") {
            let out = RegexReplacer.replaceRegex(
                result: Self.input, pattern: Self.pattern, replacement: "x",
                replaceFirst: true, timeout: Self.timeout
            )
            #expect(out == "")
        }
    }

    @Test func listExtractionStopsAtTheDeadline() throws {
        let matches = RegexMatching.matches(
            of: try #require(RegexCache.shared.regex(for: Self.pattern)),
            in: Self.input, firstOnly: false, timeout: Self.timeout
        )
        #expect(matches == nil)
        // `##` extraction runs under the extractor's fixed 2 s timeout.
        try assertStopsThrowing("extractList", limit: 2.3) {
            let out = try RegexExtractor().extractList(
                from: Self.input, rule: "##" + Self.pattern, baseURL: ""
            )
            #expect(out.isEmpty)
        }
    }

    private func assertStopsThrowing(_ name: String, limit: TimeInterval, _ call: () throws -> Void) throws {
        var thrown: Error?
        assertStops(name, limit: limit) {
            do { try call() } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    // MARK: - The rebuilt replacement matches NSRegularExpression's

    @Test func replaceAllMatchesFoundationTemplateSubstitution() throws {
        let text = "第1章 abc 第22章 de 第333章"
        let pattern = #"第(\d+)章"#
        let regex = try NSRegularExpression(pattern: pattern)
        let expected = regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[$1|$0]\\$"
        )
        let out = RegexReplacer.replaceRegex(
            result: text, pattern: pattern, replacement: "[$1|$0]\\$", replaceFirst: false
        )
        #expect(out == expected)
    }

    @Test func replaceAllHandlesEmptyMatchesAndSurrogates() throws {
        let text = "a😀b"
        let regex = try NSRegularExpression(pattern: "x*")
        let expected = regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "-"
        )
        let out = RegexReplacer.replaceRegex(result: text, pattern: "x*", replacement: "-", replaceFirst: false)
        #expect(out == expected)
    }

    @Test func cacheHelpersStillWork() {
        let cache = RegexCache()
        #expect(cache.replaceMatches(in: "a1b2c3", pattern: "\\d", replacement: "X") == "aXbXcX")
        #expect(cache.firstMatch(in: "abc123def", pattern: "\\d+")?.range == NSRange(location: 3, length: 3))
        #expect(cache.replaceMatches(in: Self.input, pattern: Self.pattern, replacement: "x", timeout: Self.timeout) == Self.input)
    }
}
