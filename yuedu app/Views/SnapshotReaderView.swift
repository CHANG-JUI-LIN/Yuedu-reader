import SwiftUI

struct SnapshotReaderView: UIViewControllerRepresentable {
    @ObservedObject var renderer: EPUBPageRenderer
    @ObservedObject var snapshotProvider: PageSnapshotProvider

    var pageTurnStyle: PageTurnStyle
    var currentPage: Int
    var onTapCenter: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(initialPage: currentPage)
    }

    func makeUIViewController(context: Context) -> ReaderPageViewController {
        let provider = snapshotProvider
        let rend = renderer
        DispatchQueue.main.async { provider.attach(renderer: rend) }
        let controller = ReaderPageViewController(
            renderer: renderer,
            snapshotProvider: snapshotProvider,
            pageTurnStyle: pageTurnStyle,
            onTapCenter: onTapCenter
        )
        return controller
    }

    func updateUIViewController(_ controller: ReaderPageViewController, context: Context) {
        let provider = snapshotProvider
        let rend = renderer
        DispatchQueue.main.async { provider.attach(renderer: rend) }
        controller.onTapCenter = onTapCenter
        let previousPage = context.coordinator.lastPage
        // 只在 SwiftUI 侧 currentPage 真正变化时才告知 UIKit 跳页，
        // 防止 UIKit 手势翻页后 @State 尚未更新就被强制跳回旧页（竞态导致的闪回）
        if currentPage != previousPage {
            let stepDelta = abs(currentPage - previousPage)
            let shouldAnimate = context.transaction.animation != nil && !context.transaction.disablesAnimations && stepDelta == 1
            controller.updateCurrentPage(currentPage, animated: shouldAnimate)
            context.coordinator.lastPage = currentPage
        }
        controller.refreshVisiblePage()
    }

    final class Coordinator {
        var lastPage: Int

        init(initialPage: Int) {
            self.lastPage = initialPage
        }
    }
}
