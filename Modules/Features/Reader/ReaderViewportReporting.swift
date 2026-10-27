import SwiftUI

/// What "the reader's viewport" means: the whole window the reader is shown in, safe areas
/// included. That is the quantity `UIScreen.main.bounds` used to stand in for, the page and
/// scroll surfaces draw under the system bars, and the engines subtract the bars' insets
/// themselves — so it is the window, not the safe-area rectangle SwiftUI proposes to content.
enum ReaderViewportMetrics {
    /// `proxy.size` is the safe-area rectangle; adding the insets back gives the window, and the
    /// sum stays put when an inset comes and goes (the status bar hiding, the window-control
    /// pill of a windowed iPad).
    static func windowSize(containerSize: CGSize, safeAreaInsets: EdgeInsets) -> CGSize {
        CGSize(
            width: containerSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: containerSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
    }
}

extension View {
    /// Reports the reader's own window size every time it changes: opening in a window that is
    /// not the screen, a Split View or Stage Manager resize, a fold, a rotation.
    ///
    /// Attach it at the root of the reader, outside its `NavigationStack`: from inside, the
    /// first passes report the content area under the navigation bar (`{20, 63}`, then
    /// `{375, 689}` for a 375×815 window), never the window.
    ///
    /// This replaces a `GeometryReader` + `PreferenceKey` + `onPreferenceChange` chain, which was
    /// measured on an iPad window to deliver the first value (`{0, 0}`) and then nothing —
    /// neither the real size at open nor any later resize — which is why the reader kept laying
    /// out for the screen. The callback runs in the layout update, so it must stay an event
    /// handler: read no UIKit window geometry in it (see `ReaderView+Footer`).
    func reportsReaderViewport(_ action: @escaping (CGSize) -> Void) -> some View {
        onGeometryChange(for: CGSize.self) { proxy in
            ReaderViewportMetrics.windowSize(
                containerSize: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets
            )
        } action: { size in
            action(size)
        }
    }

    /// Reports what the window keeps the reader clear of — its side safe areas, and on iOS 27.1
    /// what covers or folds the screen — every time it changes. Attached beside
    /// `reportsReaderViewport`, for the same reason: only there are the insets the window's.
    func reportsReaderWindowObstructions(
        _ action: @escaping (ReaderWindowObstructions) -> Void
    ) -> some View {
        modifier(ReaderWindowObstructionsReporter(action: action))
    }
}

/// A left and a right inset, in screen terms. The reader's surfaces are UIKit views laid out
/// left to right, so their margins are screen sides, where SwiftUI reports leading and trailing.
struct ReaderSideInsets: Equatable {
    var left: CGFloat
    var right: CGFloat

    static let zero = ReaderSideInsets(left: 0, right: 0)
}

/// What the reader's text and bars stay clear of, in window coordinates.
///
/// The side safe area is drawn conservatively: a folded iPhone Duo reports 84pt down its whole
/// right side, though the camera housing it is for covers only the top 82pt of it (measured on
/// iOS 27.1, 2026-10-27). Where the system also reports that housing (iOS 27.1), anything
/// running past it — the text, the 頁腳 — has the full width, as a page of 微信讀書 does; only
/// what sits beside it, the 頁眉, keeps clear.
struct ReaderWindowObstructions: Equatable {
    var windowWidth: CGFloat = 0
    var windowHeight: CGFloat = 0
    var sideSafeArea: ReaderSideInsets = .zero
    /// What covers the screen: a camera housing. Empty before iOS 27.1.
    var occlusions: [CGRect] = []
    /// Where the screen folds: an open iPhone Duo. Empty before iOS 27.1.
    var folds: [CGRect] = []

    static let none = ReaderWindowObstructions()

    /// A fold running down the screen: an iPhone Duo open in landscape, or stood up like a book.
    var hasVerticalFold: Bool {
        folds.contains { $0.height > $0.width }
    }

