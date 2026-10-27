import SwiftUI
import UIKit

/// What a bar shows that changes from page to page.
struct ReaderPageBarsPageContent: Equatable {
    var chapterTitle: String
    var chapterPage: Int
    var chapterPageCount: Int
    var totalProgress: Double
    var estimatedRemainingTime: TimeInterval?
    /// One bookmark per page: this page has one, so it hangs the ribbon.
    var isBookmarked = false
}

/// What a bar shows that is the same on every page.
struct ReaderPageBarsEnvironment: Equatable {
    var layout: ReaderBarLayout
    var headerEnabled: Bool
    var footerEnabled: Bool
    var readerTextColor: UIColor
    var headerHorizontalPadding: CGFloat
    var footerHorizontalPadding: CGFloat
    /// Page top edge → header band top edge, and page bottom edge → footer band
    /// bottom edge. The same two numbers `ReaderLayoutMetrics.barContentInsets`
    /// reserves space with, so the bar and the hole it sits in cannot drift apart.
    var headerTopOffset: CGFloat
    var footerBottomOffset: CGFloat
    var bookTitle: String
    var now: Date
    var batteryLevel: Double?
    var isCharging: Bool
    var readingDuration: TimeInterval
    var userInterfaceStyle: UIUserInterfaceStyle
    var displayScale: CGFloat
    /// What each bar keeps clear of on each side before its own padding
    /// (`ReaderView.readerBarSideInsets`). Apart, because each clears only what reaches its
    /// own height: on a folded iPhone Duo the 頁眉 sits beside the camera and the 頁腳 does not.
    var headerSideInsets: ReaderSideInsets = .zero
    var footerSideInsets: ReaderSideInsets = .zero
    /// False in a two-page spread on a screen that does not fold, where the screen-fixed
    /// layer draws one pair of bars for both pages; the pages then carry only their
    /// bookmark ribbon.
    var bakesBarsIntoPages = true
}

/// Builds the 頁眉／頁腳 for any page the paged engine asks about.
///
/// A reference type on purpose. The engine holds an escaping closure for the life
/// of the reader and calls it for any page at any time, including from a snapshot
/// render. `@State` reads through a shared box so a captured `ReaderView` copy
/// would still see live values, but `@Environment` values do not — they are
/// resolved once per body — and rebuilding a bar means touching the asset store
/// and an image cache that must not be duplicated per captured copy. Keeping the
/// inputs on one object gives the bars a single refresh point instead.
@MainActor
final class ReaderPageBarsController {

    private let builder = ReaderBarRenderModelBuilder()

    /// The latest clock/battery readings, pushed by the bars layer that owns the
    /// clock.
    ///
    /// `ReaderView` reads the clock back from here instead of observing
    /// `ClockBatteryModel`: observing it made the once-a-minute tick invalidate the
    /// entire reader body. This is a plain stored property on a class SwiftUI does
    /// not track, so writing it publishes nothing.
    var clock = ReaderOverlayClockSnapshot(now: Date(), batteryLevel: nil, isCharging: false)

    private var environment: ReaderPageBarsEnvironment?
    private var svgAssetStore: ReaderOverlaySVGAssetStore?
    /// Reassigned on every `update`, so it is never stale.
    private var pageContent: ((Int) -> ReaderPageBarsPageContent?)?

    /// Fired when an imported battery finishes rasterizing and the pages that drew
    /// the system fallback need redrawing.
    var onNeedsRedraw: (() -> Void)? {
        didSet { builder.onAssetLoaded = onNeedsRedraw }
    }

    func update(
        environment: ReaderPageBarsEnvironment,
        svgAssetStore: ReaderOverlaySVGAssetStore?,
        pageContent: @escaping (Int) -> ReaderPageBarsPageContent?
    ) {
        // Called in both reading modes. Scroll mode never asks for
        // `bars(forGlobalPage:)`, but it does call `model(for:snapshot:environment:)`
        // for its fixed overlay, and that needs the same asset store and the same
        // invalidation.

        if let existing = self.environment,
           existing.readerTextColor != environment.readerTextColor
            || existing.layout.style != environment.layout.style
            || existing.userInterfaceStyle != environment.userInterfaceStyle
            || existing.displayScale != environment.displayScale {
            // Cached battery images are tinted and sized for the old style.
            builder.invalidate()
        }
        self.environment = environment
        self.svgAssetStore = svgAssetStore
        self.pageContent = pageContent
    }

    /// Drops the closures the reader installed; they capture the reader view, which holds
    /// this controller. Called when the reader leaves for good (`ReaderTeardownProbe`).
    func releaseContent() {
        pageContent = nil
        onNeedsRedraw = nil
    }

    func bars(forGlobalPage globalPage: Int) -> ReaderPageBars? {
        guard let environment,
              let content = pageContent?(globalPage)
        else { return nil }

        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: environment.layout,
            headerEnabled: environment.headerEnabled,
            footerEnabled: environment.footerEnabled,
            // Now genuinely per page. The screen-fixed overlay had to answer this
            // with whatever the *current* page was and apply it to everything.
            isChapterOpeningPage: content.chapterPage == 1
        )
        // The ribbon hangs whether or not the user shows any bars: with both off, a
        // bookmarked page still gets bars — empty ones that carry only the ribbon.
        let showsHeader = environment.bakesBarsIntoPages && visibility.showsHeader
        let showsFooter = environment.bakesBarsIntoPages && visibility.showsFooter
        guard showsHeader || showsFooter || content.isBookmarked else {
            return nil
        }

        let snapshot = ReaderOverlayContentSnapshot(
            bookTitle: environment.bookTitle,
            chapterTitle: content.chapterTitle,
            chapterPage: content.chapterPage,
            chapterPageCount: content.chapterPageCount,
            totalProgress: content.totalProgress,
            now: environment.now,
            batteryLevel: environment.batteryLevel,
            isCharging: environment.isCharging,
            readingDuration: environment.readingDuration,
            estimatedRemainingTime: content.estimatedRemainingTime
        )

        return ReaderPageBars(
            header: showsHeader
                ? model(for: .header, snapshot: snapshot, environment: environment)
                : nil,
            footer: showsFooter
                ? model(for: .footer, snapshot: snapshot, environment: environment)
                : nil,
            headerTopOffset: environment.headerTopOffset,
            footerBottomOffset: environment.footerBottomOffset,
            isBookmarked: content.isBookmarked
        )
    }

    /// Also the scroll-mode overlay's and the settings preview's route to a bar,
    /// so every bar in the app is built and drawn by exactly one thing.
    func model(
        for bar: ReaderBar,
        snapshot: ReaderOverlayContentSnapshot,
        environment: ReaderPageBarsEnvironment
    ) -> ReaderBarRenderModel {
        var model = builder.model(
            for: bar,
            layout: environment.layout,
            content: snapshot,
            readerTextColor: environment.readerTextColor,
            horizontalPadding: bar == .header
                ? environment.headerHorizontalPadding
                : environment.footerHorizontalPadding,
            svgAssetStore: svgAssetStore,
            userInterfaceStyle: environment.userInterfaceStyle,
            displayScale: environment.displayScale
        )
        model.sideInsets = bar == .header ? environment.headerSideInsets : environment.footerSideInsets
        return model
    }
}
