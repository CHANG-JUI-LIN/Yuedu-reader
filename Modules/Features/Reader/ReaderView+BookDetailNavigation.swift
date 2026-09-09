import SwiftUI

extension ReaderView {
    func openOnlineBookDetail() {
        // Freeze source-controlled data at the navigation boundary. In particular,
        // do not re-resolve a pushed detail from a changing source/search result.
        guard let detail = onlineBookDetail else { return }
        if let navigator = readerNavigator {
            navigator.showDetail(ReaderDetailHostingController(
                content: AnyView(onlineBookDetailDestination(detail))
            ))
        } else {
            // SwiftUI-pushed readers use their parent stack; modal readers use
            // their own stack. Both routes remain owned by SwiftUI.
            onlineBookDetailSnapshot = detail
            showOnlineBookDetail = true
        }
    }

    func onlineBookDetailDestination(_ detail: OnlineBook) -> some View {
        OnlineBookView(
            book: detail,
            sourceSwitchBookId: bookId,
            onRemoveFromShelf: {
                if let navigator = readerNavigator {
                    // Close the detail first; only then run the reader's book
                    // close animation and release its presentation identity.
                    navigator.close()
                } else {
                    dismissReaderPresentation()
                }
            },
            onContinueReading: { chapterIndex in
                if let navigator = readerNavigator {
                    navigator.returnFromDetail {
                        if let chapterIndex { jumpToChapter(chapterIndex) }
                    }
                } else {
                    pendingDetailChapterIndex = chapterIndex
                    showOnlineBookDetail = false
                }
            }
        )
        .environmentObject(store)
        .environment(\.appDependencies, dependencies)
        .environment(\.readerNavigator, readerNavigator)
        .navigationTitle(localized("書籍詳情"))
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar(.visible, for: .navigationBar)
    }
}
