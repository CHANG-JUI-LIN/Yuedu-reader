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
