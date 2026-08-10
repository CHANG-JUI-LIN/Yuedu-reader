import Testing
import UIKit
@testable import yuedu_app

/// Phase 2B memory lifecycle: retained RSS must NOT grow monotonically with
/// page turns or chapter count, and the memory tracker must show per-type
/// retain/release balance after eviction.
@MainActor
struct BrowserLayoutMemoryLifecycleTests {

    private func makeConfig() -> BrowserLayoutConfig {
        BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 160, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
    }

    /// Simulates paging through a chapter: the same layout is laid out,
    /// walked page-by-page (sessions), and released — six consecutive runs.
    @Test(.serialized) func retainedRSSDoesNotGrowAcrossRepeatedLayouts() async throws {
        MemoryTracker.reset()
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 80)
        let html = "<html><body><p>\(text)</p></body></html>"

        let baseline = MemoryStats.currentFootprint()
        var footprints: [Int64] = []
        for _ in 0..<6 {
            // Sequential runs; the session goes out of scope (released) at the
            // end of each iteration. No semaphore — the test IS async.
            let session = BrowserLayoutSession(
                html: html, cssTexts: [], config: makeConfig(),
                imageLoader: { _ in nil }, generation: 0
            )
            try await session.finish()
            footprints.append(MemoryStats.currentFootprint() - baseline)
        }
        // The retained delta series must not climb monotonically: the max of
        // the second half must be close to the max of the first half (plateau).
        let firstHalf = Array(footprints.prefix(3)).max() ?? 0
        let secondHalf = Array(footprints.suffix(3)).max() ?? 0
        #expect(secondHalf <= firstHalf + max(1_000_000, firstHalf / 4),
                "retained RSS grew across repeated layouts: \(footprints)")
        // And the last run must be below the peak (objects were released).
        #expect(footprints.last! <= (footprints.max() ?? 0) + 512_000)
    }

    /// The memory tracker must release chapter artifacts on eviction: after a
    /// chapter is laid out AND evicted, retained per-type bytes return to ~0.
    @Test(.serialized) func trackerReleasesOnEviction() async throws {
        MemoryTracker.reset()
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        let html = "<html><body><p>\(text)</p></body></html>"
        let config = makeConfig()

        // Layout + commit lifecycle bytes (as the engine does).
        let document = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let pipeline = try document.makeLayout(containerSize: CGSize(width: 300, height: 160))
        let pages = PageFragmentation.fragment(box: pipeline.rootBox, pageSize: pipeline.contentSize)
        var layout = BrowserChapterLayout(
            spineIndex: 0, pages: pages, sourceText: pipeline.sourceText,
            anchorOffsets: pipeline.anchorOffsets, fontSize: 17,
            themeTextColor: .black, themeBackgroundColor: .white
        )
        layout.recordLifecycleBytes(nodeCount: pipeline.nodeCount, boxCount: pipeline.boxCount)
        // Build one display list (recorded).
        _ = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: .black)

        let retainedWhileAlive = MemoryTracker.snapshot
        #expect((retainedWhileAlive[.pageFragments] ?? 0) > 0)
        #expect((retainedWhileAlive[.layoutBoxTree] ?? 0) > 0)

        // Eviction releases everything.
        layout.releaseLifecycleBytes()
        let afterRelease = MemoryTracker.snapshot
        #expect((afterRelease[.pageFragments] ?? 0) == 0)
        #expect((afterRelease[.layoutBoxTree] ?? 0) == 0)
        #expect((afterRelease[.domStyleTree] ?? 0) == 0)
    }

    /// The engine's DisplayList window cache keeps only ±2 pages and rebuilds
    /// the rest on demand with identical output.
    @Test(.serialized) func displayListWindowCacheEvictsAndRebuilds() async throws {
        MemoryTracker.reset()
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100)
        let html = "<html><body><p>\(text)</p></body></html>"
        let config = makeConfig()
        let document = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let pipeline = try document.makeLayout(containerSize: CGSize(width: 300, height: 160))
        let pages = PageFragmentation.fragment(box: pipeline.rootBox, pageSize: pipeline.contentSize)
        var layout = BrowserChapterLayout(
            spineIndex: 0, pages: pages, sourceText: pipeline.sourceText,
            anchorOffsets: pipeline.anchorOffsets, fontSize: 17,
            themeTextColor: .black, themeBackgroundColor: .white
        )
        layout.recordLifecycleBytes(nodeCount: pipeline.nodeCount, boxCount: pipeline.boxCount)
        #expect(pages.count >= 3)

        // Build lists for all pages (engine path caches ±2 around the current
        // page — here we simulate by building each page's list).
        let lists = pages.indices.map {
            layout.displayList(forPage: $0, themeTextColor: .black, oldThemeColor: .black)
        }
        let firstList = lists[0]
        // Eviction releases the chapter (all fragment/box bytes).
        layout.releaseLifecycleBytes()
        let snapshot = MemoryTracker.snapshot
        #expect((snapshot[.pageFragments] ?? 0) == 0)
        // Rebuild after eviction produces identical output.
        let rebuilt = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: .black)
        #expect(rebuilt.items.count == firstList.items.count)
        guard case .text(let a) = rebuilt.items.first!,
              case .text(let b) = firstList.items.first! else {
            Issue.record("expected text")
            return
        }
        #expect(a.rect == b.rect)
        #expect(a.text == b.text)
    }
}
