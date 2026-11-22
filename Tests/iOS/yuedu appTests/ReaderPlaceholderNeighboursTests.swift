import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// `layoutLanded(forChapter:)` is mutating (it answers once per vend), and `#expect` cannot
/// wrap a mutating call, so each answer is taken into a local first.
@Suite("ReaderPlaceholderNeighbours")
struct ReaderPlaceholderNeighboursTests {

    @Test func aChapterNobodyVendedTakesTheShortcut() {
        var neighbours = ReaderPlaceholderNeighbours()
        let replaces = neighbours.layoutLanded(forChapter: 2)
        #expect(!replaces)
    }

    /// The 2026-11-23 case: the page after a one-page chapter was vended as 載入中 for
    /// chapter 2, and chapter 2 laid out while the reader was still on chapter 1.
    @Test func aVendedPlaceholderMakesItsChapterReplaceTheStackOnce() {
        var neighbours = ReaderPlaceholderNeighbours()
        neighbours.vended(placeholderFor: [2])

        let first = neighbours.layoutLanded(forChapter: 2)
        // Re-placing the stack made UIKit ask again; a second install of the same
        // chapter (its full pass after the first page) owes nothing more.
        let second = neighbours.layoutLanded(forChapter: 2)
        #expect(first)
        #expect(!second)
    }

    @Test func anotherChapterLandingKeepsTheRecord() {
        var neighbours = ReaderPlaceholderNeighbours()
        neighbours.vended(placeholderFor: [2])

        let other = neighbours.layoutLanded(forChapter: 0)
        let vended = neighbours.layoutLanded(forChapter: 2)
        #expect(!other)
        #expect(vended)
    }

    /// A spread can hold a 載入中 page on each side.
    @Test func aSpreadRecordsEveryChapterItWaitsFor() {
        var neighbours = ReaderPlaceholderNeighbours()
        neighbours.vended(placeholderFor: [3, 4])

        let right = neighbours.layoutLanded(forChapter: 4)
        let left = neighbours.layoutLanded(forChapter: 3)
        #expect(right)
        #expect(left)
    }

    @Test func replacedNeighboursForgetWhatWasVended() {
        var neighbours = ReaderPlaceholderNeighbours()
        neighbours.vended(placeholderFor: [2])
        neighbours.neighboursReplaced()

        let replaces = neighbours.layoutLanded(forChapter: 2)
        #expect(!replaces)
    }
}

/// The paged reader's coordinator with a real engine: a completed turn leaves UIKit holding
/// the page it left, so a 載入中 page the reader turned away from still owes a re-place
/// when its chapter lands.
@Suite("Paged reader: 載入中 neighbours after a turn", .serialized)
@MainActor
struct ReaderPlaceholderNeighbourTurnTests {
    private struct Harness {
        let engine: CoreTextPageEngine
        let coordinator: CoreTextPageEngineView.Coordinator
        let pageViewController: UIPageViewController
        let visible: UIViewController
        let directory: URL
    }

    /// Chapter 0 is one page and laid out; chapter 1 is not, so global page 1 is its
    /// 載入中 page. The reader is on page 0.
    ///
    /// Chapter 1 is the book's last, as in the 2026-11-23 case. A chapter whose real page
    /// count moves the chapters after it makes the engine announce the whole book, which
    /// rewrites the stack anyway; only a landing that moves nothing after it can leave
    /// UIKit's stale page in place.
    private func makeHarness() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: [
                "Opening page.",
                String(repeating: "Last chapter.\n", count: 40),
            ]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        // `start` leaves a background scan of chapter sizes running, which announces the
        // whole book (`nil`) when it ends, and a whole-book announcement always rewrites
        // the stack. Settle it before the scenario, or it, not the chapter under test, is
        // what replaces the page.
        let (wholeBookAnnounced, announce) = AsyncStream<Void>.makeStream()
        engine.onChapterReady = { spineIndex in
            if spineIndex == nil { announce.yield() }
        }
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        var announcements = wholeBookAnnounced.makeAsyncIterator()
        _ = await announcements.next()
        announce.finish()
        try #require(engine.localPosition(for: 1).spineIndex == 1)

        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .slide, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pageViewController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        coordinator.bindEngineCallbacks(to: engine, pageViewController: pageViewController)
        let visible = engine.pageViewController(at: 0)
        try #require(!(visible is PlaceholderPageViewController))
        pageViewController.setViewControllers([visible], direction: .forward, animated: false)
        return Harness(
            engine: engine, coordinator: coordinator, pageViewController: pageViewController,
            visible: visible, directory: directory
        )
    }

    /// Chapter 1 lands, and every main-queue block its announcement queued has run.
    private func layOutChapterOne(in harness: Harness) async {
        await harness.engine.preloadChapter(at: 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func turningBackOffAPlaceholderReplacesTheStackWhenItsChapterLands() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let placeholder = harness.engine.pageViewController(at: 1)
        try #require(placeholder is PlaceholderPageViewController)

        // The reader was on chapter 1's 載入中 page and turned back to page 0 before
        // chapter 1 laid out. Synchronous, so the layout cannot land in between.
        harness.coordinator.pageViewController(
            harness.pageViewController,
            didFinishAnimating: true,
            previousViewControllers: [placeholder],
            transitionCompleted: true
        )
        await layOutChapterOne(in: harness)

        // The stack was written again, so UIKit drops the stale page and asks anew.
        #expect(harness.pageViewController.viewControllers?.first !== harness.visible)
    }

    /// The control: turning off a page with content owes nothing, and a chapter the
    /// reader is not on takes the shortcut. Without it the test above proves nothing.
    @Test func turningOffARealPageLeavesTheStackAlone() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let left = harness.engine.pageViewController(at: 0)

        harness.coordinator.pageViewController(
            harness.pageViewController,
            didFinishAnimating: true,
            previousViewControllers: [left],
            transitionCompleted: true
        )
        await layOutChapterOne(in: harness)

        #expect(harness.pageViewController.viewControllers?.first === harness.visible)
    }
}
