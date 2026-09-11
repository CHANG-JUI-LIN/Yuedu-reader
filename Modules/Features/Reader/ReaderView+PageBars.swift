import SwiftUI
import UIKit
import YueduCoreText

// MARK: - Per-page 頁眉／頁腳 (paged mode)

extension ReaderView {

    /// True when the bars are drawn *into* the page rather than over the screen.
    ///
    /// Only the CoreText paged renderer can do it: the bars go in through
    /// `CoreTextPageView.renderPage`, which is also what bakes curl back-pages and
    /// cover-transition snapshots, so they follow the page through every turn
    /// animation. Scroll mode keeps a fixed overlay by design (the content scrolls
    /// under a stationary band), and fixed-layout pages are images with no
    /// CoreText surface to draw into.
    var usesPageBakedBars: Bool {
        !effectiveScrollMode && !usesFixedLayoutRenderer && usesCoreTextEPUB
    }

    var readerPageBarsEnvironment: ReaderPageBarsEnvironment {
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
            now: readerOverlayClock.now,
            batteryLevel: readerOverlayClock.batteryLevel,
            isCharging: readerOverlayClock.isCharging,
            readingDuration: readingStatsTracker?
                .currentMetrics(at: readerOverlayClock.now).elapsed ?? 0,
            // The reader's own surface, not the app's colour scheme: a night
            // reading theme under a light system appearance still needs the dark
            // resolution of a dynamic tip colour.
            userInterfaceStyle: readerTheme == .night ? .dark : .light,
            displayScale: readerDisplayScale
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
        )?.title ?? book?.title ?? ""

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
            )
        )
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
        guard usesPageBakedBars else { return }
        (epubRenderer.engine as? PageBarsProviding)?.refreshPageBars()
        pageBarsRevision &+= 1
    }

    /// One bar for the *current* position, for the modes that keep a fixed overlay.
    func readerBarModel(
        for bar: ReaderBar,
        content: ReaderOverlayContentSnapshot
    ) -> ReaderBarRenderModel {
        pageBarsController.model(
            for: bar,
            snapshot: content,
            environment: readerPageBarsEnvironment
        )
    }
}

extension Notification.Name {
    /// An imported battery finished rasterizing; pages that drew the system
    /// fallback should be redrawn.
    static let readerPageBarsNeedRedraw = Notification.Name("ReaderPageBarsNeedRedraw")
}
