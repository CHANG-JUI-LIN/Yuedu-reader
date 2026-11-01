import UIKit
import os

/// Signposts for the paged reader's page turns, for reading an Animation Hitches
/// trace: which kind of turn a dropped frame happened in, and which main-thread
/// step it landed on.
///
/// Every turn is one interval, and its name says what started it:
///
/// - `TapTurn` — a tap zone (or a volume key) issued a command and we ran the
///   animation (`performProgrammaticTransition`). A chained catch-up turn of a tap
///   burst is a `TapTurn` too, with `chain=1`.
/// - `SwipeTurn` — UIKit's own pan drove the turn (`willTransitionTo` →
///   `didFinishAnimating`). `SwipeLift` marks the finger leaving the glass, so the
///   finger-driven part and the settle animation can be told apart.
/// - `UIKitTapTurn` — UIKit's built-in pageCurl tap recognizer turned the page,
///   not ours.
///
/// The trigger of a UIKit-driven turn is read from the state of UIKit's own
/// recognizers at the moment the turn begins, not inferred from timing.
///
/// Recorded by the os_signpost instrument under this app's subsystem, category
/// `ReaderPerformance` — the same lane as `render.page` (`ReaderPerfTrace`), which
/// nests inside these intervals wherever a page is drawn. When nothing records,
/// each call costs one `isEnabled` check. Signposts only, no AppLogger line: the
/// trace must not add log formatting to the frames it measures.
@MainActor
final class ReaderPageTurnTrace: NSObject {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zhangruilin.yuedureader",
        category: "ReaderPerformance"
    )

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    private let style: String
    private var tapSequence = 0
    /// From our tap recognizer firing to the command it produced being executed.
    /// `dispatched` turns true once `onTapZone` has run; only then may an update
    /// pass without a command close it as `noCommand`.
    private var pendingTap: (sequence: Int, interval: Interval, dispatched: Bool)?
    private var nativeTurn: Interval?
    private weak var observedPageViewController: UIPageViewController?

    init(pageTurnStyle: PageTurnStyle) {
        switch pageTurnStyle {
        case .curl: style = "curl"
        case .slide: style = "slide"
        case .cover: style = "cover"
        case .none: style = "none"
        }
    }

    private var signposter: OSSignposter { Self.signposter }
    private var isEnabled: Bool { Self.signposter.isEnabled }

    private func begin(_ name: StaticString, _ detail: @autoclosure () -> String) -> Interval? {
        guard isEnabled else { return nil }
        let detail = detail()
        let state = signposter.beginInterval(
            name,
            id: signposter.makeSignpostID(),
            "\(detail, privacy: .public)"
        )
        return Interval(name: name, state: state)
    }

    private func end(_ interval: Interval?, _ detail: @autoclosure () -> String = "") {
        guard let interval else { return }
        let detail = detail()
        signposter.endInterval(interval.name, interval.state, "\(detail, privacy: .public)")
    }

    // MARK: - Our tap zones

    func tapRecognized(_ action: TouchAction, at point: CGPoint, in size: CGSize) {
        guard isEnabled else { return }
        closePendingTap("superseded")
        tapSequence += 1
        signposter.emitEvent(
            "Tap",
            "seq=\(self.tapSequence) action=\(String(describing: action), privacy: .public) x=\(Int(point.x))/\(Int(size.width)) style=\(self.style, privacy: .public)"
        )
        guard action.readerCommand.turnsPage,
              let interval = begin("TapToCommand", "seq=\(tapSequence) style=\(style)")
        else { return }
        pendingTap = (tapSequence, interval, false)
    }

    /// `onTapZone` has run; the SwiftUI update it causes comes after this.
    func tapDispatched() {
        pendingTap?.dispatched = true
    }

    /// One `updateUIViewController` pass, from the top.
    func beginUpdatePass() -> Interval? {
        begin("PagedViewUpdate", "style=\(style)")
    }

    func endUpdatePass(_ interval: Interval?) {
        end(interval)
        // The tap's SwiftUI update has come and gone without a command (the menu
        // was up and only closed, or the turn was refused at a book edge).
        if pendingTap?.dispatched == true { closePendingTap("noCommand") }
    }

    /// A page-turn command reached the executor, and what it did with it.
    func commandExecuted(
        version: UInt,
        target: Int,
        visible: Int,
        speed: Float,
        base: Int,
        route: StaticString
    ) {
        guard isEnabled else { return }
        signposter.emitEvent(
            "TurnCommand",
            "v=\(version) route=\(String(describing: route), privacy: .public) target=\(target) base=\(base) visible=\(visible) speed=\(String(format: "%.2f", speed), privacy: .public) style=\(self.style, privacy: .public)"
        )
        closePendingTap("v=\(version) route=\(route)")
    }

    private func closePendingTap(_ outcome: String) {
        guard let pendingTap else { return }
        self.pendingTap = nil
        end(pendingTap.interval, "seq=\(pendingTap.sequence) outcome=\(outcome)")
    }

    // MARK: - Turns we animate

    func beginTapTurn(from: Int, to: Int, speed: Float, animated: Bool, chained: Bool) -> Interval? {
        begin(
            "TapTurn",
            "style=\(style) from=\(from) to=\(to) speed=\(String(format: "%.2f", speed)) animated=\(animated ? 1 : 0) chain=\(chained ? 1 : 0)"
        )
    }

    func endTapTurn(_ interval: Interval?, landed: Int?) {
        end(interval, "landed=\(landed.map(String.init) ?? "nil")")
    }

    /// Target page controller + the stack handed to UIKit (curl adds its back page).
    func beginBuild(to page: Int) -> Interval? {
        begin("TapTurn.build", "to=\(page)")
    }

    /// The synchronous call that starts the animation: `setViewControllers`, and
    /// for slide also the push's layout and commit.
    func beginStart(to page: Int) -> Interval? {
        begin("TapTurn.start", "to=\(page)")
    }

    func endStep(_ interval: Interval?) {
        end(interval)
    }

    func queueChained(visible: Int) {
        guard isEnabled else { return }
        signposter.emitEvent("QueueChain", "settled=\(visible) style=\(self.style, privacy: .public)")
    }

    /// A tap landed mid-turn and sped up the turn already on screen.
    func speedUp(to clockSpeed: Float) {
        guard isEnabled else { return }
        signposter.emitEvent("SpeedUp", "clock=\(String(format: "%.2f", clockSpeed), privacy: .public)")
    }

    // MARK: - Turns UIKit drives

    /// Watches UIKit's own turn recognizers, only to mark when the finger lifts.
    /// A second target on a recognizer never changes what it recognizes.
    func observeBuiltInGestures(of pageViewController: UIPageViewController) {
        observedPageViewController = pageViewController
        for recognizer in Self.builtInRecognizers(of: pageViewController)
        where recognizer is UIPanGestureRecognizer {
            recognizer.addTarget(self, action: #selector(builtInPanChanged(_:)))
        }
    }

    @objc private func builtInPanChanged(_ recognizer: UIPanGestureRecognizer) {
        guard isEnabled else { return }
        switch recognizer.state {
        case .began:
            signposter.emitEvent("SwipeBegan", "style=\(self.style, privacy: .public)")
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: recognizer.view).x
            signposter.emitEvent(
                "SwipeLift",
                "state=\(recognizer.state.rawValue) vx=\(Int(velocity)) style=\(self.style, privacy: .public)"
            )
        default:
            break
        }
    }

    func beginNativeTurn(on pageViewController: UIPageViewController, from page: Int?, ourAnimationRunning: Bool) {
        guard isEnabled else { return }
        end(nativeTurn, "outcome=overlapped")
        let recognizers = Self.builtInRecognizers(of: pageViewController)
        // A quick slide flick lifts the finger before UIKit starts the turn; the
        // queuing scroll view is still decelerating from it then.
        let panning = recognizers.contains {
            $0 is UIPanGestureRecognizer && ($0.state == .began || $0.state == .changed)
        } || pageViewController.view.subviews.contains {
            guard let scrollView = $0 as? UIScrollView else { return false }
            return scrollView.isDragging || scrollView.isDecelerating
        }
        // `.ended` is `.recognized`: a discrete tap is in this state while its
        // action runs, which is when UIKit starts the turn.
        let tapped = recognizers.contains { $0 is UITapGestureRecognizer && $0.state == .ended }
        let detail = "style=\(style) from=\(page.map(String.init) ?? "nil") ourAnimation=\(ourAnimationRunning ? 1 : 0)"
        if panning {
            nativeTurn = begin("SwipeTurn", detail)
        } else if tapped {
            nativeTurn = begin("UIKitTapTurn", detail)
        } else {
            nativeTurn = begin("NativeTurn", detail + " trigger=unknown")
        }
    }

    func endNativeTurn(completed: Bool, landed: Int?) {
        end(nativeTurn, "completed=\(completed ? 1 : 0) landed=\(landed.map(String.init) ?? "nil")")
        nativeTurn = nil
    }

    private static func builtInRecognizers(of pageViewController: UIPageViewController) -> [UIGestureRecognizer] {
        // Curl puts its pan and tap on the page view controller; slide's pan
        // belongs to the queuing scroll view inside it.
        pageViewController.gestureRecognizers
            + pageViewController.view.subviews.compactMap { ($0 as? UIScrollView)?.panGestureRecognizer }
    }

    // MARK: - Work that can land inside a turn

    func beginNeighbour(_ side: StaticString) -> Interval? {
        begin("Neighbour", "side=\(side) style=\(style)")
    }

    func endNeighbour(_ interval: Interval?, _ viewController: UIViewController?) {
        end(interval, "result=\(Self.kind(of: viewController))")
    }

    func beginCurlBack(page: Int) -> Interval? {
        begin("CurlBack", "page=\(page)")
    }

    func endCurlBack(_ interval: Interval?, hasImage: Bool) {
        end(interval, "image=\(hasImage ? 1 : 0)")
    }

    func beginStackWrite(_ viewController: UIViewController) -> Interval? {
        begin("StackWrite", "page=\(Self.kind(of: viewController))")
    }

    func beginPublish(page: Int, changed: Bool) -> Interval? {
        begin("PublishPage", "page=\(page) changed=\(changed ? 1 : 0)")
    }

    func beginChapterReady(spine: Int?) -> Interval? {
        begin("ChapterReady", "spine=\(spine.map(String.init) ?? "all")")
    }

    func beginWarmUp(page: Int) -> Interval? {
        begin("WarmUpNext", "page=\(page)")
    }

    private static func kind(of viewController: UIViewController?) -> String {
        guard let viewController else { return "nil" }
        switch viewController {
        case is PageBackViewController: return "back"
        case is PlaceholderPageViewController: return "placeholder"
        case let page as any PageIndexProviding & UIViewController: return "\(page.globalPageIndex)"
        default: return String(describing: type(of: viewController))
        }
    }
}
