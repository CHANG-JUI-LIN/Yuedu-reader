import SwiftUI
import UIKit

// MARK: - ReaderTeardownProbe

/// A zero-sized view that reports when the reader leaves the view hierarchy for good.
///
/// `onDisappear` cannot say that: it also fires when the reader is only covered — a pushed
/// 作品詳情, a full-screen cover — and is about to come back. SwiftUI dismantles a
/// representable only when its view is really removed, so `dismantleUIView` is the one
/// signal every way out of the reader shares: the close button, a swipe back, a modal
/// dismissal, a detail stack popping.
///
/// The reader uses it to drop the callbacks it installed on its own state objects. Each of
/// those closures captures the reader view, which holds those same objects, so until they
/// are dropped the reader can never be freed.
///
/// `onDismantle` must not capture the reader view itself, or the probe would hold the reader
/// alive until the moment it is meant to release it.
struct ReaderTeardownProbe: UIViewRepresentable {
    let onDismantle: @MainActor () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        context.coordinator.onDismantle = onDismantle
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDismantle = onDismantle
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        let onDismantle = coordinator.onDismantle
        coordinator.onDismantle = nil
        onDismantle?()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onDismantle: (@MainActor () -> Void)?
    }
}
