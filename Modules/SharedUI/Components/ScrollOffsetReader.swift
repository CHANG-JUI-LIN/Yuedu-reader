import SwiftUI
import UIKit

extension View {
    /// Reports how far the scroll view this view sits in has scrolled from its top, in
    /// points: once when the view is placed, then each time the reader scrolls. With no
    /// scroll view above it, it reports 0 — the page is at its top.
    ///
    /// Put it on a view inside the scroll view's content — a grid, or a list's first row.
    /// It observes the nearest `UIScrollView` above itself, so it always measures the
    /// scroll view it is in. The navigation controller's `contentScrollView(for: .top)`
    /// would be shorter, but on iOS 17 it names 書架's group filter bar instead of its
    /// list. The same on every iOS version from 17 on.
    ///
    /// A list recycles the row this sits on once it scrolls far out of sight; the last
    /// offset reported stands until the row comes back near the top.
    func reportsScrollOffset(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollViewMeasurer(measure: .offset, onChange: action).accessibilityHidden(true))
    }

    /// Reports how tall the scroll view this view sits in has to be to show all its content
    /// without scrolling — the content and the insets around it, the safe area's among
    /// them: once when the view is placed, then each time the content's size changes. A
    /// sheet sizes itself to its list with it. Put it inside the scroll content, as
    /// `reportsScrollOffset(_:)`; with no scroll view above it, it reports nothing.
    func reportsScrollContentHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollViewMeasurer(measure: .contentHeight, onChange: action).accessibilityHidden(true))
    }

    /// Calls `action` as the reader starts dragging the scroll view this view sits in — a
    /// scroll, a fling or a pull to refresh, never a scroll the app or the system makes.
    /// SwiftUI reports a scroll view's phase only from iOS 18, so this listens to the scroll
    /// view's own pan recognizer, as an added target that never competes with the scroll.
    /// Put it inside the scroll content, as `reportsScrollOffset(_:)`.
    func onScrollDragBegan(_ action: @escaping () -> Void) -> some View {
        background(ScrollDragObserver(onBegan: action).accessibilityHidden(true))
    }

    /// While `pins` holds, keeps the scroll view this view sits in at the end of its content:
    /// through each change of the content's size — frame by frame while SwiftUI animates it,
    /// which `ScrollViewProxy.scrollTo` and `defaultScrollAnchor(_:for: .sizeChanges)` both
    /// skip, jumping to the final size's end while the content still has the first one — and
    /// of `bottomInset`, the safe area left by the bars under the scroll view. While a change
    /// of `morph` animates, the page travels to the end along the morph's curve, from as far
    /// from it as it was, and is held on that way through every move of the offset: SwiftUI
    /// moves it as it lays the animated content out. After that, a move of the offset that
    /// neither the content nor the bars made — a scroll of any kind: a drag, VoiceOver's, the
    /// status bar's — takes the page off its end for good: `scrolledAway` is called, and
    /// nothing more is followed until `pins` is set again. Put it inside the scroll content,
    /// as `reportsScrollOffset(_:)`.
    func pinsScrollToEnd(_ pins: Bool, through morph: Bool, bottomInset: CGFloat,
                         scrolledAway: @escaping () -> Void) -> some View {
        modifier(ScrollEndPinning(pins: pins, progress: morph ? 1 : 0, target: morph ? 1 : 0, bottomInset: bottomInset,
                                  scrolledAway: scrolledAway))
    }
}

/// `morph` as a number that animates with it, so the pin knows on every frame how far the
/// morph has come — `progress` on its way to `target` — and that it has ended on the frame it
/// does. Not `withAnimation`'s completion: the morph's never came, though another animation
/// started with the same curve beside it completed in 0.65 s (探索's 編輯首頁, iOS 27 simulator).
private struct ScrollEndPinning: ViewModifier, Animatable {
    let pins: Bool
    var progress: Double
    let target: Double
    let bottomInset: CGFloat
    let scrolledAway: () -> Void

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let morphed = pins && progress != target ? 1 - abs(target - progress) : nil
        return content.background(ScrollEndPin(pins: pins, morphed: morphed, bottomInset: bottomInset,
                                               scrolledAway: scrolledAway)
            .accessibilityHidden(true))
    }
}

private struct ScrollEndPin: UIViewRepresentable {
    let pins: Bool
    /// How much of the morph is done, from 0 to 1, while it runs. Only then is every other move
    /// of the offset undone: VoiceOver's scrolls, a tap on the status bar and a drop's autoscroll
    /// are none of them a drag, and held longer the page undid each of them.
    let morphed: Double?
    /// Read by nothing here: its change calls `updateUIView`, which pins again. The bars coming
    /// and going change the scroll view's insets and set neither its size nor its offset.
    let bottomInset: CGFloat
    let scrolledAway: () -> Void

    func makeUIView(context: Context) -> PinView {
        PinView()
    }

    func updateUIView(_ view: PinView, context: Context) {
        view.pins = pins
        view.morphed = morphed
        view.scrolledAway = scrolledAway
        view.pin()
    }

