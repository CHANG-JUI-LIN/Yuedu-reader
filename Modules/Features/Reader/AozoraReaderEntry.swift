import SwiftUI

/// 開始閱讀 on a 青空文庫 work that is not on the shelf yet: the reader opens at once and the
/// work is downloaded and converted under the reader's own 載入中… (`ReaderPreparingView`), as
/// a library book's copy is prepared in `BookReaderView`. Until 2026-10-12 作品詳情 waited on the import itself,
/// with 正在開啟書籍 and 取消 under its hero (maintainer: that wait belongs to the reader).
/// Closing while it runs cancels the import.
struct AozoraReaderEntry: View {
    let work: AozoraWork
    @EnvironmentObject private var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    // A pushed reader's stable dismissal (iOS 17), as `BookReaderView` uses.
    @Environment(\.presentationMode) private var presentationMode
    @State private var bookID: UUID?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        if let bookID {
            BookReaderView(bookId: bookID)
        } else {
            ReaderPreparingView(
                error: error,
                onRetry: { attempt += 1 },
                onClose: { presentationMode.wrappedValue.dismiss() }
            )
            .task(id: attempt) { await importWork() }
        }
    }

    /// The work's reading copy, off the shelf: the page the reader closes onto asks whether to
    /// add it (2026-10-13; until then reading put the work on the shelf).
    private func importWork() async {
        error = nil
        do {
            bookID = try await dependencies.aozoraLibrary.readingCopy(work: work, store: store).id
        } catch is CancellationError {
            // The reader was closed; nothing to show.
        } catch {
            // The service has logged it (`AppLogger.network`).
            self.error = error.localizedDescription
        }
    }
}

#Preview("青空文庫 · opening") {
    NavigationStack {
        AozoraReaderEntry(work: AozoraCatalogIndex.preview.newWorks[0])
    }
    .environmentObject(BookStore())
}