    /// The side insets for something spanning `band` (window y) across the window.
    func sideInsets(across band: ClosedRange<CGFloat>) -> ReaderSideInsets {
        ReaderSideInsets(
            left: inset(sideSafeArea.left, onLeft: true, across: band),
            right: inset(sideSafeArea.right, onLeft: false, across: band)
        )
    }

    /// The side insets for every page of a two-page spread, pages `pageWidth` wide with `gutter`
    /// between them. Every page is laid out alike, so each side clears both what the window
    /// keeps clear there and the fold: the left page ends short of it, the right page starts
    /// past it.
    func spreadPageInsets(
        across band: ClosedRange<CGFloat>,
        pageWidth: CGFloat,
        gutter: CGFloat
    ) -> ReaderSideInsets {
        var insets = sideInsets(across: band)
        for fold in folds where fold.height > fold.width {
            insets.right = max(insets.right, pageWidth - fold.minX)
            insets.left = max(insets.left, fold.maxX - (pageWidth + gutter))
        }
        return insets
    }

    /// One side's safe area, or none where it is only there for a housing that ends short of
    /// `band`. A side with no housing reported keeps its inset as it is.
    ///
    /// A housing sits in a corner: flush with this side, flush with the top or the bottom, and
    /// as wide as the inset — the folded iPhone Duo's is, held either way up. An iPhone in
    /// landscape reports its Dynamic Island halfway down the side, so it never qualifies, and
    /// nothing changes there however far its frame reaches. (The simulator runs iOS 27.1 only on
    /// the iPhone Duo, so an iPhone's island could not be measured; the corner test is what
    /// keeps the rule from depending on it.)
    private func inset(_ safeArea: CGFloat, onLeft: Bool, across band: ClosedRange<CGFloat>) -> CGFloat {
        guard safeArea > 0 else { return 0 }
        let onThisSide = occlusions.filter { onLeft == ($0.midX < windowWidth / 2) }
        let tolerance: CGFloat = 0.5
        let isHousing: (CGRect) -> Bool = { rect in
            let spansInset = onLeft
                ? rect.minX <= tolerance && rect.maxX >= safeArea - tolerance
                : rect.maxX >= windowWidth - tolerance && rect.minX <= windowWidth - safeArea + tolerance
            let inCorner = rect.minY <= tolerance || rect.maxY >= windowHeight - tolerance
            return spansInset && inCorner
        }
        guard onThisSide.contains(where: isHousing),
              !onThisSide.contains(where: { $0.minY < band.upperBound && $0.maxY > band.lowerBound })
        else { return safeArea }
        return 0
    }
}

private struct ReaderWindowObstructionsReporter: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    let action: (ReaderWindowObstructions) -> Void

    func body(content: Content) -> some View {
        let isRightToLeft = layoutDirection == .rightToLeft
        content.onGeometryChange(for: ReaderWindowObstructions.self) { proxy in
            let insets = proxy.safeAreaInsets
            let window = ReaderViewportMetrics.windowSize(containerSize: proxy.size, safeAreaInsets: insets)
            var obstructions = ReaderWindowObstructions(
                windowWidth: window.width,
                windowHeight: window.height,
                sideSafeArea: isRightToLeft
                    ? ReaderSideInsets(left: insets.trailing, right: insets.leading)
                    : ReaderSideInsets(left: insets.leading, right: insets.trailing)
            )
            if #available(iOS 27.1, *) {
                // In the proxy's own space, which starts where the safe area does; the
                // reader's surfaces draw from the window's corner.
                let origin = proxy.frame(in: .global).origin
                let toWindow = { (region: ReservedRegion) in
                    region.frame.offsetBy(dx: origin.x, dy: origin.y)
                }
                obstructions.occlusions = proxy
                    .reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
                    .map(toWindow)
                // Inactive too: the fold is there whether or not the device is bent at it.
                obstructions.folds = proxy
                    .reservedRegions(kind: .division, options: .includeInactive, layoutDirectionBehavior: .fixed)
                    .map(toWindow)
            }
            return obstructions
        } action: { obstructions in
            action(obstructions)
        }
    }
}
