import Foundation

#if DEBUG
/// A shelf for UI tests (`-seed-shelf grouped|ungrouped`), written over `books_meta.json`
/// before `BookStore` first reads it. A fresh simulator has an empty shelf, and the shelf's
/// gesture tests need books in rows: `ungrouped` is twelve books on 全部 alone, `grouped`
/// adds two groups of two ahead of them, so 全部 leads with two folders and the shelf pages.
/// The books have no content file; the tests swipe and tap menus, they never open one.
enum BookStoreTestSeed {
    static func writeShelf(_ layout: String) {
        let groups: [String]
        switch layout {
        case "grouped": groups = ["甲組", "乙組"]
        case "ungrouped": groups = []
        default:
            AppLogger.error("-seed-shelf: unknown layout \(layout); expected grouped or ungrouped")
            return
        }
        // The groups first, so in manual order their folders lead 全部; then enough books for
        // 全部 to scroll on any phone.
        var books: [ReadingBook] = []
        for group in groups {
            for index in 1...2 {
                var book = ReadingBook(title: "\(group)書\(index)", author: "測試作者", contentFilename: "")
                book.group = group
                books.append(book)
            }
        }
        books += (1...12).map { ReadingBook(title: "測試書\($0)", author: "測試作者", contentFilename: "") }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(books).write(to: StorageLocations.booksMetadataFile, options: .atomic)
        } catch {
            AppLogger.error("-seed-shelf: the shelf was not written: \(error)")
        }
    }
}
#endif
