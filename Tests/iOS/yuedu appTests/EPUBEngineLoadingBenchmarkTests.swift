import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Opt-in diagnostics on local, original EPUBs. Measures engine readiness, not
/// tap-to-display latency. Each observation owns a fresh publication and engines;
/// OS file/font caches remain warm. Route order alternates between repetitions.
@Suite(.serialized)
@MainActor
struct EPUBEngineLoadingBenchmarkTests {
    private struct Book {
        let id: String
        let filename: String
        let spine: Int
    }

    private struct Observation: Codable {
        let book: String
        let spine: Int
        let repetition: Int
        let route: String
        let sessionOpenMs: Double
        let openingFirstReadyMs: Double?
        let openingReturnMs: Double?
        let firstReadyMs: Double
        let requestReturnMs: Double
        let cachedRequestMs: Double
        let effectiveEngine: String
        let openingEngine: String?
        let legacyBuildCounts: [Int: Int]
        let legacyBuildMs: [Int: Double]
        let byteScanMs: Double?
        let resourceCalls: [String: Int]
        let resourceMs: [String: Double]
        let scannerProbeMs: Double?
        let chapterHTMLBytes: Int
        let chapterCount: Int
        let contentUnits: Int
    }

    private let size = CGSize(width: 390, height: 800)
    private var settings: ReaderRenderSettings { EPUBTestFixtures.renderSettings() }

    @Test func compareProductionLoadingRoutes() async throws {
        // Ordinary test runs do not require private, machine-local books.
        guard ProcessInfo.processInfo.environment["YUEDU_LOADING_BENCHMARK"] == "1" else { return }
        let books = [
            Book(id: "quanzhi-prose", filename: "《全职高手3》作者：蝴蝶蓝.epub", spine: 69),
            Book(id: "guimi-prose", filename: "《诡秘之主4》作者：爱潜水的乌贼.epub", spine: 80),
            Book(id: "hail-mary-prose", filename: "Project Hail Mary (Andy Weir) (z-library.sk, 1lib.sk, z-lib.sk).epub", spine: 6),
            Book(id: "game-designer-fallback", filename: "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub", spine: 10),
            Book(id: "guimi-long", filename: "《诡秘之主4》作者：爱潜水的乌贼.epub", spine: 64)
        ]
        var observations: [Observation] = []
        for repetition in 0..<6 {
            for book in books {
                let routes = repetition.isMultiple(of: 2)
                    ? ["legacy-paged", "auto-paged", "legacy-scroll", "auto-scroll"]
                    : ["auto-scroll", "legacy-scroll", "auto-paged", "legacy-paged"]
                for route in routes {
                    let value = try await observe(book, route: route, repetition: repetition)
                    observations.append(value)
                    let data = try JSONEncoder().encode(value)
                    print("LOADING-BENCH \(String(decoding: data, as: UTF8.self))")
                }
            }
        }
        #expect(observations.count == books.count * 4 * 6)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let filename = ProcessInfo.processInfo.environment["YUEDU_LOADING_BENCHMARK_OUTPUT"]
            ?? "loading-benchmark-2026-09-30.json"
        let output = root.appendingPathComponent("docs/browser-layout").appendingPathComponent(filename)
        try encoder.encode(observations).write(to: output, options: .atomic)
        print("LOADING-BENCH-OUTPUT \(output.path)")
    }

