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
        #expect(reloaded?.renderArtifactVersion == OnlineChapterRenderArtifact.currentVersion)
    }

    /// 笔趣阁 (apibi.cc, YCK1329／1330) decrypts to text that starts with U+FEFF; reading the
    /// file back as `String(contentsOf:encoding: .utf8)` dropped it, and every save failed
    /// verification ("Chapter cache verification failed").
    @Test("a body that starts with U+FEFF reads back as written")
    func leadingByteOrderMarkSurvives() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()
        let content = "\u{FEFF}<br><br>第1章<br><br>规定是假的，整篇文都是假的。"

        try repository.saveChapterPackageToCache(
            package(bookId: bookId, content: content),
            rawHTML: content,
            normalizedHTML: "\u{FEFF}<html><body>第1章</body></html>"
        )

        let reloaded = repository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: 0,
            expectedSourceURL: "https://example.com/0",
            expectedTOCTitle: "Chapter 1"
        )
        #expect(reloaded?.content == content)
        #expect(repository.loadNormalizedChapterHTMLSync(bookId: bookId, chapterIndex: 0)
            == "\u{FEFF}<html><body>第1章</body></html>")
    }

    /// 新笔趣阁wap (wap.t965.com, YCK1330) opens a book with the volume page 「正文」, whose text
    /// is the title alone. The read-back compared it with the TOC title and rejected it, so every
    /// save failed ("Chapter cache verification failed"); Legado keeps such a chapter.
    @Test("a chapter whose text is only its title is saved and read back")
    func titleOnlyChapterSurvives() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()

        try repository.saveChapterPackageToCache(
            package(bookId: bookId, content: "正文", title: "正文"),
            rawHTML: "<section id=\"nr\"><h2>正文</h2><br /></section>",
            normalizedHTML: "<html><body><h2>正文</h2></body></html>"
        )

        let reloaded = repository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: 0,
            expectedSourceURL: "https://example.com/0",
            expectedTOCTitle: "正文"
        )
        #expect(reloaded?.content == "正文")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterCacheRepositoryWriteTests-\(UUID().uuidString)")
    }

    private func package(bookId: UUID, content: String, title: String = "Chapter 1") -> ChapterPackage {
        ChapterPackage(
            bookId: bookId,
            chapterIndex: 0,
            sourceURL: "https://example.com/0",
            tocTitle: title,
            canonicalTitle: title,
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
