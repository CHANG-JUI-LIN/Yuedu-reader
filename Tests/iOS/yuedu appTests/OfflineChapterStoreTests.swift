import Foundation
import Testing
@testable import yuedu_app

@Suite("Offline chapter store", .serialized)
struct OfflineChapterStoreTests {
    @Test("missing one manga page is incomplete")
    func missingPageIsIncomplete() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())
        let request = makeMangaRequest(bookId: UUID())

        let directory = roots.storage.mangaChapterDirectory(
            bookId: request.bookId,
            chapterIndex: request.chapterIndex
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("page zero".utf8).write(to: directory.appendingPathComponent("000.jpg"))

        #expect(await store.mangaValidationState(for: request) == .incomplete)
    }

    @Test("manifest is committed only after every page succeeds")
    func completeManifest() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())
        let request = makeMangaRequest(bookId: UUID())

        try await store.persistMangaImages(request)

        #expect(await store.mangaValidationState(for: request) == .complete)
        let manifest = try #require(
            OfflineChapterStore.validatedMangaManifest(
                bookId: request.bookId,
                chapterIndex: request.chapterIndex,
                roots: roots.storage
            )
        )
        #expect(manifest.pages.count == 2)
    }

    @Test("HTTP 200 HTML challenge is not accepted as an image")
    func htmlResponseRejected() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let store = OfflineChapterStore(
            roots: roots.storage,
            imageDownloader: HTMLImageDownloader()
        )
        let request = makeMangaRequest(bookId: UUID())

        await #expect(throws: OfflineChapterStoreError.self) {
            try await store.persistMangaImages(request)
        }
        #expect(
            OfflineChapterStore.validatedMangaManifest(
                bookId: request.bookId,
                chapterIndex: request.chapterIndex,
                roots: roots.storage
            ) == nil
        )
    }

    @Test("remove book deletes text and manga roots")
    func removeDeletesBothRoots() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let textBookDirectory = roots.storage.textBookDirectory(bookId: bookId)
        let mangaBookDirectory = roots.storage.mangaBookDirectory(bookId: bookId)
        try FileManager.default.createDirectory(at: textBookDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mangaBookDirectory, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: textBookDirectory.appendingPathComponent("0.txt"))
        try Data("image".utf8).write(to: mangaBookDirectory.appendingPathComponent("0.jpg"))
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())

        try await store.removeBook(bookId: bookId)

        #expect(!FileManager.default.fileExists(atPath: textBookDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: mangaBookDirectory.path))
    }

    @Test("TOC append preserves matching chapter artifacts")
    func tocAppendPreservesArtifacts() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let textFile = roots.storage.textBookDirectory(bookId: bookId)
            .appendingPathComponent("0.txt")
        let mangaDirectory = roots.storage.mangaChapterDirectory(bookId: bookId, chapterIndex: 0)
        try FileManager.default.createDirectory(
            at: textFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: mangaDirectory, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: textFile)
        try Data("image".utf8).write(to: mangaDirectory.appendingPathComponent("000.jpg"))
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())
        let oldRefs = [OnlineChapterRef(index: 0, title: "One", url: "https://x/1")]
        let newRefs = oldRefs + [OnlineChapterRef(index: 1, title: "Two", url: "https://x/2")]

        try await store.reconcileBook(bookId: bookId, oldRefs: oldRefs, newRefs: newRefs)

        #expect(FileManager.default.fileExists(atPath: textFile.path))
        #expect(FileManager.default.fileExists(atPath: mangaDirectory.path))
    }

    @Test("changed chapter identity removes text and manga artifacts together")
    func tocMismatchRemovesArtifacts() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let textFile = roots.storage.textBookDirectory(bookId: bookId)
            .appendingPathComponent("0.txt")
        let mangaDirectory = roots.storage.mangaChapterDirectory(bookId: bookId, chapterIndex: 0)
        try FileManager.default.createDirectory(
            at: textFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: mangaDirectory, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: textFile)
        try Data("image".utf8).write(to: mangaDirectory.appendingPathComponent("000.jpg"))
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())

        try await store.reconcileBook(
            bookId: bookId,
            oldRefs: [OnlineChapterRef(index: 0, title: "One", url: "https://x/1")],
            newRefs: [OnlineChapterRef(index: 0, title: "Different", url: "https://x/changed")]
        )

        #expect(!FileManager.default.fileExists(atPath: textFile.path))
        #expect(!FileManager.default.fileExists(atPath: mangaDirectory.path))
    }

    private func makeMangaRequest(bookId: UUID) -> OfflineMangaChapterRequest {
        OfflineMangaChapterRequest(
            bookId: bookId,
            chapterIndex: 3,
            chapterSourceURL: "https://example.com/chapter/3",
            tocTitle: "Chapter 4",
            images: [
                .init(sourceURL: "https://example.com/0.jpg", headers: [:]),
                .init(sourceURL: "https://example.com/1.jpg", headers: [:]),
            ]
        )
    }

    private func makeRoots() throws -> (container: URL, storage: OfflineStorageRoots) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineChapterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return (
            container,
            OfflineStorageRoots(
                textRoot: container.appendingPathComponent("text", isDirectory: true),
                mangaRoot: container.appendingPathComponent("manga", isDirectory: true)
            )
        )
    }
}

private struct StubImageDownloader: OfflineImageDownloading {
    func response(for request: URLRequest) async throws -> OfflineImageResponse {
        OfflineImageResponse(
            data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]),
            statusCode: 200,
            mimeType: "image/jpeg"
        )
    }
}

private struct HTMLImageDownloader: OfflineImageDownloading {
    func response(for request: URLRequest) async throws -> OfflineImageResponse {
        OfflineImageResponse(
            data: Data("<html>verify you are human</html>".utf8),
            statusCode: 200,
            mimeType: "text/html"
        )
    }
}
