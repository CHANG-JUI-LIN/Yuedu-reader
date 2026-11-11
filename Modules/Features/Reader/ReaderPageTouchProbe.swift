import UIKit

/// FB-173 diagnostic: names what took a touch that the scroll-mode page never answered.
///
/// The report (3.0.1 (148), an online book, iOS 27.2): after a theme or layout change at the
/// top of a chapter, the page took no taps and no drags while every menu button still worked,
/// until the book was closed and opened again. The device log shows the state — each refresh
/// at a chapter top resets the window to the chapter's start and puts a short previous
/// chapter back in front of it, then no scroll is committed for over a minute — but that state,
/// built on a 27.2 simulator three ways, answered every touch (2026-11-11). What the log cannot
/// say is where the touches went. This records it.
///
/// A recognizer on the window that sees each touch first and steps aside at once: it fails in
/// `touchesBegan`, prevents nothing and nothing waits for it, so it cannot change what a touch
/// does. A touch counts when it lands on the page (it collected one of the page's recognizers),
/// or, without that, lands on the page in the band of the window where no reader bar sits.
/// If the page's pan, tap or long press then never starts, one `⟐ pageTouch unanswered` line
/// goes to the log when the next touch begins or the page leaves the screen: the view chain
/// under the finger, every recognizer the touch collected, any ancestor that switched the page
/// off, the page's pan, tap and long press, and the page's own state. Nothing of the book's
/// text is in it. The whole line reaches 診斷與回報's export; Console cuts os_log lines past
/// about 1 KB, so read it there, not in Console.
///
/// Delete this file, and its call sites in `CoreTextCollectionScrollViewController` (the
/// `pageTouchProbe` property and what touches it), once FB-173's cause is found and fixed.
@MainActor
final class ReaderPageTouchProbe: UIGestureRecognizer {
    /// The part of the window, top to bottom, that a touch must land in to count when it never
    /// reached the page. The reader's bars and the toolbar sit above and below it; anything
    /// presented over the reader is excluded separately.
    static let barFreeBand: ClosedRange<CGFloat> = 0.2...0.75

    private struct Answering {
        weak var recognizer: UIGestureRecognizer?
    }

    private weak var page: UIScrollView?
    private let answering: [Answering]
    private weak var owner: UIViewController?
    private let describePage: @MainActor () -> String
    private var ledger = ReaderPageTouchLedger()

