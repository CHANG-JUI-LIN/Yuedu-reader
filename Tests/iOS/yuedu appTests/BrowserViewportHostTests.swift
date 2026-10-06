@testable import YueduCoreText
import Combine
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserViewportHostTests {
    @Test func smallScrollUpdatesPreserveVisibleGlyphScreenPositions() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let html = "<body>" + (0..<160).map {
            "<p id='p\($0)' style='margin:24px 0'>Paragraph \($0) "
                + String(repeating: "中文 continuous geometry sample ", count: 3 + $0 % 9) + "</p>"
        }.joined() + "</body>"
        let chapters = [MockBrowserLayoutResource.Chapter(title: "Geometry", href: "0.xhtml", html: html, css: [])]
        let builder = MockAttributedStringBuilder(texts: [html])
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let browser = BrowserLayoutPageEngine(resource: MockBrowserLayoutResource(chapters: chapters),
            delegate: delegate, settings: settings, mode: .browserAuto)
        browser.usesViewportScrolling = true
        let size = scene.coordinateSpace.bounds.size
        await browser.start(renderSize: size, bookId: "small-scroll-geometry")
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        await engine.start(initialChapter: 0, contentWidth: size.width - 24,
                           viewportExtent: size.height, loadAdjacentChapters: false)
        let chapter = try #require(engine.browserChapter(at: 0))
        let owner = try #require(chapter.layoutOwner)
        let target = try #require(chapter.facts?.anchorOffsets["p80"])
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            horizontalInset: 12, verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: 0, charOffset: target)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        controller.update(axis: .vertical, horizontal: 12, vertical: 20)
        collection.layoutIfNeeded()
        // The restore target is laid out on its chapter's thread; start from it.
        await engine.waitForViewportIdle()
        collection.layoutIfNeeded()

        // Measure the actual retained fragment canvas in window coordinates.
        // Looking up documentY again after correction would hide a screen jump.
        func visibleGlyphs() -> [String: CGFloat] {
            var result: [String: CGFloat] = [:]
            for surface in controller.fragmentHost.visibleSurfaces {
                guard let fragment = surface.fragment, fragment.textPaintPhase == .glyphs,
                      let canvas = surface.subviews.first else { continue }
                for case .text(let text) in fragment.displayList.items {
                    let p = canvas.convert(CGPoint(x: text.rect.rawValue.midX, y: text.baselineY), to: window)
                    let viewport = collection.convert(collection.bounds, to: window).insetBy(dx: 0, dy: 60)
                    if viewport.contains(p) {
                        result["\(text.nodeID):\(text.sourceRange):\(text.text)"] = p.y
                    }
                }
            }
            return result
        }
        var worst: CGFloat = 0
        var observations = 0
        let initialRevision = chapter.layoutRevision
        let start = SourcePerfTrace.now
        for direction: CGFloat in [-1, 1, -1, 1] {
            for step in 0..<500 {
                let before = visibleGlyphs()
                #expect(!before.isEmpty, "the external paint host must contain visible text")
                let oldOffset = collection.contentOffset.y
                let delta = direction * 3
                collection.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y + delta), animated: false)
                controller.scrollViewDidScroll(collection)
                if step % 7 == 0 { controller.update(axis: .vertical, horizontal: 12, vertical: 20) }
                // A requested layout commits asynchronously; each commit must keep
                // the visible glyphs where they were.
                await engine.waitForViewportIdle()
                collection.layoutIfNeeded()
                let after = visibleGlyphs()
                for (key, y) in before {
                    guard let actual = after[key] else { continue }
                    let error = abs(actual - (y - delta))
                    worst = max(worst, error); observations += 1
                    if error > 1 / window.screen.scale + 0.001 {
                        Issue.record("visible glyph jumped \(error)pt at step \(step), direction \(direction), revision \(chapter.layoutRevision), source=\(key) screenBefore=\(y) screenAfter=\(actual) offsetBefore=\(oldOffset) offsetAfter=\(collection.contentOffset.y)")
                        return
                    }
                }
            }
        }
        print("[ViewportScreenStability] observations=\(observations) maxError=\(worst)")
        SourcePerfTrace.record("test.viewport.screenStability", "observations=\(observations) maxError=\(worst)", since: start, thresholdMs: 0)
        #expect(observations > 1000)
        #expect(chapter.layoutRevision > initialRevision, "small steps must cross a viewport update boundary")
        #expect(await owner.diagnostics().mainThreadTransactionCount == 0, "a scroll callback never lays out")
    }

    @Test func prefetchedTileUsesCurrentSnapshotBeforeBecomingVisible() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let html = "<body>" + (0..<160).map {
            "<p id='p\($0)' style='margin:24px 0'>Paragraph \($0) "
                + String(repeating: "中文 continuous geometry sample ", count: 3 + $0 % 9) + "</p>"
        }.joined() + "</body>"
        let chapters = [MockBrowserLayoutResource.Chapter(title: "Geometry", href: "0.xhtml", html: html, css: [])]
        let builder = MockAttributedStringBuilder(texts: [html])
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let browser = BrowserLayoutPageEngine(resource: MockBrowserLayoutResource(chapters: chapters),
            delegate: delegate, settings: settings, mode: .browserAuto)
        browser.usesViewportScrolling = true
        let size = scene.coordinateSpace.bounds.size
        await browser.start(renderSize: size, bookId: "small-scroll-geometry")
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        await engine.start(initialChapter: 0, contentWidth: size.width - 24,
                           viewportExtent: size.height, loadAdjacentChapters: false)
        let chapter = try #require(engine.browserChapter(at: 0))
        let owner = try #require(chapter.layoutOwner)
        let target = try #require(chapter.facts?.anchorOffsets["p80"])
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            horizontalInset: 12, verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: 0, charOffset: target)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        controller.update(axis: .vertical, horizontal: 12, vertical: 20)
        collection.layoutIfNeeded()
        // The restore target is laid out on its chapter's thread; start from it.
        await engine.waitForViewportIdle()
        collection.layoutIfNeeded()


        let path = try #require(collection.indexPathsForVisibleItems.sorted().first)
        guard case .browser(let oldTile) = engine.chunks[path.item] else { Issue.record("expected browser tile"); return }
        // UIKit can prepare a cell before it becomes visible. Hold that old
        // snapshot across a measured-height correction in an earlier paragraph.
        let prefetched = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: size.width, height: oldTile.documentRect.height))
        prefetched.configure(tile: oldTile, horizontalInset: 12, leadingSpacing: 0, verticalInset: 20)
        let oldPaint = prefetched.interactiveView.displayList
        engine.requestViewport(chapter: 0,
            bounds: CGRect(x: 0, y: max(0, oldTile.documentRect.minY - 3000), width: size.width - 24, height: 4500),
            anchorOffset: target)
        await engine.waitForViewportIdle()
        guard case .browser(let currentTile) = engine.chunks[path.item] else { Issue.record("expected current browser tile"); return }
        let expected = chapter.document.items(in: currentTile.documentRect.insetBy(dx: 0, dy: -1))
        #expect(!oldPaint.hasSameContents(as: expected), "fixture must change prefetched paint geometry")
        let oldBaselines = oldPaint.items.compactMap { item -> (Int, CGFloat)? in
            guard case .text(let text) = item else { return nil }
            return (text.sourceRange.location, text.baselineY)
        }
        let shifts = expected.items.compactMap { item -> CGFloat? in
            guard case .text(let text) = item,
                  let old = oldBaselines.first(where: { $0.0 == text.sourceRange.location }) else { return nil }
            return abs(text.baselineY - old.1)
        }
        let staleShift = try #require(shifts.max())
        print("[ViewportPrefetch] staleBaselineShift=\(staleShift)")
        #expect(staleShift > 1, "fixture must expose a positional error, not only a different CTLine identity")
        controller.collectionView(collection, willDisplay: prefetched, forItemAt: path)
        #expect(prefetched.interactiveView.displayList.hasSameContents(as: expected),
            "willDisplay must not expose the prefetch-time source positions after a viewport commit")
    }

    @Test func retiredChapterResourceCountStaysCurrentWithoutRepeatedTreeWalks() throws {
        let html = "<body>" + String(repeating: "<p>中文 resource residency check.</p>", count: 1000) + "</body>"
        let session = try HTMLLayoutDocument(html: html,
            configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 600)).makeViewportSession()
        #expect(session.retainedLineCount == 0)
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1200))
        #expect(session.retainedLineCount > 0)
        session.discardRenderingResources()
        let start = SourcePerfTrace.now
        var total = 0
        for _ in 0..<2000 { total += session.retainedLineCount }
        SourcePerfTrace.record("test.viewport.retiredPolling", "queries=2000 paragraphs=1000", since: start, thresholdMs: 0)
        print("[ViewportPolling] ms=\((SourcePerfTrace.now - start) * 1000)")
        #expect(total == 0)
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1200))
        #expect(session.retainedLineCount > 0, "reloading must refresh the count")
    }

    @Test func chapterArrivalDuringTrackingDoesNotSuspendViewportUntilDefaultMode() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let chapters = (0..<3).map { chapter in
            MockBrowserLayoutResource.Chapter(title: "Chapter \(chapter)", href: "\(chapter).xhtml",
                html: "<body>" + (0..<60).map { "<p id='p\($0)'>Chapter \(chapter) paragraph \($0) "
                    + String(repeating: "continuous 中文內容 ", count: 20) + "</p>" }.joined() + "</body>", css: [])
        }
        let builder = MockAttributedStringBuilder(texts: chapters.map(\.html))
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        // The host starts the engine itself on its first layout, adjacent chapters
        // included (kickoffEngineIfNeeded). This test starts chapter 2 first, so
        // that start owns chapter 0: hold its content, as a slow fetch would,
        // until the reader has scrolled back toward it (below).
        let resource = HeldChapterResource(MockBrowserLayoutResource(chapters: chapters), holding: 0)
        defer { resource.release() }
        let browser = BrowserLayoutPageEngine(resource: resource,
            delegate: delegate, settings: settings, mode: .browserAuto)
        browser.usesViewportScrolling = true
        let size = scene.coordinateSpace.bounds.size
        await browser.start(renderSize: size, bookId: "tracking-arrival")
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        await engine.start(initialChapter: 1, contentWidth: size.width - 24,
                           viewportExtent: size.height, loadAdjacentChapters: false)
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            horizontalInset: 12, verticalInset: 20, backgroundColor: .white)
        // Begin in the middle, away from both neighbors.
        let initial = try #require(engine.browserChapter(at: 1)?.facts?.anchorOffsets["p30"])
        controller.setInitialPosition(chapter: 1, charOffset: initial)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()

        // An async chapter finishes while the UI is tracking a drag. Pump only
        // tracking mode, never default mode: the user need not lift their finger
        // before the outline and newly exposed text become available.
        for spine in [2, 0] {
            if spine == 0 {
                // Scrolling up toward chapter 1's top is what requests the previous
                // chapter in the reader, so it arrives inside the window the host
                // keeps resident (visible bounds ± 2000 pt) with the first screen it
                // was built with. Released any earlier, it could arrive while the
                // viewport was still mid-chapter 1 and be retired there before the
                // jump below reached it. The drag also abandons a restore still
                // waiting for its layout, which would pull the viewport back.
                controller.scrollViewWillBeginDragging(collection)
                let first = try #require(engine.chapterRanges[1]?.first)
                let top = try #require(collection.layoutAttributesForItem(at: IndexPath(item: first, section: 0))?.frame)
                collection.setContentOffset(CGPoint(x: 0, y: top.minY + 300), animated: false)
                controller.scrollViewDidScroll(collection)
                collection.layoutIfNeeded()
                resource.release()
            }
            await engine.start(initialChapter: spine, contentWidth: size.width - 24,
                               viewportExtent: size.height, loadAdjacentChapters: false)
            // The host's own start may already own this load (see `resource`).
            // start() deduplicates an in-flight request; it does not await that
            // request's completion. Observe its actual commit, without pumping
            // default mode or imposing an arbitrary wait.
            if engine.chapterRanges[spine] == nil {
                var arrival: AnyCancellable?
                await withCheckedContinuation { continuation in
                    arrival = engine.events.sink { event in
                        guard case .chunksInserted(_, let chapter) = event, chapter == spine else { return }
                        arrival?.cancel()
                        continuation.resume()
                    }
                }
            }
            CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.tracking.rawValue as CFString), 0, true)
            let dataSource = try #require(collection.dataSource)
            #expect(dataSource.collectionView(collection, numberOfItemsInSection: 0) == engine.chunks.count,
                    "chapter arrival must publish its outline without waiting for default run-loop mode")
            collection.layoutIfNeeded()
            let row = try #require(engine.chapterRanges[spine]?.first, "missing committed chapter \(spine)")
            let frame = try #require(collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
            collection.setContentOffset(CGPoint(x: 0, y: frame.minY + 300), animated: false)
            controller.scrollViewDidScroll(collection)
            collection.layoutIfNeeded()
            let visible = collection.visibleCells.compactMap { $0 as? BrowserScrollTileCell }
            #expect(visible.contains { $0.currentTile?.chapter.spineIndex == spine
                && $0.interactiveView.displayList.items.contains { if case .text = $0 { true } else { false } } },
                "rapid movement into the arriving chapter must show text during tracking")
        }
    }

    @Test func coldScrollSkipsPaginationAndReverseCrossChapterKeepsVisibleTextAndGeometry() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let chapters = (0..<3).map { chapter in
            MockBrowserLayoutResource.Chapter(title: "Chapter \(chapter)", href: "\(chapter).xhtml",
                html: "<body>" + (0..<120).map { "<p id='p\($0)'>Chapter \(chapter) paragraph \($0) " + String(repeating: "continuous 測試內容 ", count: 12) + "</p>" }.joined() + "</body>", css: [])
        }
        let builder = MockAttributedStringBuilder(texts: chapters.map(\.html))
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let browser = BrowserLayoutPageEngine(resource: MockBrowserLayoutResource(chapters: chapters),
            delegate: delegate, settings: settings, mode: .browserAuto)
        browser.usesViewportScrolling = true
        let size = scene.coordinateSpace.bounds.size
        await browser.start(renderSize: size, bookId: "viewport-test")
        #expect(delegate.layouts.isEmpty, "continuous cold start must not run paged layout")
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        await engine.start(initialChapter: 1, contentWidth: size.width - 24,
                           viewportExtent: size.height, loadAdjacentChapters: false)
        let initialChapter = try #require(engine.browserChapter(at: 1))
        let initial = try #require(initialChapter.layoutOwner)
        // Loading a chapter lays out its first screen only (on the layout thread).
        #expect(await initial.diagnostics().shapedLineCount < 120)
        let target = try #require(initialChapter.facts?.anchorOffsets["p60"])
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            horizontalInset: 12, verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: 1, charOffset: target)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        #expect(collection.collectionViewLayout is ReaderScrollLayout)
        await engine.waitForViewportIdle()
        let mounted = await initial.diagnostics()
        #expect(mounted.shapedLineCount < 500)
        #expect(mounted.estimatedBoxCount > 50)
        var committed: CoreTextReadingPosition?
        controller.onProgressCommit = { committed = $0 }
        controller.scrollViewDidEndDecelerating(collection)
        #expect(committed?.spineIndex == 1)
        #expect(abs((committed?.charOffset ?? -1000) - target) < 80)
        // Prepend/append completion during an uncommitted drag must use the live
        // viewport, not the original handover position stored by the controller.
        collection.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y + 500), animated: false)
        controller.scrollViewDidScroll(collection)
        await engine.waitForViewportIdle()
        let visibleBeforeInsertion = try #require(collection.visibleCells.compactMap { $0 as? BrowserScrollTileCell }.first)
        let sourceBeforeInsertion = visibleBeforeInsertion.currentTile?.chapter.spineIndex
        await engine.start(initialChapter: 0, contentWidth: size.width - 24, viewportExtent: size.height, loadAdjacentChapters: false)
        await engine.start(initialChapter: 2, contentWidth: size.width - 24, viewportExtent: size.height, loadAdjacentChapters: false)
        await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        collection.layoutIfNeeded()
        controller.scrollViewDidEndDecelerating(collection)
        #expect(committed?.spineIndex == sourceBeforeInsertion)
        #expect((committed?.charOffset ?? 0) > target + 80, "arrival must not restore the original, now stale target")
        func visiblePaintCells() throws -> [BrowserScrollTileCell] {
            // UIKit can keep departing cells in visibleCells during a large
            // programmatic chapter jump. Query every actual viewport slot:
            // neither an offscreen retired cell nor a missing onscreen cell
            // should be mistaken for a successful resource restoration.
            let paths = (collection.collectionViewLayout.layoutAttributesForElements(in: collection.bounds) ?? [])
                .map(\.indexPath).sorted()
            try #require(!paths.isEmpty)
            return try paths.map { try #require(collection.cellForItem(at: $0) as? BrowserScrollTileCell) }
        }
        // Resolve each target afresh: estimated chapter extents change item counts.
        for spine in [1, 2, 1, 0, 1] {
            let chapter = try #require(engine.browserChapter(at: spine))
            let owner = try #require(chapter.layoutOwner)
            let offset = try #require(chapter.facts?.anchorOffsets["p60"])
            controller.setInitialPosition(chapter: spine, charOffset: offset)
            collection.layoutIfNeeded()
            await engine.waitForViewportIdle()
            for delta: CGFloat in [480, 960, -720, -400, 800, -300] {
                collection.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y + delta), animated: false)
                controller.scrollViewDidScroll(collection)
                // Text appears once its layout arrives; the frame never waits for it.
                await engine.waitForViewportIdle()
                collection.layoutIfNeeded()
                let cells = collection.visibleCells.compactMap { $0 as? BrowserScrollTileCell }
                try #require(!cells.isEmpty)
                let viewport = collection.bounds
                for cell in cells {
                    let visible = collection.convert(cell.interactiveView.bounds, from: cell.interactiveView).intersection(viewport)
                    if visible.height > 80 {
                        #expect(cell.interactiveView.displayList.items.contains { if case .text = $0 { true } else { false } })
                    }
                }
                let before = collection.contentOffset
                let count = await owner.diagnostics().shapedLineCount
                controller.scrollViewDidScroll(collection)
                await engine.waitForViewportIdle()
                collection.layoutIfNeeded()
                #expect(abs(collection.contentOffset.y - before.y) < 0.5, "idle viewport must not drift after a correction")
                #expect(await owner.diagnostics().shapedLineCount == count, "unchanged demand must reuse layout")
                #expect(engine.geometryFragmentCount == engine.chunks.count)
                #expect(engine.geometryChapterOrder == [0, 1, 2])
                #expect(chapter.retainedLineCount < 1000)
                #expect(chapter.materializedBounds.height <= size.height * 3 + 1802,
                    "layout demand follows complete visible tiles plus one runway, not the obsolete 2000pt cap twice")
            }
            // A reversal can restore released drawing resources while all
            // measured tile extents remain identical. Keep existing cells and
            // their backing surfaces instead of invalidating collection layout.
            let before = collection.contentOffset
            let invalidations = controller.viewportLayoutInvalidationCount
            let cells = try visiblePaintCells()
            let surfaces = cells.map { ObjectIdentifier($0.interactiveView) }
            let start = SourcePerfTrace.now
            for _ in 0..<5 {
                chapter.discardViewportResources()
                controller.scrollViewDidScroll(collection)
                await engine.waitForViewportIdle()
                collection.layoutIfNeeded()
            }
            SourcePerfTrace.record("test.viewport.paintOnlyRestore", "spine=\(spine) restores=5", since: start, thresholdMs: 0)
            #expect(controller.viewportLayoutInvalidationCount == invalidations)
            #expect(abs(collection.contentOffset.y - before.y) < 0.5)
            let restoredCells = try visiblePaintCells()
            #expect(restoredCells.map { ObjectIdentifier($0.interactiveView) } == surfaces)
            for cell in restoredCells {
                let tile = cell.currentTile
                #expect(!cell.interactiveView.displayList.items.isEmpty,
                    "restored spine=\(spine) row=\(String(describing: collection.indexPath(for: cell))) cellFrame=\(cell.frame) viewport=\(collection.bounds) tile=\(String(describing: tile?.documentRect)) bound=\(cell.boundRevision) chapter=\(String(describing: tile?.chapter.layoutRevision)) documentItems=\(tile.map { $0.chapter.document.items(in: $0.documentRect).items.count } ?? -1)")
            }
        }
        #expect(delegate.layouts.isEmpty)
        await browser.activatePagedLayout()
        #expect(!delegate.layouts.isEmpty, "switching back must initialize the paged engine")
    }

    @Test func supersededContentTaskCannotReplaceTheNewViewportSession() async throws {
        let resource = SuspendedViewportResource()
        let settings = EPUBTestFixtures.renderSettings()
        let delegate = CoreTextPageEngine(attributedBuilder: MockAttributedStringBuilder(texts: ["text"]), renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        engine.usesViewportScrolling = true
        let size = CGSize(width: 320, height: 600)
        await engine.start(renderSize: size, bookId: "stale")
        let old = Task { try await engine.makeScrollChapter(at: 0, settings: settings, contentSize: size) }
        await resource.waitUntilSuspended()
        engine.cancelPendingWork()
        let replacement = try #require(await engine.makeScrollChapter(at: 0, settings: settings, contentSize: size))
        resource.release()
        do { _ = try await old.value; Issue.record("retired task should not return a chapter") }
        catch is CancellationError {} catch { Issue.record("unexpected error \(error)") }
        let cached = try #require(await engine.makeScrollChapter(at: 0, settings: settings, contentSize: size))
        #expect(cached === replacement)
        #expect(cached.document.sourceText.contains("new content"))
        let changed = EPUBTestFixtures.renderSettings(fontSize: settings.fontSize + 3)
        engine.updateRenderSettings(changed)
        let updated = try #require(await engine.makeScrollChapter(at: 0, settings: changed, contentSize: size))
        #expect(updated !== replacement)
    }
}

