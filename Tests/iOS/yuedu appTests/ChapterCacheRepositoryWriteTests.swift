import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter cache durable writes", .serialized)
struct ChapterCacheRepositoryWriteTests {
    @Test("empty content is rejected")
    func emptyContentRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)

        #expect(throws: ChapterCacheWriteError.emptyContent) {
            try repository.saveChapterPackageToCache(
                package(bookId: UUID(), content: ""),
                rawHTML: nil,
                normalizedHTML: nil
            )
        }
    }

    @Test("body write failure propagates")
    func bodyFailurePropagates() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let repository = ChapterCacheRepository(rootDirectory: root)

        #expect(throws: ChapterCacheWriteError.self) {
            try repository.saveChapterPackageToCache(
                package(bookId: UUID(), content: "body"),
                rawHTML: nil,
                normalizedHTML: nil
            )
        }
    }

    @Test("successful write is immediately reloadable and verified")
    func writeIsReloadable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()

        let filename = try repository.saveChapterPackageToCache(
            package(bookId: bookId, content: "durable body"),
            rawHTML: "<p>durable body</p>",
            normalizedHTML: "<html><body>durable body</body></html>"
        )

        #expect(filename == "0.txt")
        let reloaded = repository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: 0,
            expectedSourceURL: "https://example.com/0",
            expectedTOCTitle: "Chapter 1"
        )
        #expect(reloaded?.content == "durable body")
        #expect(reloaded?.state == .cached)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterCacheRepositoryWriteTests-\(UUID().uuidString)")
    }

    private func package(bookId: UUID, content: String) -> ChapterPackage {
        ChapterPackage(
            bookId: bookId,
            chapterIndex: 0,
            sourceURL: "https://example.com/0",
            tocTitle: "Chapter 1",
            canonicalTitle: "Chapter 1",
            content: content,
            contentChecksum: "",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(timeIntervalSince1970: 1),
            state: .cached,
            failureReason: nil
        )
    }
}
