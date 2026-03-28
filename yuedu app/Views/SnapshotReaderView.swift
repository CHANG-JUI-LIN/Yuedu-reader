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
        snapshotProvider.attach(renderer: renderer)
        let controller = ReaderPageViewController(
            renderer: renderer,
            snapshotProvider: snapshotProvider,
            pageTurnStyle: pageTurnStyle,
            onTapCenter: onTapCenter
        )
        return controller
    }

    func updateUIViewController(_ controller: ReaderPageViewController, context: Context) {
        snapshotProvider.attach(renderer: renderer)
        controller.onTapCenter = onTapCenter
        let previousPage = context.coordinator.lastPage
        let stepDelta = abs(currentPage - previousPage)
        let shouldAnimate = context.transaction.animation != nil && !context.transaction.disablesAnimations && stepDelta == 1
        controller.updateCurrentPage(currentPage, animated: shouldAnimate)
        controller.refreshVisiblePage()
        context.coordinator.lastPage = currentPage
    }

    final class Coordinator {
        var lastPage: Int

        init(initialPage: Int) {
            self.lastPage = initialPage
        }
    }
}
