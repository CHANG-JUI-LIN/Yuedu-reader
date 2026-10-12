import SwiftUI

/// 「將「書名」加入書架？」 after a reader closes on a book that is not on the shelf, asked by the
/// page the reader closes onto (maintainer, 2026-10-13). Every way out reaches that page — the
/// close button and a swipe back alike — and a swipe back cannot be stopped to ask, so the
/// reader itself never asks. Its own prompt had not shown since 2026-10-04 anyway: it asked only
/// for a book missing from the store, and a book read without adding has been a record off the
/// shelf since then.
enum ReaderShelvePrompt {
    /// The copy to ask about once its reader has closed: one off the shelf that was opened; nil
    /// for anything else. Only a book read from a library or a source is off the shelf (an
    /// imported file joins it), and a copy made ahead of reading was never opened.
    @MainActor
    static func copy(_ id: UUID, in store: BookStore) -> ReadingBook? {
        guard let book = store.readingBook(id: id), !book.isInBookshelf, book.lastOpenedDate != nil else { return nil }
        return book
    }
}

private struct ReaderShelvePromptModifier: ViewModifier {
    @Binding var book: ReadingBook?
    let onAdd: (ReadingBook) -> Void
    let onDecline: (ReadingBook) -> Void

    func body(content: Content) -> some View {
        content.alert(String(format: localized("將「%@」加入書架？"), book?.title ?? ""),
                      isPresented: Binding(get: { book != nil }, set: { if !$0 { book = nil } }),
                      presenting: book) { book in
            Button(localized("加入書架")) { onAdd(book) }
            Button(localized("不加入"), role: .cancel) { onDecline(book) }
        }
    }
}

extension View {
    /// Asks whether to add `book` to the shelf while it is set; answering clears it.
    func readerShelvePrompt(_ book: Binding<ReadingBook?>, onAdd: @escaping (ReadingBook) -> Void,
                            onDecline: @escaping (ReadingBook) -> Void = { _ in }) -> some View {
        modifier(ReaderShelvePromptModifier(book: book, onAdd: onAdd, onDecline: onDecline))
    }
}

#Preview("加入書架？") {
    @Previewable @State var book: ReadingBook? = ReadingBook(title: "ホノルル", author: "中谷宇吉郎", source: "local_epub",
                                                             contentFilename: "preview.epub")
    Button("Ask") { book = ReadingBook(title: "ホノルル", author: "中谷宇吉郎", source: "local_epub", contentFilename: "preview.epub") }
        .readerShelvePrompt($book, onAdd: { _ in })
}
