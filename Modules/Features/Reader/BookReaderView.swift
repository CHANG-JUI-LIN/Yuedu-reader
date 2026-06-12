import SwiftUI

// MARK: - Book Reader Router
//
// Single branch point that picks the reader for a book: the shared fixed-page
// reader for image archives / FXL EPUB, otherwise the existing text/EPUB `ReaderView`.
// All shelf/online presentation sites go through this so `ReaderView` stays
// untouched.

struct BookReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore

    var body: some View {
        Group {
            if isAudiobook {
                AudiobookReaderView(bookId: bookId)
            } else if shouldUseFixedPageReader {
                FixedPageReaderView(bookId: bookId)
            } else {
                ReaderView(bookId: bookId)
            }
        }
        .onAppear {
            if let book = store.books.first(where: { $0.id == bookId }) {
                // Tag crash/diagnostic reports with the book being read — most
                // reader crashes are content-specific, so this is the fastest clue.
                CrashContext.setKey("current_book", "\(book.title) [\(book.id.uuidString.prefix(8))]")
                CrashContext.setKey("current_book_kind", "\(book.resolvedPipelineKind)")
                CrashContext.setKey("current_book_online", book.isOnline)
                CrashContext.breadcrumb("open reader: \(book.title) (\(book.resolvedPipelineKind))")
                if book.lastOpenedDate == nil {
                    store.updateLastOpened(bookId: bookId)
                }
            }
        }
        .onDisappear { CrashContext.breadcrumb("close reader") }
    }

    private var shouldUseFixedPageReader: Bool {
        guard let kind = store.books.first(where: { $0.id == bookId })?.resolvedPipelineKind else {
            return false
        }
        return kind == .manga || kind == .fixedPage
    }

    private var isAudiobook: Bool {
        store.books.first(where: { $0.id == bookId })?.resolvedPipelineKind == .audio
    }
}
