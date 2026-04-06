/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import SwiftUI

struct SnapshotReaderView: UIViewControllerRepresentable {
    @ObservedObject var renderer: EPUBPageRenderer
    @ObservedObject var snapshotProvider: PageSnapshotProvider

    var pageTurnStyle: PageTurnStyle
    var currentPage: Int
    var onTapCenter: () -> Void

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
        controller.updateCurrentPage(currentPage, animated: false)
        controller.refreshVisiblePage()
    }
}
*/
