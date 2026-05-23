import SwiftUI
import UIKit

/// Wraps CoreTextCollectionScrollViewController as a SwiftUI representable, forwarding engine, insets, and theme.
struct CoreTextScrollHostView: UIViewControllerRepresentable {

    @ObservedObject var engine: CoreTextScrollEngine
    let axis: CoreTextScrollAxis
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let bottomMargin: CGFloat
    let backgroundColor: UIColor
    let initialChapter: Int
    let initialCharOffset: Int
    let resliceToken: UInt
    let playbackHighlightText: String?
    let textAnnotations: [CoreTextTextAnnotation]
    var onTap: () -> Void = {}
    var onProgressCommit: (ScrollProgress) -> Void = { _ in }
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
        vc.onProgressCommit = onProgressCommit
        vc.onInternalLinkTap = onInternalLinkTap
        vc.setInitialPosition(chapter: initialChapter, charOffset: initialCharOffset)
        vc.setTextAnnotations(textAnnotations)
        vc.setPlaybackHighlight(text: playbackHighlightText)
        vc.bottomMargin = bottomMargin
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard let collectionVC = vc as? CoreTextCollectionScrollViewController else { return }
        collectionVC.onTap = onTap
        collectionVC.onProgressCommit = onProgressCommit
        collectionVC.onInternalLinkTap = onInternalLinkTap
        collectionVC.setTextAnnotations(textAnnotations)
        collectionVC.setPlaybackHighlight(text: playbackHighlightText)
        collectionVC.update(axis: axis, horizontal: horizontalInset, vertical: verticalInset, bottomMargin: bottomMargin)
        collectionVC.updateBackgroundColor(backgroundColor)
        if context.coordinator.lastResliceToken != resliceToken {
            context.coordinator.lastResliceToken = resliceToken
            if context.coordinator.lastResliceToken != 0 {
                collectionVC.requestReslice(at: initialChapter, charOffset: initialCharOffset)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastResliceToken: UInt = 0
    }
}
