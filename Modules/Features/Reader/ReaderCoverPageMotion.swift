import UIKit

enum ReaderCoverTurnDirection: Equatable {
    case forward
    case backward
}

struct ReaderCoverPageMotion: Equatable {
    let direction: ReaderCoverTurnDirection
    let isRTL: Bool

    static func direction(for translationX: CGFloat, threshold: CGFloat, isRTL: Bool) -> ReaderCoverTurnDirection? {
        if isRTL {
            if translationX > threshold { return .forward }
            if translationX < -threshold { return .backward }
        } else {
            if translationX < -threshold { return .forward }
            if translationX > threshold { return .backward }
        }
        return nil
    }

    func initialX(width: CGFloat) -> CGFloat {
        switch direction {
        case .forward:
            return 0
        case .backward:
            return offscreenX(width: width)
        }
    }

    func interactiveX(progress: CGFloat, width: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 0.999)
        let offscreen = offscreenX(width: width)
        switch direction {
        case .forward:
            return offscreen * clamped
        case .backward:
            return offscreen * (1 - clamped)
        }
    }

    /// Share of the page width a slow release must have covered to turn the page.
    static let commitProgressRatio: CGFloat = 0.34
    /// Horizontal speed (points/second) that decides a release on its own: a
    /// flick the way the page is turning commits it, a flick back cancels it.
    static let commitVelocityThreshold: CGFloat = 560

    /// `value` measured along the way this turn travels: positive is further into
    /// the turn, negative is back towards where the drag started.
    private func alongTurn(_ value: CGFloat) -> CGFloat {
        let turnsLeftwards = (direction == .forward) != isRTL
        return turnsLeftwards ? -value : value
    }

    /// How far into the turn the finger has dragged the page, 0...1. Dragging back
    /// past where the gesture started is 0, not progress: until 2026-09-30 this
    /// was the bare distance from the start, so a page dragged back through its
    /// starting point began turning again in the same direction.
    func dragProgress(translationX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(alongTurn(translationX) / max(width, 1), 0), 1)
    }

    /// Whether letting go turns the page. Velocity used to count in either
    /// direction, so a page flicked back the way it came turned anyway.
    func shouldCommit(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) -> Bool {
        let velocity = alongTurn(velocityX)
        if velocity > Self.commitVelocityThreshold { return true }
        if velocity < -Self.commitVelocityThreshold { return false }
        return dragProgress(translationX: translationX, width: width) > Self.commitProgressRatio
    }

    func settledX(width: CGFloat, shouldCommit: Bool) -> CGFloat {
        switch direction {
        case .forward:
            return shouldCommit ? offscreenX(width: width) : 0
        case .backward:
            return shouldCommit ? 0 : offscreenX(width: width)
        }
    }

    /// How long the page takes to come to rest after the finger lets go. UIKit's
    /// spring for a given duration is stiffer than an ease-out of the same length:
    /// the 0.22s ease-out this replaced covered two thirds of the way in its
    /// first 0.1s, a 0.22s spring nine tenths. At 0.27s it covers about four
    /// fifths — still a little brisker than the ease-out from a standstill.
    static let settleDuration: TimeInterval = 0.27

    /// Ceiling on `settleSpringVelocity`. UIKit's critically damped spring for
    /// `settleDuration` overshoots its target once the initial velocity passes the
    /// spring's own natural frequency — the page would slide past its resting edge
    /// and show what is behind it. `coverSettleSpringNeverOvershoots` measures that
    /// frequency and holds this below it (measured 2026-09-30 on iOS 27: 39.3 for
    /// 0.22s, 31.7 for 0.27s, 16.2 for 0.30s).
    static let maxSettleSpringVelocity: CGFloat = 16

    /// The released page's speed, in the unit UIKit's spring API takes: remaining
    /// distances per second. Handing the spring the finger's velocity is what lets
    /// the page carry on at the speed it was let go at instead of jumping to the
    /// curve's own. A finger moving away from where the page will rest contributes
    /// nothing — the page turns round from a standstill.
    static func settleSpringVelocity(
        currentX: CGFloat,
        destinationX: CGFloat,
        velocityX: CGFloat
    ) -> CGFloat {
        let remaining = destinationX - currentX
        guard abs(remaining) >= 1 else { return 0 }
        return min(max(velocityX / remaining, 0), maxSettleSpringVelocity)
    }

    var movingEdgeCorners: CACornerMask {
        isRTL
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }

    var shadowOffset: CGSize {
        let ltrOffset: CGFloat = direction == .forward ? 10 : -10
        return CGSize(width: isRTL ? -ltrOffset : ltrOffset, height: 0)
    }

    private func offscreenX(width: CGFloat) -> CGFloat {
        (isRTL ? 1 : -1) * max(width, 1)
    }
}

struct PageViewControllerPagingAdapterDescriptor: Equatable {
    let style: ReaderPagingStyle
    let transitionStyle: UIPageViewController.TransitionStyle
    let disablesBuiltInSwipe: Bool
    let usesCoverOverlay: Bool
    let usesInstantPan: Bool
    let isDoubleSided: Bool