    private func observe(_ book: Book, route: String, repetition: Int) async throws -> Observation {
        let url = URL(fileURLWithPath: "/Users/zhangruilin/Desktop/Test document/EPUB Format")
            .appendingPathComponent(book.filename)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let openStart = SourcePerfTrace.now
        let session = try await PublicationSession.open(sourceURL: url)
        let openMs = elapsed(openStart)
        let builder = TimedBuilder(EPUBAttributedStringBuilder(session: session, renderSize: size))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: directory))
        legacy.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        let resource = TimedResource(EPUBBrowserLayoutResourceAdapter(session: session))
        let auto = route.hasPrefix("auto")
            ? BrowserLayoutPageEngine(resource: resource, delegate: legacy, settings: settings,
                mode: .browserAuto, showDebugOverlay: false) : nil
        var openingFirst: Double?
        var openingReturn: Double?
        var openingEngine: String?
        var firstReady: Double?
        var requestReturn: Double = 0
        var cached: Double = 0
        var effective: String = "legacy"
        var units = 0
        defer { auto?.cancelPendingWork(); legacy.cancelPendingWork() }

        if route.hasSuffix("paged") {
            let openingStart = SourcePerfTrace.now
            let openingCallback: (Int?) -> Void = { spine in
                guard spine == 0, openingFirst == nil else { return }
                if let auto, auto.choice(for: 0) == nil { return }
                openingFirst = elapsed(openingStart)
            }
            if let auto {
                auto.onChapterReady = openingCallback
                await auto.start(renderSize: size, bookId: UUID().uuidString)
                openingEngine = auto.choice(for: 0)?.debugLabel
            } else {
                legacy.onChapterReady = openingCallback
                await legacy.start(renderSize: size, bookId: UUID().uuidString)
                openingEngine = "legacy"
            }
            openingReturn = elapsed(openingStart)
            // Finish the opening chapter before isolating entry to the target.
            _ = await legacy.preloadChapter(at: 0)
            let targetStart = SourcePerfTrace.now
            let targetCallback: (Int?) -> Void = { spine in
                if spine == book.spine, firstReady == nil {
                    firstReady = elapsed(targetStart)
                    SourcePerfTrace.record("benchmark.\(route).firstReady", "book=\(book.id) spine=\(book.spine)",
                        since: targetStart, thresholdMs: 0)
                }
            }
            if let auto {
                auto.onChapterReady = targetCallback
                let result = await auto.preloadChapter(at: book.spine)
                #expect(result.isReady)
                effective = auto.choice(for: book.spine)?.debugLabel ?? "unknown"
                units = (auto.chapterText(forSpine: book.spine) as NSString?)?.length ?? 0
            } else {
                legacy.onChapterReady = targetCallback
                let result = await legacy.preloadChapter(at: book.spine)
                #expect(result.isReady)
                units = legacy.layouts[book.spine]?.sourceLength ?? 0
            }
            requestReturn = elapsed(targetStart)
            let cachedStart = SourcePerfTrace.now
            if let auto { _ = await auto.preloadChapter(at: book.spine) }
            else { _ = await legacy.preloadChapter(at: book.spine) }
            cached = elapsed(cachedStart)
            // Await the actual final resource read, so no whole-book byte scan
            // from this observation can compete with the following observation.
            await builder.waitForByteScan()
            auto?.onChapterReady = nil
            legacy.onChapterReady = nil
        } else {
            let scroll = CoreTextScrollEngine(builder: builder, renderSettings: settings)
            if let auto {
                auto.usesViewportScrolling = true
                await auto.start(renderSize: size, bookId: UUID().uuidString)
                scroll.browserAutoEngine = auto
            }
            let targetStart = SourcePerfTrace.now
            await scroll.start(initialChapter: book.spine, contentWidth: size.width - 24,
                viewportExtent: size.height - 24, loadAdjacentChapters: false)
            firstReady = elapsed(targetStart)
            SourcePerfTrace.record("benchmark.\(route).firstReady", "book=\(book.id) spine=\(book.spine)",
                since: targetStart, thresholdMs: 0)
            requestReturn = firstReady!
            #expect(scroll.isReady)
            #expect(!scroll.chunks.isEmpty)
            #expect(scroll.chunkIndex(forChapter: book.spine, charOffset: 0) != nil)
            if let auto { effective = auto.choice(for: book.spine)?.debugLabel ?? "unknown" }
            units = scroll.browserChapter(at: book.spine).map { ($0.document.sourceText as NSString).length }
                ?? scroll.chunks.count
            let cachedStart = SourcePerfTrace.now
            await scroll.start(initialChapter: book.spine, contentWidth: size.width - 24,
                viewportExtent: size.height - 24, loadAdjacentChapters: false)
            cached = elapsed(cachedStart)
            await scroll.waitForViewportIdle()
            scroll.trimViewportChapters(keeping: [])
        }
        #expect(firstReady != nil, "\(book.id) \(route) never published a ready chapter")
        #expect(units > 0)
        // An independent warm scanner probe, OUTSIDE all timed engine work.
        // This is a component diagnostic, not an additive decomposition.
        let html = try await session.chapterHTML(at: book.spine)
        var probe: Double?
        if auto != nil {
            let input = await resource.base.cssFrontendInput(forChapter: book.spine, html: html)
            let probeStart = SourcePerfTrace.now
            _ = await Task.detached(priority: .userInitiated) {
                BrowserLayoutCapabilityScanner.scan(input: input, writingMode: .horizontal)
            }.value
            probe = elapsed(probeStart)
        }
        return Observation(book: book.id, spine: book.spine, repetition: repetition, route: route,
            sessionOpenMs: openMs, openingFirstReadyMs: openingFirst, openingReturnMs: openingReturn,
            firstReadyMs: firstReady ?? requestReturn, requestReturnMs: requestReturn, cachedRequestMs: cached,
            effectiveEngine: effective, openingEngine: openingEngine, legacyBuildCounts: builder.counts,
            legacyBuildMs: builder.milliseconds, byteScanMs: builder.byteScanMs,
            resourceCalls: resource.counts, resourceMs: resource.milliseconds,
            scannerProbeMs: probe, chapterHTMLBytes: html.utf8.count, chapterCount: session.chapters.count,
            contentUnits: units)
    }

    private func elapsed(_ start: TimeInterval) -> Double { (SourcePerfTrace.now - start) * 1000 }
}

