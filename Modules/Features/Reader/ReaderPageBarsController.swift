import SwiftUI
import UIKit

/// What a bar shows that changes from page to page.
struct ReaderPageBarsPageContent: Equatable {
    var chapterTitle: String
    var chapterPage: Int
    var chapterPageCount: Int
    var totalProgress: Double
    var estimatedRemainingTime: TimeInterval?
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
        guard visibility.showsHeader || visibility.showsFooter else { return nil }

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
            header: visibility.showsHeader
                ? model(for: .header, snapshot: snapshot, environment: environment)
                : nil,
            footer: visibility.showsFooter
                ? model(for: .footer, snapshot: snapshot, environment: environment)
                : nil,
            headerTopOffset: environment.headerTopOffset,
            footerBottomOffset: environment.footerBottomOffset
        )
    }

    /// Also the scroll-mode overlay's and the settings preview's route to a bar,
    /// so every bar in the app is built and drawn by exactly one thing.
    func model(
        for bar: ReaderBar,
        snapshot: ReaderOverlayContentSnapshot,
        environment: ReaderPageBarsEnvironment
    ) -> ReaderBarRenderModel {
        builder.model(
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
    }
}
