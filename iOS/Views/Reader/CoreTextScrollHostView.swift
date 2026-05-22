import SwiftUI
import UIKit

/// Wraps CoreTextCollectionScrollViewController as a SwiftUI representable, forwarding engine, insets, and theme.
struct CoreTextScrollHostView: UIViewControllerRepresentable {

    @ObservedObject var engine: CoreTextScrollEngine
    let axis: CoreTextScrollAxis
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let backgroundColor: UIColor
    let initialChapter: Int
    let initialCharOffset: Int
    let resliceToken: UInt
    let playbackHighlightText: String?
    var onTap: () -> Void = {}
    var onProgressChange: (Int, Int, Double) -> Void = { _, _, _ in }
    var onInternalLinkTap: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: axis,
            horizontalInset: horizontalInset,
            verticalInset: verticalInset,
            backgroundColor: backgroundColor
        )
        vc.onTap = onTap
        vc.onProgressChange = onProgressChange
        vc.onInternalLinkTap = onInternalLinkTap
        vc.setInitialPosition(chapter: initialChapter, charOffset: initialCharOffset)
        vc.setPlaybackHighlight(text: playbackHighlightText)
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard let collectionVC = vc as? CoreTextCollectionScrollViewController else { return }
        collectionVC.onTap = onTap
        collectionVC.onProgressChange = onProgressChange
        collectionVC.onInternalLinkTap = onInternalLinkTap
        collectionVC.setPlaybackHighlight(text: playbackHighlightText)
        collectionVC.update(axis: axis, horizontal: horizontalInset, vertical: verticalInset)
        collectionVC.updateBackgroundColor(backgroundColor)
        if context.coordinator.lastResliceToken != resliceToken {
            context.coordinator.lastResliceToken = resliceToken
            if context.coordinator.lastResliceToken != 0 {
                collectionVC.requestReslice(at: initialChapter)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastResliceToken: UInt = 0
    }
}
