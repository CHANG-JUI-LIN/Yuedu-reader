import Combine
import Foundation

@MainActor
final class DownloadManagementViewModel: ObservableObject {
    @Published private(set) var byteCountsByBook: [UUID: Int64] = [:]

    func refreshStorage(
        for books: [ReadingBook],
        chapterStore: any OfflineChapterStoring
    ) async {
        var snapshot: [UUID: Int64] = [:]
        for book in books where book.isOnline {
            snapshot[book.id] = await chapterStore.storageByteCount(bookId: book.id)
        }
        byteCountsByBook = snapshot
    }

    func megabytes(for bookId: UUID) -> Double {
        Double(byteCountsByBook[bookId] ?? 0) / 1_048_576
    }

    var totalMegabytes: Double {
        Double(byteCountsByBook.values.reduce(0, +)) / 1_048_576
    }
}
