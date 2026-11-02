import Combine
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Scroll mode shows a publisher EPUB one *segment* at a time: consecutive chapters of one writing mode,
/// on that mode's axis, because one collection view scrolls along one axis. The case that started it:
/// the table of contents a Calibre conversion appends to a vertical book (`c0004.xhtml`, spine 3) is
/// horizontal, so it is a segment of its own after spines 0–2.
///
/// Crossing from one segment to the next takes the reader's own drag, which a unit test cannot make
/// (`isDragging` is UIKit's); the crossing itself is checked in the simulator. These tests hold
/// everything around it: what a segment loads, how it is entered, and that nothing else crosses.
@Suite("Scroll mode writing-mode segments", .serialized)
@MainActor
struct ScrollWritingModeSegmentTests {
    private static var bounds: CGRect {
        get throws {
            try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                .coordinateSpace.bounds
        }
    }

    /// The converted vertical book loaded the way the reader loads it, before scroll mode shows it.
    private static func reader() async throws -> (EPUBPageRenderer, CoreTextScrollEngine) {
        let session = try await PublicationSession.open(
            sourceURL: try await BookWritingModesTests.converted("vertical-zh.azw3"))
        let renderer = EPUBPageRenderer()
        let modes = await renderer.resolveWritingModes(for: session)
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                      renderSize: try bounds.size,
                      settings: EPUBTestFixtures.renderSettings(writingMode: modes.direction.principalMode))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        return (renderer, try #require(renderer.scrollEngine))
    }

    /// The extents the scroll host starts its engine with on `axis` (`sideInsets` 12, `verticalInset` 20).
    private static func extents(_ axis: CoreTextScrollAxis) throws -> (content: CGFloat, viewport: CGFloat) {
        let size = try bounds.size
        return axis == .vertical ? (size.width - 24, size.height) : (size.height - 20, size.width)
    }

