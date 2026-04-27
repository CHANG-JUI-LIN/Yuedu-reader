import SwiftUI
import UIKit

/// SwiftUI 入口：包裝 `CoreTextScrollViewController`，把 engine、insets、theme 推進去。
struct CoreTextScrollHostView: UIViewControllerRepresentable {

    @ObservedObject var engine: CoreTextScrollEngine
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let backgroundColor: UIColor
    let initialChapter: Int
    let initialCharOffset: Int
    let resliceToken: UInt
    var onTap: () -> Void = {}
    var onProgressChange: (Int, Int, Double) -> Void = { _, _, _ in }

    func makeUIViewController(context: Context) -> CoreTextScrollViewController {
        let vc = CoreTextScrollViewController(
            engine: engine,
            horizontalInset: horizontalInset,
            verticalInset: verticalInset,
            backgroundColor: backgroundColor
        )
        vc.onTap = onTap
        vc.onProgressChange = onProgressChange
        vc.setInitialPosition(chapter: initialChapter, charOffset: initialCharOffset)
        return vc
    }

    func updateUIViewController(_ vc: CoreTextScrollViewController, context: Context) {
        vc.onTap = onTap
        vc.onProgressChange = onProgressChange
        vc.updateInsets(horizontal: horizontalInset, vertical: verticalInset)
        vc.updateBackgroundColor(backgroundColor)
        if context.coordinator.lastResliceToken != resliceToken {
            context.coordinator.lastResliceToken = resliceToken
            if context.coordinator.lastResliceToken != 0 {
                vc.requestReslice(at: initialChapter)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastResliceToken: UInt = 0
    }
}
