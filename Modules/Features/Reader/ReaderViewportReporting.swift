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

    /// Reports the window's side safe area — the larger of the leading and trailing insets —
    /// every time it changes. Nonzero in iPhone landscape, where the Dynamic Island takes one
    /// side, and wherever a window has a bar down one side. Attached beside
    /// `reportsReaderViewport`, for the same reason: only there are the insets the window's.
    func reportsReaderSideSafeArea(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
        } action: { inset in
            action(inset)
        }
    }
}