@MainActor
private final class TimedBuilder: @preconcurrency AttributedStringBuilding, RenderSizeAwareAttributedStringBuilding {
    let base: EPUBAttributedStringBuilder
    var counts: [Int: Int] = [:]
    var milliseconds: [Int: Double] = [:]
    private var byteScanFinished = false
    private var byteScanWaiter: CheckedContinuation<Void, Never>?
    private var byteScanStart: TimeInterval?
    private(set) var byteScanMs: Double?
    init(_ base: EPUBAttributedStringBuilder) { self.base = base }
    var chapterCount: Int { base.chapterCount }
    var prefersLazyByteScan: Bool { base.prefersLazyByteScan }
    func updateRenderSize(_ size: CGSize) { base.updateRenderSize(size) }
    func chapterTitle(at index: Int) -> String { base.chapterTitle(at: index) }
    func chapterSourceHref(at index: Int) -> String? { base.chapterSourceHref(at: index) }
    func chapterDataSize(at index: Int) async -> Int {
        if index == 0 { byteScanStart = SourcePerfTrace.now }
        let size = await base.chapterDataSize(at: index)
        if index == chapterCount - 1 {
            byteScanMs = byteScanStart.map { (SourcePerfTrace.now - $0) * 1000 }
            byteScanFinished = true
            byteScanWaiter?.resume()
            byteScanWaiter = nil
        }
        return size
    }
    func waitForByteScan() async {
        if !byteScanFinished { await withCheckedContinuation { byteScanWaiter = $0 } }
    }
    func chapterIndex(for href: String) -> Int? { base.chapterIndex(for: href) }
    func cssResourceHrefs() -> [String] { base.cssResourceHrefs() }
    func chapterPlainText(at index: Int) async -> String? { await base.chapterPlainText(at: index) }
    func localChapterText(at index: Int) async -> AILocalChapterText { await base.localChapterText(at: index) }
    func buildChapter(at index: Int, settings: ReaderRenderSettings,
        themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        let start = SourcePerfTrace.now
        counts[index, default: 0] += 1
        defer { milliseconds[index, default: 0] += (SourcePerfTrace.now - start) * 1000 }
        return try await base.buildChapter(at: index, settings: settings,
            themeTextColor: themeTextColor, themeBackgroundColor: themeBackgroundColor)
    }
}

@MainActor
private final class TimedResource: BrowserLayoutResourceProviding {
    let base: EPUBBrowserLayoutResourceAdapter
    var counts: [String: Int] = [:]
    var milliseconds: [String: Double] = [:]
    init(_ base: EPUBBrowserLayoutResourceAdapter) { self.base = base }
    var chapterCount: Int { base.chapterCount }
    func chapterTitle(at index: Int) -> String { base.chapterTitle(at: index) }
    func chapterSourceHref(at index: Int) -> String? { base.chapterSourceHref(at: index) }
    func fontResolver() -> BrowserFontResolver? { base.fontResolver() }
    func prepareFonts(requests: Set<BrowserFontRequest>) async {
        let start = SourcePerfTrace.now
        defer { record("fonts", since: start) }
        await base.prepareFonts(requests: requests)
    }
    func resolveMediaAttachment(forChapter index: Int, media: EPUBMediaAttachment) -> EPUBMediaAttachment {
        base.resolveMediaAttachment(forChapter: index, media: media)
    }
    private func record(_ key: String, since start: TimeInterval) {
        counts[key, default: 0] += 1
        milliseconds[key, default: 0] += (SourcePerfTrace.now - start) * 1000
    }
    func chapterHTML(at index: Int) async throws -> String {
        let start = SourcePerfTrace.now
        defer { record("html.\(index)", since: start) }
        return try await base.chapterHTML(at: index)
    }
    func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
        let start = SourcePerfTrace.now
        defer { record("css.\(index)", since: start) }
        return await base.cssFrontendInput(forChapter: index, html: html)
    }
    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] {
        let start = SourcePerfTrace.now
        defer { record("images.\(index)", since: start) }
        return await base.prefetchImages(forChapter: index, html: html, renderWidth: renderWidth)
    }
    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? {
        let start = SourcePerfTrace.now
        defer { record("image.\(index)", since: start) }
        return await base.loadImage(forChapter: index, source: source, renderWidth: renderWidth)
    }
}
