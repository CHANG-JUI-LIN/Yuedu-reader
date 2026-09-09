import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Deterministic stage measurements. No live websites or persistent user content are modified.
@Suite("Reader architecture measurements", .serialized)
struct ReaderArchitectureBenchmarkTests {
    private func report(_ stage: String, fixture: String, iteration: Int, start: TimeInterval, count: Int) {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let row: [String: Any] = ["stage": stage, "fixture": fixture, "iteration": iteration,
                                  "ms": ms, "outputCount": count]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("READER_ARCH_BENCH " + String(decoding: data, as: UTF8.self))
    }

    @Test("Source session first-use and reuse latency on identical HTML")
    func sourceSessionLatency() throws {
        let pipeline = BookSourceParsingPipeline()
        for fixture in [CoreTextPerformanceFixtures.plain10K, CoreTextPerformanceFixtures.plain100K] {
            for (kind, rule) in [("css", "body@text"), ("js", "@js:result.replace(/<[^>]*>/g, '')")] {
                for iteration in 0..<5 {
                    var source = BookSource(bookSourceUrl: "https://benchmark-\(UUID().uuidString).invalid",
                                            bookSourceName: "Measurement fixture")
                    source.ruleContent.content = rule
                    let start = ProcessInfo.processInfo.systemUptime
                    let first = try SourcePerfTrace.span("benchmark.source.first", thresholdMs: 0) {
                        try pipeline.parseChapterResult(html: fixture.html,
                            baseURL: source.bookSourceUrl, source: source)
                    }
                    #expect(first.content.utf16.count >= fixture.minimumTextCharacters)
                    report("source.\(kind).first", fixture: fixture.id, iteration: iteration,
                           start: start, count: first.content.utf16.count)
                    let warmStart = ProcessInfo.processInfo.systemUptime
                    let warm = try SourcePerfTrace.span("benchmark.source.reuse", thresholdMs: 0) {
                        try pipeline.parseChapterResult(html: fixture.html,
                            baseURL: source.bookSourceUrl, source: source)
                    }
                    #expect(warm.content == first.content)
                    report("source.\(kind).reuse", fixture: fixture.id, iteration: iteration,
                           start: warmStart, count: warm.content.utf16.count)
                }
            }
        }
    }

    @Test("Document, first page, full pagination and scroll slicing latency")
    @MainActor
    func readerStageLatency() async throws {
        let size = CGSize(width: 390, height: 844)
        let settings = EPUBTestFixtures.renderSettings(fontSize: 18, lineHeightMultiple: 1.5, paragraphSpacing: 8)
        for fixture in [CoreTextPerformanceFixtures.plain10K, CoreTextPerformanceFixtures.plain100K] {
            for iteration in 0..<5 {
                let builder = OnlineProviderAttributedStringBuilder(
                    provider: BenchmarkChapterProvider(html: fixture.html), renderSize: size)
                let store = ChapterDocumentStore(builder: builder)
                let request = ChapterDocumentRequest(spineIndex: 0, settings: settings,
                    themeTextColor: settings.textColor, themeBackgroundColor: settings.backgroundColor)
                let buildStart = ProcessInfo.processInfo.systemUptime
                let document = try await SourcePerfTrace.spanAsync("benchmark.document.first", thresholdMs: 0) {
                    try await store.document(for: request)
                }
                #expect(document.attributedString.length >= fixture.minimumTextCharacters)
                report("document.first", fixture: fixture.id, iteration: iteration,
                       start: buildStart, count: document.attributedString.length)
                let warmStart = ProcessInfo.processInfo.systemUptime
                let cached = try await SourcePerfTrace.spanAsync("benchmark.document.reuse", thresholdMs: 0) {
                    try await store.document(for: request)
                }
                #expect(cached.revision == document.revision)
                report("document.reuse", fixture: fixture.id, iteration: iteration,
                       start: warmStart, count: cached.attributedString.length)
                let paginator = CoreTextPaginator()
                let firstStart = ProcessInfo.processInfo.systemUptime
                let first = await SourcePerfTrace.spanAsync("benchmark.page.first", thresholdMs: 0) {
                    await paginator.paginateFirstPage(spineIndex: 0, attrStr: document.attributedString,
                        imagePage: document.imagePage, pageBackgroundImage: document.pageBackgroundImage,
                        pageBackgroundColor: document.pageBackgroundColor, anchorOffsets: document.anchorOffsets,
                        renderSize: size, fontSize: settings.fontSize, lineSpacing: settings.lineSpacing,
                        paragraphSpacing: settings.paragraphSpacing, letterSpacing: settings.letterSpacing,
                        contentInsets: settings.contentInsets, writingMode: settings.writingMode, revision: document.revision)
                }
                #expect(first?.pageRanges.isEmpty == false)
                report("page.first", fixture: fixture.id, iteration: iteration,
                       start: firstStart, count: first?.pageRanges.count ?? 0)
                let fullStart = ProcessInfo.processInfo.systemUptime
                let full = await SourcePerfTrace.spanAsync("benchmark.page.full", thresholdMs: 0) {
                    await paginator.paginate(spineIndex: 0, attrStr: document.attributedString,
                        imagePage: document.imagePage, pageBackgroundImage: document.pageBackgroundImage,
                        pageBackgroundColor: document.pageBackgroundColor, anchorOffsets: document.anchorOffsets,
                        renderSize: size, fontSize: settings.fontSize, lineSpacing: settings.lineSpacing,
                        paragraphSpacing: settings.paragraphSpacing, letterSpacing: settings.letterSpacing,
                        contentInsets: settings.contentInsets, writingMode: settings.writingMode, revision: document.revision)
                }
                #expect(!full.pageRanges.isEmpty)
                let covered = full.pageRanges.reduce(0) { $0 + $1.length }
                #expect(covered == document.attributedString.length)
                report("page.full", fixture: fixture.id, iteration: iteration,
                       start: fullStart, count: full.pageRanges.count)
                let scroll = CoreTextScrollEngine(builder: builder, renderSettings: settings, chapterDocumentStore: store)
                let scrollStart = ProcessInfo.processInfo.systemUptime
                await SourcePerfTrace.spanAsync("benchmark.scroll.ready", thresholdMs: 0) {
                    await scroll.start(initialChapter: 0,
                        contentWidth: size.width - settings.contentInsets.left - settings.contentInsets.right,
                        viewportExtent: size.height, loadAdjacentChapters: false)
                }
                #expect(scroll.isReady)
                #expect(scroll.chunks.reduce(0) { $0 + $1.charRange.length } == document.attributedString.length)
                report("scroll.ready", fixture: fixture.id, iteration: iteration,
                       start: scrollStart, count: scroll.chunks.count)
            }
        }
    }
}

private struct BenchmarkChapterProvider: BookContentProvider {
    let html: String
    let totalChapters = 1
    func chapterTitle(at index: Int) -> String { "Measurement chapter" }
    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(index: index, title: chapterTitle(at: index), plainText: "",
                              body: .html(html), sourceHref: nil)
    }
}