    /// - Parameters:
    ///   - page: the scroll view whose touches are watched.
    ///   - answering: the page's recognizers that answer a touch — its pan, its tap, its long
    ///     press. A touch is answered when a continuous one begins or a discrete one is
    ///     recognized.
    ///   - owner: the page's view controller; while it has something presented, touches are
    ///     that presentation's and do not count.
    ///   - describePage: the page's own state, for the log line.
    init(
        page: UIScrollView,
        answering: [UIGestureRecognizer],
        owner: UIViewController,
        describePage: @escaping @MainActor () -> String
    ) {
        self.page = page
        self.answering = answering.map { Answering(recognizer: $0) }
        self.owner = owner
        self.describePage = describePage
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        for recognizer in answering {
            recognizer.addTarget(self, action: #selector(answeringRecognizerChanged(_:)))
        }
    }

    /// Watches `window` while the page is on screen there.
    func install(on window: UIWindow?) {
        guard let window, view !== window else { return }
        view?.removeGestureRecognizer(self)
        window.addGestureRecognizer(self)
    }

    /// Stops watching. The touch still open is judged now: the page is leaving.
    func uninstall() {
        if let report = ledger.close() { Self.log(report) }
        view?.removeGestureRecognizer(self)
    }

    /// The page started a pan or a long press, or recognized a tap: the open touch was answered.
    @objc private func answeringRecognizerChanged(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .ended else { return }
        ledger.pageAnswered()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Steps aside before anything else: this recognizer only looks.
        state = .failed
        if let report = ledger.begin(touches.first.flatMap(record)) { Self.log(report) }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    /// The line for `touch` if it counts; nil if it is none of the page's business.
    private func record(_ touch: UITouch) -> String? {
        guard let page, let window = page.window, touch.window === window,
              owner?.presentedViewController == nil else { return nil }
        let reached = touch.gestureRecognizers?.contains { $0.view === page } ?? false
        let point = touch.location(in: window)
        if !reached {
            guard Self.counts(unreachedAt: point, in: window.bounds.size),
                  page.bounds.contains(touch.location(in: page)) else { return nil }
        }
        let others = (touch.gestureRecognizers ?? []).filter { $0 !== self }
        return "⟐ pageTouch unanswered reached=\(reached ? "yes" : "no")"
            + " at=(\(Int(point.x)),\(Int(point.y)))"
            + " hit=\(Self.chain(from: touch.view))"
            + " recognizers=\(Self.describe(others))"
            + " page=[\(Self.describe(page)) ancestors=\(Self.switchedOffAncestors(of: page))"
            + " own=\(Self.describe(answering.compactMap(\.recognizer))) \(describePage())]"
    }

    /// Whether a touch that never reached the page still counts: it landed where no reader bar
    /// sits, so the page was the only thing there to answer it.
    static func counts(unreachedAt point: CGPoint, in windowSize: CGSize) -> Bool {
        guard windowSize.height > 0 else { return false }
        return barFreeBand.contains(point.y / windowSize.height)
    }

    private static func log(_ line: String) {
        AppLogger.render(line, level: .notice)
    }

    private static func chain(from view: UIView?) -> String {
        var parts: [String] = []
        var current = view
        while let view = current, parts.count < 10 {
            parts.append(describe(view))
            current = view.superview
        }
        return parts.isEmpty ? "none" : parts.joined(separator: " < ")
    }

    /// Every ancestor of the page that takes it out of hit-testing, or "ok".
    private static func switchedOffAncestors(of page: UIView) -> String {
        var off: [String] = []
        var current = page.superview
        while let view = current {
            if !view.isUserInteractionEnabled || view.isHidden || view.alpha < 0.01 {
                off.append(describe(view))
            }
            current = view.superview
        }
        return off.isEmpty ? "ok" : off.joined(separator: " < ")
    }

    private static func describe(_ view: UIView) -> String {
        let flags = (view.isUserInteractionEnabled ? "" : "[noUI]")
            + (view.isHidden ? "[hidden]" : "")
            + (view.alpha < 0.01 ? "[a0]" : "")
        let frame = view.frame
        return "\(typeName(view))\(flags)@\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
    }

    private static func describe(_ recognizers: [UIGestureRecognizer]) -> String {
        let limit = 12
        let shown = recognizers.prefix(limit).map { recognizer in
            "\(typeName(recognizer))(\(recognizer.state.rawValue)\(recognizer.isEnabled ? "" : ",off")"
                + "@\(recognizer.view.map { typeName($0) } ?? "nil"))"
        }
        let more = recognizers.count > limit ? " | +\(recognizers.count - limit)" : ""
        return "[" + shown.joined(separator: " | ") + more + "]"
    }

    private static func typeName(_ object: AnyObject) -> String {
        String(String(describing: type(of: object)).prefix(48))
    }
}

/// `ReaderPageTouchProbe`'s bookkeeping, apart from UIKit so it can be tested. One touch is
/// held open at a time and reported only if the page never answered it, and a page reports at
/// most `budget` of them: a frozen page is tapped over and over, the first lines say all there
/// is, and the exported log keeps only its newest 6000 entries.
struct ReaderPageTouchLedger {
    static let budget = 30

    private(set) var reportedCount = 0
    private var open: String?
    private var answered = false

    /// A touch began; `line` is its record, or nil when it does not count. Whatever the
    /// previous touch left unanswered comes back to be logged.
    mutating func begin(_ line: String?) -> String? {
        let report = close()
        open = line
        return report
    }

    mutating func pageAnswered() {
        answered = true
    }

    /// Ends the open touch: its line, if the page never answered it and the budget has room.
    mutating func close() -> String? {
        let line = open
        let wasAnswered = answered
        open = nil
        answered = false
        guard let line, !wasAnswered, reportedCount < Self.budget else { return nil }
        reportedCount += 1
        return line
    }
}
