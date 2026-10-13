import SwiftUI

extension ReaderView {
    /// 作品詳情 for the book being read (unified library 5f-4b, decision 32): every book has
    /// it, local ones included, and it shows only this copy.
    func openWorkDetail() {
        // Freeze the route at the navigation boundary: the page never re-resolves it from
        // the reader's changing state.
        guard let book, let route = ShelfProvider(store: store).items([book]).first.flatMap(WorkDetailRoute.init) else {
            AppLogger.info("⟐ workDetail no route bookID=\(bookId)")
            return
        }
        if let navigator = readerNavigator {
            navigator.showDetail(ReaderDetailHostingController(
                content: AnyView(workDetailDestination(route))
            ))
        } else {
            // SwiftUI-pushed readers use their parent stack; modal readers use
            // their own stack. Both routes remain owned by SwiftUI.
            workDetailSnapshot = route
            showWorkDetail = true
        }
    }

    func workDetailDestination(_ route: WorkDetailRoute) -> some View {
        WorkDetailView(route: route, readerContext: WorkDetailReaderContext(
            bookId: bookId,
            continueReading: { target in
                if let navigator = readerNavigator {
                    navigator.returnFromDetail {
                        if let target { jumpToTOCEntry(target.entry) }
                    }
                } else {
                    pendingDetailTOCTarget = target
                    showWorkDetail = false
                }
            },
            removedFromShelf: {
                if let navigator = readerNavigator {
                    // Close the detail first; only then run the reader's book
                    // close animation and release its presentation identity.
                    navigator.close()
                } else {
                    dismissReaderPresentation()
                }
            }
        ))
        .environmentObject(store)
        .environment(\.appDependencies, dependencies)
        .environment(\.readerNavigator, readerNavigator)
        // Above 書架's reader the detail gets its own hosting controller, which starts a
        // new environment; without this it could hide only 書架's tab bar.
        .environment(\.rootTabBarVisibility, rootTabBarVisibility)
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar(.visible, for: .navigationBar)
    }
}