    private static func mount(_ engine: CoreTextScrollEngine, axis: CoreTextScrollAxis,
                              position: CoreTextReadingPosition) throws
        -> (UIWindow, CoreTextCollectionScrollViewController, UICollectionView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: axis,
            sideInsets: .init(left: 12, right: 12), verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: position.spineIndex, charOffset: position.charOffset)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        return (window, controller, collection)
    }

    @Test("a vertical segment loads its own chapters and stops at the horizontal table of contents")
    func verticalSegmentStopsAtTheTOC() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(renderer.scrollSegmentIsPending, "scroll mode cannot show the book before it knows the segment")
        #expect(await renderer.enterScrollSegment(containing: 2) == .entered)
        #expect(renderer.scrollSegmentMode == .verticalRTL)
        #expect(engine.renderSettings.writingMode == .verticalRTL)
        #expect((renderer.engine as? BrowserLayoutPageEngine)?.usesViewportScrolling == false)

        let extents = try Self.extents(.horizontalRTL)
        await engine.start(initialChapter: 2, contentWidth: extents.content, viewportExtent: extents.viewport)
        #expect(engine.isReady)
        #expect(engine.chapterRanges[2]?.isEmpty == false)
        #expect(engine.chapterRanges[1]?.isEmpty == false)
        #expect(engine.chapterRanges[3] == nil, "the TOC is another segment's")
        #expect(engine.segmentBoundary(after: 2) == 3)
        #expect(engine.segmentBoundary(before: 2) == nil)
        #expect(engine.chunks.allSatisfy { $0.writingMode == .verticalRTL })
        // Prefetch at the segment's end stops at its boundary.
        engine.ensureChapterAhead(of: 2)
        #expect(engine.chapterRanges[3] == nil)
    }

    @Test("entering the TOC's segment lays it out horizontally and viewport-driven, bounded by spine 2")
    func enteringTheTOCSegment() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 3) == .entered)
        #expect(renderer.scrollSegmentMode == .horizontal)
        #expect(engine.renderSettings.writingMode == .horizontal)
        let browser = try #require(renderer.engine as? BrowserLayoutPageEngine)
        #expect(browser.usesViewportScrolling)

        let extents = try Self.extents(.vertical)
        #expect(await engine.reslice(restoreAt: 3, contentWidth: extents.content, viewportExtent: extents.viewport))
        #expect(engine.chapterRanges[3]?.isEmpty == false)
        // A reslice lays out its target alone; the host's prefetch then asks for the chapter before it,
        // which turns out to be the vertical segment's. The prefetch's load is a main-actor task: one
        // queued after it runs once it has started, and the engine then reports when it is done.
        engine.ensureChapterBehind(of: 3)
        await Task { @MainActor in }.value
        await engine.waitForViewportIdle()
        #expect(engine.chapterRanges[2] == nil)
        #expect(engine.segmentBoundary(before: 3) == 2)
        #expect(engine.segmentBoundary(after: 3) == nil, "past the end of the book is no segment")
        #expect(engine.chunks.allSatisfy { $0.writingMode == .horizontal })
        #expect(browser.testStaleAdmissionSpines.isEmpty, "\(browser.testStaleAdmissionSpines)")
    }

    @Test("the segment on screen is entered once; leaving scroll mode lets the next session decide its own")
    func enteringIsIdempotent() async throws {
        let (renderer, _) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 1) == .entered)
        #expect(await renderer.enterScrollSegment(containing: 2) == .unchanged)
        #expect(await renderer.enterScrollSegment(containing: 0) == .unchanged)
        renderer.leaveScrollSegment()
        #expect(renderer.scrollSegmentIsPending)
        #expect(await renderer.enterScrollSegment(containing: 3) == .entered)
        #expect(renderer.scrollSegmentMode == .horizontal)
    }

    @Test("a refresh carrying the book's mode, submitted before the segment was entered, keeps the segment's")
    func staleRefreshKeepsTheSegmentMode() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 3) == .entered)
        // Entering scroll mode submits its refresh at once, built while no segment was on screen.
        let request = ReaderRenderRefreshRequest(
            intent: .layout, mode: .scroll,
            settings: EPUBTestFixtures.renderSettings(writingMode: .verticalRTL),
            position: .chapterStart(3), viewportSize: try Self.bounds.size)
        let refresh = Task { await renderer.refresh(request) }
        var commit: ReaderVisibleRefreshCommit?
        for await pending in renderer.$pendingVisibleRefreshCommit.values {
            if let pending { commit = pending; break }
        }
        #expect(engine.renderSettings.writingMode == .horizontal)
        #expect((renderer.engine as? BrowserLayoutPageEngine)?.usesViewportScrolling == true)
        let transactionID = try #require(commit?.transactionID)
        renderer.finishVisibleRefresh(transactionID: transactionID, outcome: .applied)
        _ = await refresh.value
    }

    @Test("an engine started on a chapter outside its segment shows nothing rather than the wrong mode")
    func startOutsideTheSegment() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 2) == .entered)
        let extents = try Self.extents(.horizontalRTL)
        #expect(await engine.reslice(restoreAt: 3, contentWidth: extents.content,
                                     viewportExtent: extents.viewport) == false)
        #expect(engine.chunks.isEmpty)
        #expect(!engine.isReady)
    }

    @Test("restore, reslice and offsets set by the app at a segment's edge never cross it")
    func onlyTheReadersDragCrosses() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 2) == .entered)
        let extents = try Self.extents(.horizontalRTL)
        await engine.start(initialChapter: 2, contentWidth: extents.content, viewportExtent: extents.viewport)
        let length = try #require(engine.characterCount(forChapter: 2))
        // Restore onto the segment's last line: its forward edge, with the TOC beyond it.
        let (window, controller, collection) = try Self.mount(
            engine, axis: .horizontalRTL, position: .init(spineIndex: 2, charOffset: max(0, length - 1)))
        defer { window.isHidden = true; window.rootViewController = nil }
        var crossed: [Int] = []
        controller.onSegmentBoundary = { crossed.append($0) }
        #expect(collection.alwaysBounceHorizontal && !collection.alwaysBounceVertical)

        let end = collection.contentSize.width - collection.bounds.width + collection.adjustedContentInset.right
        let start = -collection.adjustedContentInset.left
        collection.setContentOffset(CGPoint(x: start, y: 0), animated: false)
        collection.setContentOffset(CGPoint(x: end, y: 0), animated: false)
        collection.layoutIfNeeded()
        // A refresh's reslice lands on the same edge.
        let outcome = await withCheckedContinuation { continuation in
            controller.applyVisibleRefresh(.init(transactionID: 1, mode: .scroll,
                                                 position: .init(spineIndex: 2, charOffset: max(0, length - 1)))) {
                continuation.resume(returning: $1)
            }
        }
        #expect(outcome == .applied)
        #expect(crossed.isEmpty, "only the reader's drag crosses into \(crossed)")
    }

    @Test("turning the axis shows nothing of the segment left until the reslice, which starts the new one square")
    func axisTurnWaitsForTheReslice() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 2) == .entered)
        let extents = try Self.extents(.horizontalRTL)
        await engine.start(initialChapter: 2, contentWidth: extents.content, viewportExtent: extents.viewport)
        let length = try #require(engine.characterCount(forChapter: 2))
        let (window, controller, collection) = try Self.mount(
            engine, axis: .horizontalRTL, position: .init(spineIndex: 2, charOffset: length / 2))
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(collection.numberOfItems(inSection: 0) > 0)

        #expect(await renderer.enterScrollSegment(containing: 3) == .entered)
        controller.update(axis: .vertical, sides: .init(left: 12, right: 12), vertical: 20)
        collection.layoutIfNeeded()
        let start = CGPoint(x: -collection.adjustedContentInset.left, y: -collection.adjustedContentInset.top)
        #expect(collection.numberOfItems(inSection: 0) == 0, "spine 2's columns must not show on the vertical axis")
        #expect(collection.contentOffset == start, "the horizontal offset must not carry over to the vertical axis")

        let outcome = await withCheckedContinuation { continuation in
            controller.applyVisibleRefresh(.init(transactionID: 1, mode: .scroll, position: .chapterStart(3))) {
                continuation.resume(returning: $1)
            }
        }
        #expect(outcome == .applied)
        #expect(collection.numberOfItems(inSection: 0) == engine.chunks.count)
        #expect(engine.chunks.allSatisfy { $0.writingMode == .horizontal && $0.chapterIndex == 3 })
        #expect(collection.contentOffset == start, "the TOC opens at its top, its lines' starts on screen")
    }

    @Test("progress saved inside the TOC's horizontal segment reopens on the same line")
    func saveAndReopenInsideTheTOC() async throws {
        let extents = try Self.extents(.vertical)
        func open(at position: CoreTextReadingPosition) async throws
            -> (UIWindow, CoreTextScrollEngine, CoreTextReadingPosition?) {
            let (renderer, engine) = try await Self.reader()
            #expect(await renderer.enterScrollSegment(containing: position.spineIndex) == .entered)
            await engine.start(initialChapter: position.spineIndex, contentWidth: extents.content,
                               viewportExtent: extents.viewport, loadAdjacentChapters: false)
            let (window, controller, collection) = try Self.mount(engine, axis: .vertical, position: position)
            var saved: CoreTextReadingPosition?
            controller.onProgressCommit = { saved = $0 }
            controller.scrollViewDidEndDragging(collection, willDecelerate: false)
            return (window, engine, saved)
        }
        let (window, engine, first) = try await open(at: .chapterStart(3))
        let saved = try #require(first, "a horizontal chapter of a vertical book must save its progress")
        #expect(saved.spineIndex == 3)
        #expect(engine.chunks.allSatisfy { $0.writingMode == .horizontal })
        window.isHidden = true
        window.rootViewController = nil

        let bookID = "scroll-segment-test-" + UUID().uuidString
        let path = StorageLocations.readingPosition.appendingPathComponent(bookID + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        await JSONFileReadingPositionStore().save(saved, for: bookID)
        let reopened = try #require(JSONFileReadingPositionStore().loadSync(for: bookID))
        let (nextWindow, _, resaved) = try await open(at: reopened)
        defer { nextWindow.isHidden = true; nextWindow.rootViewController = nil }
        #expect(resaved == saved)
    }

    @Test("a one-screen segment still moves under a drag, and 自動閱讀 stops at its end")
    func oneScreenSegment() async throws {
        let (renderer, engine) = try await Self.reader()
        #expect(await renderer.enterScrollSegment(containing: 3) == .entered)
        let extents = try Self.extents(.vertical)
        await engine.start(initialChapter: 3, contentWidth: extents.content, viewportExtent: extents.viewport)
        let (window, controller, collection) = try Self.mount(engine, axis: .vertical, position: .chapterStart(3))
        defer { window.isHidden = true; window.rootViewController = nil }
        var crossed: [Int] = []
        controller.onSegmentBoundary = { crossed.append($0) }
        #expect(collection.alwaysBounceVertical && !collection.alwaysBounceHorizontal)
        var steps = 0
        while controller.autoScroll(by: collection.bounds.height), steps < 50 { steps += 1 }
        #expect(steps < 50, "自動閱讀 must stop at the segment's end")
        #expect(crossed.isEmpty)
    }
}
