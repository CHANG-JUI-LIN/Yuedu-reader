import SwiftUI
import UIKit

/// The window the reader is in. Brightness, the window's safe area and orientation requests
/// belong to that window's scene and screen — not to whichever window happens to be key, which
/// on an iPad with two windows, or a Stage Manager window on an external display, is another
/// screen altogether.
///
/// A reference, not `@State` of the window itself: the probe reports from `didMoveToWindow`,
/// which can run inside a SwiftUI update, and storing it must not publish anything.
@MainActor
final class ReaderWindowReference {
    /// Kept when the reader leaves its window: `onDisappear` runs once the reader's views are
    /// out of the window and still has to hand the screen its brightness back.
    private(set) weak var window: UIWindow?
    /// Work that needed the window before the reader was in one. A reader pushed by UIKit
    /// (`ReaderHostingController`) appears before its view is added to the window.
    private var pendingWork: [(UIWindow) -> Void] = []

    var screen: UIScreen? { window?.windowScene?.screen }
    var windowScene: UIWindowScene? { window?.windowScene }

    /// Runs `work` now if the reader is in a window, otherwise once it is.
    func withWindow(_ work: @escaping (UIWindow) -> Void) {
        if let window {
            work(window)
        } else {
            pendingWork.append(work)
        }
    }

    fileprivate func moved(to window: UIWindow?) {
        guard let window else { return }
        self.window = window
        let work = pendingWork
        pendingWork = []
        work.forEach { $0(window) }
    }
}

private struct ReaderWindowProbe: UIViewRepresentable {
    let reference: ReaderWindowReference

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.reference = reference
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.reference = reference
    }

    final class ProbeView: UIView {
        var reference: ReaderWindowReference? {
            didSet { reference?.moved(to: window) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reference?.moved(to: window)
        }
    }
}

extension View {
    /// Keeps `reference` pointing at the window this view is in. An overlay, not a background:
    /// a platform view in `.background` reorders VoiceOver so the page reads before the bars.
    func readerWindowProbe(_ reference: ReaderWindowReference) -> some View {
        overlay {
            ReaderWindowProbe(reference: reference)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
