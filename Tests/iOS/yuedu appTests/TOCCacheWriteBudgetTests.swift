import Foundation
import os
import Testing
@testable import yuedu_app

/// The launch's "check for new chapters" walks every online book. Each pass used to rewrite
/// the cached table of contents and its raw HTML whether or not anything changed — part of
/// the ≈1 GB of writes MetricKit reported within a minute of launch.
@Suite("TOC cache write budget", .serialized)
struct TOCCacheWriteBudgetTests {
    private func chapters(_ count: Int) -> [OnlineChapterRef] {
        (0..<count).map { OnlineChapterRef(index: $0, title: "第 \($0 + 1) 章", url: "https://example.com/c\($0)") }
    }

    private func fileNumber(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    @Test("an unchanged list parsed afresh is not rewritten, and no raw HTML is written")
    func unchangedListNotRewritten() throws {
        let fetcher = BookSourceFetcher()
        let source = BookSource(bookSourceUrl: "https://example.com/\(UUID().uuidString)", bookSourceName: "測試")
        let tocURL = "https://example.com/toc/\(UUID().uuidString)"
        defer { fetcher.clearTOCAndBookInfoCache(tocUrl: tocURL, bookURL: nil, source: source) }

        fetcher.saveTOCPackage(tocUrl: tocURL, source: source, runtimeVariables: ["k": "v"], chapters: chapters(30))
        let package = try #require(fetcher.loadTOCPackageSync(tocUrl: tocURL, source: source))
        let packageFile = fetcher.tocPackagePath(tocUrl: tocURL, source: source)
        let before = try fileNumber(packageFile)

        // Same content, new chapter ids — what every parse produces.
        fetcher.saveTOCPackage(tocUrl: tocURL, source: source, runtimeVariables: ["k": "v"], chapters: chapters(30))

        #expect(try fileNumber(packageFile) == before)
        #expect(!FileManager.default.fileExists(atPath: fetcher.tocRawHTMLPath(tocUrl: tocURL, source: source).path))
        #expect(fetcher.loadTOCPackageSync(tocUrl: tocURL, source: source)?.chapters.count == package.chapters.count)

        // A new chapter is a change: written.
        fetcher.saveTOCPackage(tocUrl: tocURL, source: source, runtimeVariables: ["k": "v"], chapters: chapters(31))
        #expect(try fileNumber(packageFile) != before)
        #expect(fetcher.loadTOCPackageSync(tocUrl: tocURL, source: source)?.chapters.count == 31)
    }

    @Test("the fingerprint ignores chapter ids and sees every other field")
    func fingerprintIgnoresIDs() {
        let a = chapters(5)
        let b = chapters(5)
        #expect(a.map(\.id) != b.map(\.id))
        #expect(BookSourceFetcher.tocFingerprint(chapters: a, runtimeVariables: nil)
            == BookSourceFetcher.tocFingerprint(chapters: b, runtimeVariables: nil))
        var cached = b
        cached[2].cachedFilename = "2.html"
        #expect(BookSourceFetcher.tocFingerprint(chapters: a, runtimeVariables: nil)
            != BookSourceFetcher.tocFingerprint(chapters: cached, runtimeVariables: nil))
        #expect(BookSourceFetcher.tocFingerprint(chapters: a, runtimeVariables: ["t": "1"])
            != BookSourceFetcher.tocFingerprint(chapters: a, runtimeVariables: ["t": "2"]))
    }

    @Test("the automatic refresh throttle survives a relaunch")
    func throttlePersists() throws {
        let suite = "AutoRefreshThrottleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_000_000)

        #expect(AutoRefreshThrottle(defaults: defaults, minimumInterval: 300).consume(now: start))
        // A new launch: a new throttle value over the same defaults.
        #expect(!AutoRefreshThrottle(defaults: defaults, minimumInterval: 300).consume(now: start.addingTimeInterval(120)))
        #expect(AutoRefreshThrottle(defaults: defaults, minimumInterval: 300).consume(now: start.addingTimeInterval(301)))
        // A clock moved back does not block refreshing.
        #expect(AutoRefreshThrottle(defaults: defaults, minimumInterval: 300).consume(now: start))
    }

    /// 3.0.0 (140): a 258-book pass outlived the 5 min throttle and every foreground started
    /// another beside it, five at once.
    @Test("a second check never runs beside the pass already running")
    @MainActor func onePassAtATime() async {
        let gate = ChapterRefreshPass()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        let firstEnded = OSAllocatedUnfairLock(initialState: false)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()

        let first = Task { @MainActor in
            await gate.run(waitForRunning: false) {
                runs.withLock { $0 += 1 }
                startedSignal.yield()
                for await _ in release { break }
                firstEnded.withLock { $0 = true }
            }
        }
        for await _ in started { break }

        // An automatic check while it runs: returns without a pass of its own.
        await gate.run(waitForRunning: false) { runs.withLock { $0 += 1 } }
        #expect(runs.withLock { $0 } == 1)

        // A pull-to-refresh while it runs: waits for that pass instead of starting one.
        let manual = Task { @MainActor in
            await gate.run(waitForRunning: true) { runs.withLock { $0 += 1 } }
            return firstEnded.withLock { $0 }
        }
        releaseSignal.yield()
        #expect(await manual.value)
        #expect(runs.withLock { $0 } == 1)
        await first.value

        // Once it has ended, the next check runs.
        await gate.run(waitForRunning: false) { runs.withLock { $0 += 1 } }
        #expect(runs.withLock { $0 } == 2)
    }
}
