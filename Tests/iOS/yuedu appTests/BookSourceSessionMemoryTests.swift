import Foundation
import SwiftSoup
import Testing
@testable import yuedu_app

/// Crashlytics 6dda6179 (3.0.0 build 143): a user with 8,735 sources ran the source check and
/// the process died at 3.7 GB, two and a half minutes in, after about a hundred sources had
/// reached their table of contents. The check takes every source through
/// `BookSourceSession.session(for:)`, whose cache keeps 32 and evicts the rest — so the
/// sessions it evicts, and the JS runtime each one stood up, have to go with them.
@Suite("Book source session memory", .serialized)
struct BookSourceSessionMemoryTests {
    /// A source whose session stands up its JS runtime the first time a script runs.
    static func jsSource(_ index: Int) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://session-memory.test/\(index)#\(UUID().uuidString)",
            bookSourceName: "Session memory \(index)"
        )
        source.jsLib = "function tag(x) { return 'm' + x; }"
        return source
    }

    @Test("a session nobody holds is freed once its script has run")
    func droppedSessionIsFreed() async throws {
        weak var weakSession: BookSourceSession?
        do {
            let session = BookSourceSession(source: Self.jsSource(0))
            let value = try await session.parse { $0.evaluateSourceScript("tag(1 + 1)") }
            #expect(value == "m2", "the script ran in the session's runtime")
            weakSession = session
        }
        #expect(weakSession == nil, "a session that ran a script outlived its last reference")
    }

    /// A source whose table of contents is plain CSS rules.
    static func tocSource(_ index: Int) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://session-memory.test/toc-\(index)#\(UUID().uuidString)",
            bookSourceName: "Session memory toc \(index)"
        )
        source.ruleToc.chapterList = "ul#list li"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        return source
    }

    /// A one-page catalog of `chapters` chapters, as a big web-novel site serves it.
    static func tocPage(chapters: Int) -> String {
        let rows = (0..<chapters).map {
            "<li class=\"c\"><a href=\"/b/1/\($0).html\" title=\"第\($0)章\">第\($0)章 標題文字標題文字</a></li>"
        }.joined()
        return "<html><head><title>目錄</title></head><body><div id=\"main\"><ul id=\"list\">\(rows)</ul></div></body></html>"
    }

    /// The source check parses a table of contents for every source it reaches, 32 sources at
    /// a time, each on its own host queue — and the GCD threads those queues run on outlive the
    /// parse. Whatever a parse leaves on its thread stays until that thread parses again.
    ///
    /// Counted as live heap: the footprint also keeps the pages malloc has freed and not given
    /// back, which here is most of what 48 concurrent parses ever touched.
    @Test("pages the hosts parsed are not kept once their parse is over")
    func parsedPagesAreNotKept() async throws {
        let page = Self.tocPage(chapters: 8_000)
        let warm = Self.tocSource(-1)
        let warmChapters = try await BookSourceSession(source: warm).parse {
            try $0.parseTOCPage(html: page, baseURL: "https://session-memory.test/b/1/", source: warm).chapters.count
        }
        try #require(warmChapters == 8_000, "the TOC rules read the page")

        let before = Self.heapInUseMB()
        let sources = 48
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<sources {
                let source = Self.tocSource(index)
                group.addTask {
                    try await BookSourceSession(source: source).parse {
                        try $0.parseTOCPage(html: page, baseURL: "https://session-memory.test/b/1/", source: source)
                            .chapters.count
                    }
                }
            }
            for try await count in group { #expect(count == 8_000) }
        }
        let after = Self.heapInUseMB()
        let retainedMB = after - before
        print(String(
            format: "SESSION_MEMORY parsedPages sources=%d pageKB=%d heapBefore=%.1fMB heapAfter=%.1fMB retained=%.1fMB",
            sources, page.utf8.count / 1024, before, after, retainedMB
        ))
        #expect(retainedMB < 40, "the parses left \(Int(retainedMB)) MB behind them")
    }

    /// Live heap, in MB: what malloc still has handed out. The footprint also counts pages
    /// malloc has not given back, so it cannot tell a freed document from a kept one.
    nonisolated static func heapInUseMB() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576
    }

    /// The other half of 6dda6179. SwiftSoup gives every element a selector runs from a result
    /// cache and a window of query statistics, and allocated both in full up front: ~45 KB an
    /// element. A table of contents read row by row (`a@text`, `a@href` on every `li`) grew its
    /// page document by about 460 MB, and the source check reads 32 of those at once.
    @Test("selecting row by row costs less than the page")
    func rowSelectsCostLessThanThePage() async throws {
        let page = Self.tocPage(chapters: 8_000)
        let (documentMB, rowsMB): (Double, Double) = await withCheckedContinuation { continuation in
            Thread {
                let measured: (Double, Double) = autoreleasepool {
                    let start = Self.heapInUseMB()
                    guard let document = try? SwiftSoup.parse(page, "https://session-memory.test/b/1/"),
                          let rows = try? document.select("ul#list li")
                    else { return (-1, -1) }
                    let parsed = Self.heapInUseMB()
                    for row in rows.array() { _ = try? row.select("a").first()?.text() }
                    let selected = Self.heapInUseMB()
                    withExtendedLifetime(document) {}
                    return (parsed - start, selected - parsed)
                }
                continuation.resume(returning: measured)
            }.start()
        }
        print(String(format: "SESSION_MEMORY rowSelects document=%.1fMB rows=%.1fMB", documentMB, rowsMB))
        #expect(documentMB > 0, "the page parsed")
        #expect(rowsMB < documentMB, "8000 row selects added \(Int(rowsMB)) MB to a \(Int(documentMB)) MB page")
    }

    @Test("sessions the cache evicts give their memory back")
    func evictedSessionsReleaseFootprint() async throws {
        // Warm up the shared machinery (JavaScriptCore itself, the polyfills' first load) so
        // the measured rounds count only what each session keeps.
        for index in 0..<40 {
            _ = try await BookSourceSession.session(for: Self.jsSource(10_000 + index))
                .parse { $0.evaluateSourceScript("tag(\(index))") }
        }
        let before = MemoryFootprint.current()
        let count = 400
        for index in 0..<count {
            let session = BookSourceSession.session(for: Self.jsSource(index))
            let value = try await session.parse { $0.evaluateSourceScript("tag(\(index))") }
            #expect(value == "m\(index)")
        }
        let after = MemoryFootprint.current()
        let perSessionKB = Double(after - before) / Double(count) / 1024
        print(String(
            format: "SESSION_MEMORY sessions=%d before=%.1fMB after=%.1fMB perSession=%.1fKB",
            count, Double(before) / 1_048_576, Double(after) / 1_048_576, perSessionKB
        ))
        // 32 live sessions stay cached by design; the other 368 must not each keep a runtime.
        #expect(perSessionKB < 64, "every evicted session kept about \(Int(perSessionKB)) KB")
    }
}
