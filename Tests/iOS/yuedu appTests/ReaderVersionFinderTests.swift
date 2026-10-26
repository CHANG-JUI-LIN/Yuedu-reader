import Foundation
import Testing
@testable import yuedu_app

/// 換源's 書庫與模組 (maintainer 2026-10-26: every origin is a version like any other): what the
/// libraries and modules find under the title is listed when it is the same work.
@MainActor
@Suite("換源's versions in the libraries and modules", .serialized)
struct ReaderVersionFinderTests {
    @Test("a found book of the same title and author is the work's; another author's is not")
    func foundBooksMatchTheWork() {
        let work = route(1, "Pride and Prejudice", "Jane Austen")
        let same = route(1342, "Pride and Prejudice", "Jane Austen")
        let otherAuthor = route(20686, "Pride and Prejudice", "Someone Else")
        let otherTitle = route(161, "Sense and Sensibility", "Jane Austen")

        let found = WorkOffers.found(of: work, in: [same, otherAuthor, otherTitle])

        #expect(found.map(\.record.key) == [same.record.key])
    }

    @Test("the reader's book lists a library's version of its work once, by the library's name")
    func finderListsLibraryVersionOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderVersionFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let imported = ReadingBook(title: "Pride and Prejudice", author: "Jane Austen", source: "local_epub",
                                   contentFilename: "\(UUID()).epub")
        store.saveReadingBook(imported)
        let same = route(1342, "Pride and Prejudice", "Jane Austen")
        let other = route(20686, "Pride and Prejudice", "Someone Else")
        let answer = LibrarySearchAnswer(connectionID: "fixture", name: "Fixture", outcome: .results,
                                         entries: [same, other, same].map { .item($0.record, $0.summary, $0.opening) })
        let finder = ReaderVersionFinder(searches: { [FixedSearch(answer: answer)] })

        finder.start(for: imported.id, store: store)
        await finder.waitForTesting()

        #expect(!finder.isSearching)
        #expect(finder.found.map(\.route.record.key) == [same.record.key])
        #expect(finder.found.map(\.place) == ["Project Gutenberg"])
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
    }

    private func route(_ id: Int, _ title: String, _ author: String) -> WorkDetailRoute {
        WorkDetailRoute(PublicLibraryBook.gutenberg(GutenbergBook(id: id, title: title, author: author)))
    }
}

/// A place that answers every search with the same books.
@MainActor
private final class FixedSearch: SearchAnswering {
    let answer: LibrarySearchAnswer
    init(answer: LibrarySearchAnswer) { self.answer = answer }
    var isAvailable: Bool { true }
    func search(_ query: String, onAnswer: (LibrarySearchAnswer) -> Void) async { onAnswer(answer) }
}