    final class PinView: UIView {
        var pins = false {
            didSet { if !pins { hasScrolledAway = false } }
        }
        var morphed: Double?
        var scrolledAway: () -> Void = {}
        /// A scroll took the page off its end, and the pin lets it be until `pins` is cleared:
        /// SwiftUI hears of it on the main actor's next turn, and an update before that still
        /// reads `pins` set.
        private var hasScrolledAway = false
        /// What the page was last put at the end of. The offset moving while all of it stays is
        /// no layout's doing but a scroll's: VoiceOver's or the status bar's are not drags, and
        /// followed on, a section that changed its size later — its books arriving, or hidden —
        /// took the page back to its end.
        private var pinnedLayout: PinnedLayout?
        /// How far above the end the page was as the morph began. Put at the end at once, a page
        /// left at the editor's top by the bar's 完成 swapped to its end in one frame and only then
        /// morphed; from the end itself, this is 0 and the page stays there.
        private var startDistance: CGFloat?
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            let scrollView = ancestor as? UIScrollView
            guard scrollView !== self.scrollView || observations.isEmpty else { return }
            self.scrollView = scrollView
            // Both change on the main thread. The size only when it is another: SwiftUI sets the
            // same size again on each frame of a scroll, and the page went back to its end as the
            // status bar took it to its top.
            observations = scrollView.map { scrollView in
                [scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                    guard change.oldValue != change.newValue else { return }
                    MainActor.assumeIsolated { self?.pin() }
                 },
                 scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.offsetChanged() }
                 }]
            } ?? []
            pin()
        }

        private func offsetChanged() {
            guard pins, !hasScrolledAway, let scrollView else { return }
            // The morph moves it as it lays the content out; the content or the bars changing do.
            guard morphed == nil, PinnedLayout(scrollView) == pinnedLayout else {
                pin()
                return
            }
            // Within a point is still the end: SwiftUI puts the offset on an end of its own as it
            // updates the scroll view, worked out from the size rounded to a whole point — 633 for
            // 632.33 (iOS 27 simulator, Reduce Motion, 完成), and the page stopped following there.
            guard abs(scrollView.contentOffset.y - Self.end(of: scrollView)) >= 1 else { return }
            hasScrolledAway = true
            // Published on the next turn: a scroll's move can come in the middle of a view update.
            Task { @MainActor [weak self] in self?.scrolledAway() }
        }

        func pin() {
            guard pins, !hasScrolledAway, let scrollView else {
                startDistance = nil
                pinnedLayout = nil
                return
            }
            let insets = scrollView.adjustedContentInset
            let top = -insets.top
            let end = Self.end(of: scrollView)
            pinnedLayout = PinnedLayout(scrollView)
            var offset = end
            if let morphed {
                let distance = startDistance ?? max(0, end - scrollView.contentOffset.y)
                startDistance = distance
                offset = max(top, end - distance * (1 - morphed))
            } else {
                startDistance = nil
            }
            // Within half a point: setting the offset calls the offset's observer again.
            guard abs(scrollView.contentOffset.y - offset) > 0.5 else { return }
            // Never animated. The tab bar coming back changes the safe area inside UIKit's own
            // animation, and an offset set there went with it: the page then showed that
            // animation's offset, not the one set each frame after, and jumped 646 points when
            // it ended (編輯首頁's 完成, iOS 27 simulator).
            UIView.performWithoutAnimation { scrollView.contentOffset.y = offset }
        }

        private static func end(of scrollView: UIScrollView) -> CGFloat {
            let insets = scrollView.adjustedContentInset
            return max(-insets.top, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
        }
    }

    /// Everything the end depends on.
    private struct PinnedLayout: Equatable {
        let contentSize: CGSize
        let insets: UIEdgeInsets
        let boundsSize: CGSize

        @MainActor
        init(_ scrollView: UIScrollView) {
            contentSize = scrollView.contentSize
            insets = scrollView.adjustedContentInset
            boundsSize = scrollView.bounds.size
        }
    }
}

private struct ScrollDragObserver: UIViewRepresentable {
    let onBegan: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(onBegan: onBegan)
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onBegan = onBegan
    }

    final class ObserverView: UIView {
        var onBegan: () -> Void
        private weak var scrollView: UIScrollView?

        init(onBegan: @escaping () -> Void) {
            self.onBegan = onBegan
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            scrollView = nil
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            scrollView = ancestor as? UIScrollView
            scrollView?.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { onBegan() }
        }
    }
}

private struct ScrollViewMeasurer: UIViewRepresentable {
    enum Measure {
        /// How far the scroll view has scrolled from its top.
        case offset
        /// How tall it has to be to show its content without scrolling.
        case contentHeight
    }

    let measure: Measure
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> MeasuringView {
        MeasuringView(measure: measure, onChange: onChange)
    }

    func updateUIView(_ view: MeasuringView, context: Context) {
        view.onChange = onChange
    }

    final class MeasuringView: UIView {
        let measure: Measure
        var onChange: (CGFloat) -> Void
        private var observation: NSKeyValueObservation?
        private weak var observedScrollView: UIScrollView?

        init(measure: Measure, onChange: @escaping (CGFloat) -> Void) {
            self.measure = measure
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            let scrollView = ancestor as? UIScrollView
            if scrollView !== observedScrollView || observation == nil {
                observedScrollView = scrollView
                observation = scrollView.map(observe)
            }
            // The value as placed goes out on the main actor's next turn: SwiftUI is still
            // adding this view to the window here, and publishing in the middle of that is a
            // change during a view update. Every later change comes from the observation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let observedScrollView {
                    report(observedScrollView)
                } else if measure == .offset {
                    onChange(0)
                }
            }
        }

        /// The offset and the content size both change on the main thread, so the change
        /// handler runs there.
        private func observe(_ scrollView: UIScrollView) -> NSKeyValueObservation {
            switch measure {
            case .offset:
                scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated {
                        self?.report(scrollView)
                    }
                }
            case .contentHeight:
                scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated {
                        self?.report(scrollView)
                    }
                }
            }
        }

        private func report(_ scrollView: UIScrollView) {
            let insets = scrollView.adjustedContentInset
            switch measure {
            case .offset:
                onChange(scrollView.contentOffset.y + insets.top)
            case .contentHeight:
                onChange(scrollView.contentSize.height + insets.top + insets.bottom)
            }
        }
    }
}
