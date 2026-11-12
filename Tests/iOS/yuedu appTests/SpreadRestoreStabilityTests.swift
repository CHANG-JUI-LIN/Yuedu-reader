import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 回饋中心 #182 (iPad 雙頁, 網路書源): every open from 書架 lands somewhere else — the video
/// shows the same chapter at 22/22, then 21/22, then 20/22, and later whole chapters back.
///
/// The spread holding the restored position used to be the even/odd pair of *global* page
/// indices, and a global index counts estimated pages for every chapter not laid out yet. Which
/// chapters are laid out differs from open to open, so the same position fell on a spread's
/// first page one time and its second the next — and the position saved on closing is the
/// spread's first page. Each open could move the reader one page back, across a chapter start
/// onto the previous chapter's last page, and on.
@Suite("iPad spreads restore where they were left", .serialized)
@MainActor
struct SpreadRestoreStabilityTests {
    /// One open: a fresh engine, a reader restoring `target`, and the position it reports.
    private struct Open {
        let shownPositions: [CoreTextReadingPosition]
        let reported: CoreTextReadingPosition?
        let targetPage: Int?
        let shownPages: [Int]
    }

    @Test("reopening a spread restores the same spread, whichever chapters are laid out",
          arguments: [PageTurnStyle.slide, .curl], [false, true])
    func reopenKeepsTheSpread(style: PageTurnStyle, chapterStart: Bool) async throws {
        let lines = try await chapterOneLinesShiftingParity()
        let probe = try await engine(chapterOneLines: lines, layingOutChapterOne: true)
        let chapter = try #require(probe.layouts[2])
        try #require(chapter.pageRanges.count > 3)
        // A second page of chapter 2, or its first page.
        let saved = CoreTextReadingPosition(
            spineIndex: 2,
            charOffset: chapterStart ? 0 : Int(chapter.pageRanges[1].location)
        )

        var target = saved
        var reportedAfterFirst: CoreTextReadingPosition?
        for cycle in 0..<4 {
            // Alternate which chapters are laid out before the reader shows: chapter 1 is
            // estimated at one page in one open and laid out at its real count in the next,
            // which flips the parity of every global page index in chapter 2.
            let open = try await open(
                target: target, style: style, lines: lines, layingOutChapterOne: cycle % 2 == 1
            )
            let reported = try #require(open.reported, "cycle \(cycle) reported no position")
            #expect(open.targetPage.map(open.shownPages.contains) == true,
                    "cycle \(cycle): the spread \(open.shownPages) does not show the restored page \(String(describing: open.targetPage))")
            #expect(reported.spineIndex == saved.spineIndex,
                    "cycle \(cycle): restoring \(target) reported \(reported)")
            if let reportedAfterFirst {
                #expect(reported == reportedAfterFirst,
                        "cycle \(cycle): restoring \(target) reported \(reported), the open before reported \(reportedAfterFirst)")
            } else {
                reportedAfterFirst = reported
            }
            target = reported
        }
    }

    @Test("a spread restored before its chapter is laid out keeps the restored position",
          arguments: [PageTurnStyle.slide, .curl])
    func unlaidTargetKeepsItsPosition(style: PageTurnStyle) async throws {
        let lines = try await chapterOneLinesShiftingParity()
        let probe = try await engine(chapterOneLines: lines, layingOutChapterOne: true)
        let chapter = try #require(probe.layouts[2])
        let saved = CoreTextReadingPosition(spineIndex: 2, charOffset: Int(chapter.pageRanges[1].location))

        let open = try await open(
            target: saved, style: style, lines: lines, layingOutChapterOne: false, layingOutTarget: false
        )
        #expect(open.reported == saved,
                "a 載入中 spread for \(saved) reported \(String(describing: open.reported))")
    }

    // MARK: - Opens

    private func open(
        target: CoreTextReadingPosition,
        style: PageTurnStyle,
        lines: Int,
        layingOutChapterOne: Bool,
        layingOutTarget: Bool = true
    ) async throws -> Open {
        let engine = try await engine(
            chapterOneLines: lines, layingOutChapterOne: layingOutChapterOne, layingOutTarget: layingOutTarget
        )
        engine.updateReadingPosition(target)
        let state = RestoreHostState(
            target: target,
            page: engine.pageIndex(for: target) ?? engine.estimatedGlobalPage(for: target) ?? 0
        )
        let host = UIHostingController(rootView: RestorePagedHost(state: state, engine: engine, style: style))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await drainMainQueue()

        let pvc = try #require(host.firstDescendant(UIPageViewController.self))
        let pages = (pvc.viewControllers ?? []).flatMap { viewController -> [UIViewController] in
            (viewController as? ReaderSpreadPageViewController)?.pageViewControllers ?? [viewController]
        }
        let positions = pages.compactMap { ($0 as? CoreTextReadingPositionProviding)?.coreTextReadingPosition }
        return Open(
            shownPositions: positions,
            reported: state.reported,
            targetPage: engine.pageIndex(for: target),
            shownPages: positions.compactMap { engine.pageIndex(for: $0) }
        )
    }

    /// Chapter 0 laid out by `start`, chapter 2 (the reading chapter) laid out as a reopened
    /// book's cached chapter is, and chapter 1 either laid out or left at its one-page estimate.
    private func engine(
        chapterOneLines: Int,
        layingOutChapterOne: Bool,
        layingOutTarget: Bool = true
    ) async throws -> CoreTextPageEngine {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CoreTextPageEngine(
            attributedBuilder: RestoreBuilder(lines: [40, chapterOneLines, 200]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 500, height: 700), bookId: UUID().uuidString)
        if layingOutChapterOne { _ = await engine.preloadChapter(at: 1) }
        if layingOutTarget { _ = await engine.preloadChapter(at: 2) }
        return engine
    }

    /// A chapter-1 length whose real page count differs in parity from its one-page estimate,
    /// so laying it out shifts chapter 2's global page indices by an odd number.
    private func chapterOneLinesShiftingParity() async throws -> Int {
        for lines in stride(from: 30, through: 90, by: 7) {
            let engine = try await engine(chapterOneLines: lines, layingOutChapterOne: true, layingOutTarget: false)
            if let pages = engine.layouts[1]?.pageRanges.count, pages % 2 == 0 { return lines }
        }
        throw ParityShiftUnavailable()
    }

    private struct ParityShiftUnavailable: Error {}

    private func drainMainQueue() async {
        for _ in 0..<6 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// What `ReaderView` hands the paged host on opening a book: the restored position as the
/// navigator's external target, and the position each settle reports — the one it saves.
@MainActor
private final class RestoreHostState: ObservableObject {
    @Published var externalTarget: CoreTextReadingPosition?
    @Published var page: Int
    private(set) var reported: CoreTextReadingPosition?

    init(target: CoreTextReadingPosition, page: Int) {
        externalTarget = target
        self.page = page
    }

    func report(_ position: CoreTextReadingPosition?) {
        if let position { reported = position }
    }
}

private struct RestorePagedHost: View {
    @ObservedObject var state: RestoreHostState
    let engine: any PageRenderingProvider
    let style: PageTurnStyle

    var body: some View {
        CoreTextPageEngineView(
            engine: engine, pageTurnStyle: style, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: true,
            spreadGutter: PageViewControllerPagingAdapterDescriptor(pageTurnStyle: style).spreadGutter,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: state.externalTarget,
            pageTurnCommand: nil, clearExternalTargetPosition: { state.externalTarget = nil },
            currentPage: $state.page,
            onPageChanged: { _, position in state.report(position) }, onTapZone: { _ in }
        )
    }
}

/// Online chapters of fixed lengths; no byte sizes, so a chapter not laid out counts one page.
private actor RestoreBuilder: AttributedStringBuilding {
    nonisolated let lines: [Int]
    init(lines: [Int]) { self.lines = lines }
    nonisolated var chapterCount: Int { lines.count }
    nonisolated var prefersLazyByteScan: Bool { true }
    nonisolated func chapterTitle(at index: Int) -> String { "第\(index + 1)章" }
    func chapterDataSize(at index: Int) -> Int { 0 }
    nonisolated func buildChapter(at index: Int, settings: ReaderRenderSettings,
                                  themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        let text = String(repeating: "第\(index + 1)章的正文，風穿過山林，江水映著月光。\n", count: lines[index])
        return AttributedChapterBuildResult(attributedString: NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: themeTextColor,
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
    }
}

private extension UIViewController {
    func firstDescendant<T: UIViewController>(_ type: T.Type) -> T? {
        for child in children {
            if let match = (child as? T) ?? child.firstDescendant(type) { return match }
        }
        return nil
    }
}