@MainActor
private final class SuspendedViewportResource: BrowserLayoutResourceProviding {
    var chapterCount: Int { 1 }
    private var first = true
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func chapterTitle(at index: Int) -> String { "test" }
    func chapterSourceHref(at index: Int) -> String? { "test.xhtml" }
    func chapterHTML(at index: Int) async throws -> String {
        if first {
            first = false
            await withCheckedContinuation { suspended = $0; observer?.resume(); observer = nil }
            return "<body><p>old content</p></body>"
        }
        return "<body><p>new content</p></body>"
    }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
    func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput { .currentCompatibility(html: html, cssTexts: []) }
    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] { [:] }
    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { nil }
    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)? { nil }
}

/// Withholds one chapter's HTML, as a slow fetch would, until `release()`.
/// The scroll host loads a neighbor on its own, so only the resource can decide
/// when that neighbor arrives.
@MainActor
private final class HeldChapterResource: BrowserLayoutResourceProviding {
    private let base: MockBrowserLayoutResource
    private var held: Int?
    private var readers: [CheckedContinuation<Void, Never>] = []
    init(_ base: MockBrowserLayoutResource, holding chapter: Int) { self.base = base; held = chapter }
    func release() {
        held = nil
        let waiting = readers
        readers.removeAll()
        waiting.forEach { $0.resume() }
    }
    var chapterCount: Int { base.chapterCount }
    func chapterTitle(at index: Int) -> String { base.chapterTitle(at: index) }
    func chapterSourceHref(at index: Int) -> String? { base.chapterSourceHref(at: index) }
    func chapterHTML(at index: Int) async throws -> String {
        if index == held { await withCheckedContinuation { readers.append($0) } }
        return try await base.chapterHTML(at: index)
    }
    func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
        await base.cssFrontendInput(forChapter: index, html: html)
    }
    func prepareFonts(requests: Set<BrowserFontRequest>) async { await base.prepareFonts(requests: requests) }
    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] { [:] }
    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { nil }
    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)? { nil }
}
