import SwiftUI
import UIKit
import YueduCoreText

// MARK: - Per-page 頁眉／頁腳 (paged mode)

extension ReaderView {

    /// True when the pages on screen are CoreText pages that carry something of the
    /// bars' channel — the bars themselves, the bookmark ribbon, or both.
    ///
    /// Only the CoreText paged renderer can do it: the bars go in through
    /// `CoreTextPageView.renderPage`, which is also what bakes curl back-pages and
    /// cover-transition snapshots, so they follow the page through every turn
    /// animation. Scroll mode keeps a fixed overlay by design (the content scrolls
    /// under a stationary band), and fixed-layout pages are images with no
    /// CoreText surface to draw into.
    var pagesCarryBarsChannel: Bool {
        !effectiveScrollMode && !usesFixedLayoutRenderer && usesCoreTextEPUB
    }

    /// True when the 頁眉／頁腳 text is drawn *into* each page rather than over the screen.
    ///
    /// Not in a two-page spread: each half drew its own pair, so the screen showed two
    /// headers and two footers (reported 2026-10-10). The spread is one screen and gets
    /// one pair, from the fixed layer, spanning both pages — the user's choice; the
    /// price is that those bars stay put during a turn instead of turning with the
    /// page. The bookmark ribbon still belongs to its page and stays baked.
    var usesPageBakedBars: Bool {
        pagesCarryBarsChannel && effectiveReaderSpreadMode != .doublePage
    }

    /// The page the screen-fixed bars describe in a two-page spread: the later page of
    /// the pair in reading order, i.e. the last page the reader has on screen. Spreads
    /// tile global pages (0,1)(2,3)… (`spreadViewController(containingPage:)`); a
    /// final spread with no second page describes its only page.
    var spreadBarsGlobalPage: Int? {
        guard pagesCarryBarsChannel, effectiveReaderSpreadMode == .doublePage,
              let engine = epubRenderer.engine, engine.totalPages > 0
        else { return nil }
        let pairStart = (max(0, currentPage) / 2) * 2
        return min(pairStart + 1, engine.totalPages - 1)
    }

    var readerPageBarsEnvironment: ReaderPageBarsEnvironment {
        readerPageBarsEnvironment(clock: readerOverlayClock)
    }

    /// Same as above for one specific set of clock readings — see
    /// `readerOverlayContentSnapshot(clock:)` for why the clock is a parameter.
    func readerPageBarsEnvironment(
        clock: ReaderOverlayClockSnapshot
    ) -> ReaderPageBarsEnvironment {
        ReaderPageBarsEnvironment(
            layout: settings.readerBarLayout,
            headerEnabled: readerConfig.readerHeaderVisible,
            footerEnabled: readerConfig.readerFooterVisible,
            readerTextColor: readerTheme.uiTextColor,
            headerHorizontalPadding: readerConfig.readerHeaderHorizontalPadding,
            footerHorizontalPadding: readerConfig.readerFooterHorizontalPadding,
            headerTopOffset: readerHeaderBarOffset,
            footerBottomOffset: readerFooterBarOffset,
            bookTitle: book?.title ?? snapshotBook?.title ?? "",
            now: clock.now,
            batteryLevel: clock.batteryLevel,
            isCharging: clock.isCharging,
            readingDuration: readingStatsTracker?
                .currentMetrics(at: clock.now).elapsed ?? 0,
            // The reader's own surface, not the app's colour scheme: a night
            // reading theme under a light system appearance still needs the dark
            // resolution of a dynamic tip colour.
            userInterfaceStyle: readerTheme == .night ? .dark : .light,
            displayScale: readerDisplayScale,
            sideSafeArea: readerSideSafeArea,
            bakesBarsIntoPages: usesPageBakedBars
        )
    }

