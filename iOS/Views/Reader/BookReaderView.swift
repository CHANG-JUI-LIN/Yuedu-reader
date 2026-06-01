import SwiftUI

// MARK: - Book Reader Router
//
// Single branch point that picks the reader for a book: the image-based manga
// reader for `.manga` books, otherwise the existing text/EPUB `ReaderView`.
// All shelf/online presentation sites go through this so `ReaderView` stays
// untouched.

struct BookReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore

    var body: some View {
        Group {
            if store.books.first(where: { $0.id == bookId })?.resolvedPipelineKind == .manga {
                MangaReaderView(bookId: bookId)
            } else {
                ReaderView(bookId: bookId)
            }
        }
        .onAppear {
            if store.books.first(where: { $0.id == bookId })?.lastOpenedDate == nil {
                store.updateLastOpened(bookId: bookId)
            }
        }
    }
}
