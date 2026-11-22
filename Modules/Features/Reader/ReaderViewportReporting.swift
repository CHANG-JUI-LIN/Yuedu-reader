import SwiftUI
import UIKit

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
    /// `reportsReaderViewport`, for the same reason: only there does the reader's frame,
    /// stretched over its safe area, cover the window.
    /// The side safe areas are the reader's window's own; the reporter keeps `window` pointed at
    /// that window (`readerWindowProbe`), for the reader's other uses of it too.
    func reportsReaderWindowObstructions(
        in window: ReaderWindowReference,
        _ action: @escaping (ReaderWindowObstructions) -> Void
    ) -> some View {
        modifier(ReaderWindowObstructionsReporter(window: window, action: action))
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

    /// One report on its way to the page: `measured` as the page is laid out, and the report to
    /// keep as the one taken while reading. A report taken with the status bar hidden is the
    /// reading one; any other — status bar shown, or not known for that measurement (`nil`) —
    /// keeps the occlusions of the last reading one (`withOcclusions(whileReading:)`).
    ///
    /// The reader hides the status bar while reading and shows it with its menu. A folded
    /// iPhone Duo stands its status bar down the right side, under the camera, and reports the
    /// housing grown to take it in: 84×82pt hidden, 84×174pt shown (iOS 27.2 simulator,
    /// 2026-11-15). 174pt reaches the first lines of text, so every tap that opened or closed the
    /// menu took the text's 84pt right inset away or gave it back, and the whole chapter was laid
    /// out again behind a loading screen (221 pages read, 257 with the menu open). The page is
    /// laid out for reading; the status bar shown over it with the menu is part of the menu.
    ///
    /// Fallback, disclosed: with no report taken while reading for this window — a book opened
    /// from the shelf, whose first report still has the shelf's status bar, or a window resized
    /// with the menu open — these stand as measured, and the page is laid out once more when the
    /// status bar hides. Delete this once the system reports the status bar apart from the
    /// housing it stands beside.
    static func forReading(
        _ measured: ReaderWindowObstructions,
        statusBarHidden: Bool?,
        whileReading: ReaderWindowObstructions?
    ) -> (laidOut: ReaderWindowObstructions, whileReading: ReaderWindowObstructions?) {
        if statusBarHidden == true {
            if measured.occlusions.isEmpty, let whileReading, !whileReading.occlusions.isEmpty,
               measured.withOcclusions(whileReading: whileReading).occlusions == whileReading.occlusions {
                // Fallback, disclosed: a report with no occlusions at all, for the window and
                // the side safe areas a housing was just read beside, is one the system has not
                // filled in yet. A folded iPhone Duo coming back to the foreground reported its
                // 84pt side with nothing in it, and the housing in the next report (iOS 27.2
                // simulator, 2026-11-22). Standing as measured, it has no housing to free the
                // text from that side, and the text keeps 84pt clear on its right for as long as
                // no later report arrives. The side safe area is there for the housing, so one
                // cannot go without the other. Delete this once the system hands over a
                // window's occlusions together with its safe areas.
                return (measured.withOcclusions(whileReading: whileReading), whileReading)
            }
            return (measured, measured)
        }
        return (measured.withOcclusions(whileReading: whileReading), whileReading)
    }

    /// These, with the occlusions of `whileReading` in place of their own, when both were
    /// measured for the same window: the same size and the same side safe areas.
    func withOcclusions(whileReading: ReaderWindowObstructions?) -> ReaderWindowObstructions {
        guard let whileReading,
              whileReading.windowWidth == windowWidth,
              whileReading.windowHeight == windowHeight,
              whileReading.sideSafeArea == sideSafeArea
        else { return self }
        var laidOut = self
        laidOut.occlusions = whileReading.occlusions
        return laidOut
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
    /// exactly as wide as the inset, which is there for it — the folded iPhone Duo's is 84pt
    /// beside an 84pt inset, held upright or on its side, status bar shown or hidden (shown, it
    /// also runs twice as far down: `withOcclusions(whileReading:)`).
    ///
    /// An iPhone reports a 54pt band along the Dynamic Island's whole edge: across the top in
    /// portrait, where the sides have no inset, and down one side in landscape, narrower than
    /// its 62pt inset (iPhone 18 Pro Max, iOS 27.2). Neither is a housing, and a band down a
    /// whole side would keep its inset regardless, since every band meets it. Wider than the
    /// inset is no housing either: for one pass of a turn to landscape the window already has
    /// its landscape size and insets but still carries portrait's band, 440pt across the top
    /// left, which must not free the 頁腳 from the left inset.
    private func inset(_ safeArea: CGFloat, onLeft: Bool, across band: ClosedRange<CGFloat>) -> CGFloat {
        guard safeArea > 0 else { return 0 }
        let onThisSide = occlusions.filter { onLeft == ($0.midX < windowWidth / 2) }
        let tolerance: CGFloat = 0.5
        let isHousing: (CGRect) -> Bool = { rect in
            let fillsInset = onLeft
                ? rect.minX <= tolerance && abs(rect.maxX - safeArea) <= tolerance
                : rect.maxX >= windowWidth - tolerance && abs(rect.minX - (windowWidth - safeArea)) <= tolerance
            let inCorner = rect.minY <= tolerance || rect.maxY >= windowHeight - tolerance
            return fillsInset && inCorner
        }
        guard onThisSide.contains(where: isHousing),
              !onThisSide.contains(where: { $0.minY < band.upperBound && $0.maxY > band.lowerBound })
        else { return safeArea }
        return 0
    }
}

private struct ReaderWindowObstructionsReporter: ViewModifier {
    let window: ReaderWindowReference
    let action: (ReaderWindowObstructions) -> Void
    @State private var held = HeldObstructions()

    /// What SwiftUI last reported, kept while the reader's window is not known yet.
    @MainActor
    private final class HeldObstructions {
        var latest: ReaderWindowObstructions?
        var awaitsWindow = false
        /// The last report taken with the status bar hidden — what the page is laid out around —
        /// for each window it was taken in: its size and its side safe areas.
        ///
        /// One for each, not the last one alone. Going to the background, the system lays the
        /// scene out at other sizes for its snapshots: a folded iPhone Duo's 466×678pt reader was
        /// reported at 951×669pt and back, and the report that came back first had no occlusions
        /// (iOS 27.2 simulator, 2026-11-22). With the 951pt report kept in place of the 466pt one,
        /// that empty report had nothing to be read against and stood as measured: the text's
        /// 84pt right inset, until the housing was reported again. A device has a handful of
        /// such windows.
        var whileReading: [WindowKey: ReaderWindowObstructions] = [:]
    }

    /// A window as a reading report belongs to it (`ReaderWindowObstructions.withOcclusions`).
    private struct WindowKey: Hashable {
        let width: CGFloat
        let height: CGFloat
        let left: CGFloat
        let right: CGFloat

        init(_ obstructions: ReaderWindowObstructions) {
            width = obstructions.windowWidth
            height = obstructions.windowHeight
            left = obstructions.sideSafeArea.left
            right = obstructions.sideSafeArea.right
        }
    }

    func body(content: Content) -> some View {
        content
            .readerWindowProbe(window)
            .background {
                // Measured over the whole window, not over the reader, which is the safe-area
                // rectangle: SwiftUI hands a view only the reserved regions that reach its own
                // frame, and those are exactly what the safe area keeps the reader clear of. The
                // reader got none on iOS 27.2 — neither an iPhone's 54pt band across the top
                // nor the folded iPhone Duo's housing beside its 84pt inset — while this
                // rectangle gets the window's own (both simulators, 2026-11-07). It is the
                // window's, so its space is the window's too.
                Color.clear
                    .onGeometryChange(for: ReaderWindowObstructions.self) { proxy in
                        var obstructions = ReaderWindowObstructions(
                            windowWidth: proxy.size.width,
                            windowHeight: proxy.size.height
                        )
                        if #available(iOS 27.1, *) {
                            obstructions.occlusions = proxy
                                .reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
                                .map(\.frame)
                            // Inactive too: the fold is there whether or not the device is bent at it.
                            obstructions.folds = proxy
                                .reservedRegions(kind: .division, options: .includeInactive, layoutDirectionBehavior: .fixed)
                                .map(\.frame)
                        }
                        return obstructions
                    } action: { obstructions in
                        report(obstructions)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    /// Reports `obstructions` with the window's own side safe areas. A reader laid out in its
    /// window before the probe beside it has joined it — the first layout of one pushed inside a
    /// tab — waits for the probe: the side safe areas come from the window alone, never from
    /// SwiftUI, whose include the container's (the test host had 168pt on the right, its
    /// window's 84pt and its container's 84pt). The probe joins from inside a
    /// SwiftUI update, where the reader's state must not change, so the report goes out on the
    /// main actor once that update is over, with whatever SwiftUI reported last.
    private func report(_ obstructions: ReaderWindowObstructions) {
        held.latest = obstructions
        if let readerWindow = window.window {
            action(Self.forReading(
                Self.withSides(of: readerWindow, obstructions),
                statusBarHidden: readerWindow.windowScene?.statusBarManager?.isStatusBarHidden ?? true,
                held: held
            ))
            return
        }
        guard !held.awaitsWindow else { return }
        held.awaitsWindow = true
        let held = held
        let action = action
        window.withWindow { readerWindow in
            Task { @MainActor in
                held.awaitsWindow = false
                guard let latest = held.latest else { return }
                action(Self.forReading(
                    Self.withSides(of: readerWindow, latest),
                    statusBarHidden: nil,
                    held: held
                ))
            }
        }
    }

    /// The window's own side safe areas, in place of the ones SwiftUI hands the reader, which
    /// include whatever the reader's container reserves. A tab keeps reserving its tab bar's side
    /// after the reader has hidden it: on an open iPhone Duo held in landscape the root tab bar
    /// stands down the right side, and with it hidden the tab still reported 84pt there where
    /// the window reported none, so both pages of a spread kept 84pt clear on their right — the
    /// page by the fold as much as the page by the edge (iOS 27.1 simulator, 2026-10-27;
    /// `isTabBarHidden` was true, and a forced layout kept the 84pt). The reader covers its
    /// window, so the window's are the safe areas there are.
    ///
    /// Asked in the handler, never in the measuring closure: a SwiftUI update must not consult
    /// UIKit's window geometry (`ReaderView.effectiveReaderSafeTop`). The window's insets move
    /// only with its size or with what covers it, and both are measured: through a rotation,
    /// every report found the window's insets already matching its new size (iOS 27.2, iPhone
    /// 18 Pro Max and iPhone Duo, 2026-11-07).
    private static func withSides(
        of readerWindow: UIWindow,
        _ obstructions: ReaderWindowObstructions
    ) -> ReaderWindowObstructions {
        let insets = readerWindow.safeAreaInsets
        var obstructions = obstructions
        obstructions.sideSafeArea = ReaderSideInsets(left: insets.left, right: insets.right)
        return obstructions
    }

    /// `measured` as the page is laid out, through `ReaderWindowObstructions.forReading`, with
    /// the report kept for the next one.
    ///
    /// `statusBarHidden` is the window scene's, asked in the handler for the reason `withSides`
    /// gives, and only for a report just measured: one the deferred path hands on later was
    /// measured before the flag may have moved, so it passes `nil`. A scene without a status
    /// bar manager has no status bar to show.
    private static func forReading(
        _ measured: ReaderWindowObstructions,
        statusBarHidden: Bool?,
        held: HeldObstructions
    ) -> ReaderWindowObstructions {
        let step = ReaderWindowObstructions.forReading(
            measured,
            statusBarHidden: statusBarHidden,
            whileReading: held.whileReading[WindowKey(measured)]
        )
        if let reading = step.whileReading {
            held.whileReading[WindowKey(reading)] = reading
        }
        // What the text's side margins are decided from. A folded iPhone Duo's right margin
        // moves by 84pt with these, and only this line says which report moved it.
        AppLogger.render(
            "⟐ readerObstructions window=\(Int(measured.windowWidth))x\(Int(measured.windowHeight)) "
                + "sides=\(measured.sideSafeArea.left)/\(measured.sideSafeArea.right) "
                + "statusBarHidden=\(statusBarHidden.map(String.init) ?? "unknown") "
                + "measured=\(measured.occlusions) laidOut=\(step.laidOut.occlusions) "
                + "reading=\(step.whileReading.map { "\($0.occlusions)" } ?? "none")"
        )
        return step.laidOut
    }
}