    /// What the bars say on one specific page.
    ///
    /// This is what the screen-fixed overlay could never do: it asked
    /// `readerOverlayContentSnapshot`, which is hardcoded to the *current* page, so
    /// every page on screen during a turn showed the same chapter and page number.
    func pageBarsContent(forGlobalPage globalPage: Int) -> ReaderPageBarsPageContent? {
        guard let engine = epubRenderer.engine, usesCoreTextEPUB, engine.totalPages > 0 else {
            return nil
        }
        let clamped = max(0, min(globalPage, engine.totalPages - 1))
        let position = engine.charOffset(forPage: clamped)
        let pagination = engine.chapterPagination(
            forSpine: position.spineIndex,
            charOffset: position.charOffset
        )
        let chapterTitle = tocChapter(
            forSpineIndex: position.spineIndex,
            charOffset: position.charOffset
        )?.title.converted(to: settings.textConversion) ?? book?.title ?? ""

        let pace = readingStatsTracker?.currentPaceMetrics(at: readerOverlayClock.now)
            ?? (elapsed: 0, contentUnitsRead: 0)
        let remainingUnits = readerContentMetrics(
            for: CoreTextReadingPosition(
                spineIndex: position.spineIndex,
                charOffset: position.charOffset
            ),
            engine: engine
        )?.remainingUnitCount

        return ReaderPageBarsPageContent(
            chapterTitle: chapterTitle,
            chapterPage: pagination.map { $0.localPageIndex + 1 } ?? 0,
            chapterPageCount: pagination?.displayPageCount ?? 0,
            totalProgress: engine.totalProgress(
                forSpine: position.spineIndex,
                charOffset: position.charOffset
            ),
            estimatedRemainingTime: ReaderRemainingTimeEstimator.estimate(
                elapsed: pace.elapsed,
                contentUnitsRead: pace.contentUnitsRead,
                remainingContentUnits: remainingUnits
            ),
            // Measured the same way the toggle measures the page it is on, so the
            // ribbon and the top bar's bookmark button can never disagree.
            isBookmarked: !ReaderPageBookmarkRange.page(
                startingAt: CoreTextReadingPosition(
                    spineIndex: position.spineIndex,
                    charOffset: position.charOffset
                ),
                in: engine
            ).pageBookmarks(in: book?.bookmarks ?? []).isEmpty
        )
    }

    /// Where every page bookmark sits. Changes whenever one is added or removed,
    /// whichever way — top bar, touch zone, pull-down, the list, a sync — and that
    /// is the moment the pages on screen have to hang or drop their ribbon.
    var pageBookmarkPositions: [CoreTextReadingPosition] {
        (book?.bookmarks ?? []).filter { $0.kind == .bookmark }.map(\.position)
    }

    /// Hands the engine a closure it can ask for any page's bars.
    ///
    /// Captures the controller, not `self`: the engine stores this closure for the
    /// life of the reader and may call it during a snapshot render, and routing
    /// every page through one object is what keeps the battery cache and the
    /// asset store single.
    func bindPageBarsProvider() {
        let controller = pageBarsController
        epubRenderer.pageBarsProvider = { [weak controller] page in
            MainActor.assumeIsolated { controller?.bars(forGlobalPage: page) }
        }
        controller.onNeedsRedraw = {
            NotificationCenter.default.post(name: .readerPageBarsNeedRedraw, object: nil)
        }
        refreshPageBars()
    }

    /// Re-reads every input and tells the pages already on screen.
    ///
    /// The `pageContent` closure captures `self`. `@State` and `@ObservedObject`
    /// read through shared storage so a captured copy still sees live values, but
    /// `@Environment` values are resolved per body and would go stale — which is
    /// why this is called again on every change to `readerPageBarsEnvironment`.
    func refreshPageBars() {
        pageBarsController.update(
            environment: readerPageBarsEnvironment,
            svgAssetStore: readerOverlaySVGAssetStore,
            pageContent: { page in
                MainActor.assumeIsolated { pageBarsContent(forGlobalPage: page) }
            }
        )
        guard pagesCarryBarsChannel else { return }
        (epubRenderer.engine as? PageBarsProviding)?.refreshPageBars()
        pageBarsRevision &+= 1
    }

    /// One bar for the *current* position, for the modes that keep a fixed overlay.
    func readerBarModel(
        for bar: ReaderBar,
        clock: ReaderOverlayClockSnapshot
    ) -> ReaderBarRenderModel {
        pageBarsController.model(
            for: bar,
            snapshot: readerOverlayContentSnapshot(clock: clock),
            environment: readerPageBarsEnvironment(clock: clock)
        )
    }

    /// Takes the clock forward one tick.
    ///
    /// The bars layer owns the model and redraws itself; this stores the readings
    /// where the rest of the reader looks them up and rebuilds the page-baked bars,
    /// which no view of theirs would otherwise notice. In scroll and fixed-layout
    /// mode `refreshPageBars` stops before touching any `@State`, so a tick costs
    /// nothing outside the bars.
    func applyClockTick(_ snapshot: ReaderOverlayClockSnapshot) {
        pageBarsController.clock = snapshot
        refreshPageBars()
    }
}

extension Notification.Name {
    /// An imported battery finished rasterizing; pages that drew the system
    /// fallback should be redrawn.
    static let readerPageBarsNeedRedraw = Notification.Name("ReaderPageBarsNeedRedraw")
}