    init(pageTurnStyle: PageTurnStyle) {
        style = ReaderPagingStyle(pageTurnStyle: pageTurnStyle)
        isDoubleSided = pageTurnStyle == .curl
        switch pageTurnStyle {
        case .curl:
            transitionStyle = .pageCurl
            disablesBuiltInSwipe = false
            usesCoverOverlay = false
            usesInstantPan = false
        case .slide:
            transitionStyle = .scroll
            disablesBuiltInSwipe = false
            usesCoverOverlay = false
            usesInstantPan = false
        case .cover:
            transitionStyle = .scroll
            disablesBuiltInSwipe = true
            usesCoverOverlay = true
            usesInstantPan = false
        case .none:
            transitionStyle = .scroll
            disablesBuiltInSwipe = true
            usesCoverOverlay = false
            usesInstantPan = true
        }
    }

    func spineLocation(isRTL: Bool) -> UIPageViewController.SpineLocation {
        isRTL && (style == .curl || style == .cover) ? .max : .min
    }

    /// Switches off the tap-to-turn recognizer UIKit gives a page-curl controller.
    ///
    /// Every tapped turn here is ours — `Coordinator.handleTap` and the reader's
    /// own, remappable tap zones — so UIKit's recognizer never turned a page: none
    /// of 83 taps on a 2026-10-05 device trace. Deciding not to still cost a curl
    /// back-page render on the main thread for 58 of them (~20ms each), because
    /// `_gestureRecognizerShouldBegin:` asks the data source for the incoming pages,
    /// and in a tap burst that render lands inside the running curl.
    @MainActor
    func disableBuiltInTapToTurn(on pageViewController: UIPageViewController) {
        guard transitionStyle == .pageCurl else { return }
        for recognizer in pageViewController.gestureRecognizers
        where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
    }
}

/// Which animation engine plays a programmatic slide turn, and how.
///
/// Every tap, volume-key and queued slide turn runs as our own push transition;
/// only interactive swipes keep UIKit's `.scroll` transition. UIKit's programmatic
/// turn can be neither shortened nor cut short: `_UIQueuingScrollView` walks its
/// content offset on the main thread off a display link, which `layer.speed` does
/// not scale, so a second tap has to wait out the first turn in full. A push is a
/// render-server animation with a duration we own.
///
/// The push reproduces UIKit's own turn — duration and curve below — so a lone
/// tap still moves exactly like the page a swipe settles. It used to read as a
/// different, rougher animation because iPhone capped it at 60Hz while UIKit's
/// scrolling ran at 120Hz. `CADisableMinimumFrameDurationOnPhone` in Info.plist
/// plus `frameRateRange` were meant to lift that cap, but a device trace on
/// 2026-10-05 still measured the push at 60Hz with both in place;
/// `ReaderTurnFrameRateRequest` asks for the rate while the turn runs.
enum ReaderSlideTurnAnimation {
    /// UIKit's programmatic `.scroll` turn, sampled frame by frame (2026-09-26,
    /// iOS 27 simulator): 0.30s, progress (1 − cos πt) / 2.
    static let nativeDuration: CFTimeInterval = 0.3
    /// Apple's range for a fast, full-screen movement. On iPhone, Core Animation
    /// ignores anything above 60Hz unless Info.plist carries
    /// `CADisableMinimumFrameDurationOnPhone`.
    static let frameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    static func runsTimedPush(pageTurnStyle: PageTurnStyle, animated: Bool) -> Bool {
        animated && pageTurnStyle == .slide
    }

    /// - Parameter speed: the tap-burst speed-up; 1 plays UIKit's own pace.
    static func pushTransition(
        direction: UIPageViewController.NavigationDirection,
        speed: Float
    ) -> CATransition {
        let transition = CATransition()
        transition.type = .push
        // `direction` already carries the RTL swap, so it maps straight to the
        // edge the incoming page enters from.
        transition.subtype = direction == .forward ? .fromRight : .fromLeft
        transition.duration = nativeDuration / Double(max(speed, 1))
        // Least-squares Bézier fit to UIKit's sine curve: within 0.08% of a page
        // at every sampled frame.
        transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.365, 0, 0.635, 1)
        transition.preferredFrameRateRange = frameRateRange
        return transition
    }
}

enum ReaderCurlVirtualIndex {
    static func frontIndex(forGlobalPage page: Int, isRTL: Bool) -> Int {
        let base = max(0, page) * 2
        return isRTL ? base + 1 : base
    }

    static func backIndex(forLogicalPage page: Int, isRTL: Bool) -> Int {
        let base = max(0, page) * 2
        return isRTL ? base : base + 1
    }
}

enum ReaderCurlBackPageResolver {
    static func logicalPageIndex(targetPage: Int, visiblePage: Int) -> Int {
        targetPage >= visiblePage ? targetPage - 1 : targetPage
    }

    static func contentPageIndex(logicalPageIndex: Int, totalPages: Int) -> Int? {
        guard logicalPageIndex >= 0, logicalPageIndex < totalPages else { return nil }
        return logicalPageIndex
    }
}
