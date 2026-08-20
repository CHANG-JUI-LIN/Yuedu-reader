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

        try await store.reconcileBook(bookId: bookId, oldRefs: oldRefs, newRefs: newRefs, disposition: .deleteMismatched)

        #expect(FileManager.default.fileExists(atPath: textFile.path))
        #expect(FileManager.default.fileExists(atPath: mangaDirectory.path))
    }

    @Test("a book with no offline data reconciles without creating anything")
    func reconcileWithoutCachedDataIsANoOp() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())

        // The ordinary 換源 case: nothing was ever downloaded, and every index mismatches
        // because the chapters come from a different site. This used to probe six paths
        // per chapter to find that out.
        let oldRefs = (0..<500).map {
            OnlineChapterRef(index: $0, title: "舊 \($0)", url: "https://old.example/\($0)")
        }
        let newRefs = (0..<500).map {
            OnlineChapterRef(index: $0, title: "新 \($0)", url: "https://new.example/\($0)")
        }

        try await store.reconcileBook(bookId: bookId, oldRefs: oldRefs, newRefs: newRefs, disposition: .deleteMismatched)

        #expect(
            !FileManager.default.fileExists(
                atPath: roots.storage.textBookDirectory(bookId: bookId).path)
        )
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
            newRefs: [OnlineChapterRef(index: 0, title: "Different", url: "https://x/changed")],
            disposition: .deleteMismatched
        )

        #expect(!FileManager.default.fileExists(atPath: textFile.path))
        #expect(!FileManager.default.fileExists(atPath: mangaDirectory.path))
    }

    @Test("a readable cached chapter counts as downloaded")
    func cachedChapterIsComplete() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let repository = ChapterCacheRepository(rootDirectory: roots.storage.textRoot)
        _ = try repository.saveToCache(
            content: "第一章的內文，足夠長到不會被拒絕。",
            bookId: bookId,
            chapterIndex: 0,
            sourceURL: "https://example.com/1",
            tocTitle: "第一章"
        )
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())

        let state = await store.validationState(
            bookId: bookId,
            chapterIndex: 0,
            expectedSourceURL: "https://example.com/1",
            expectedTOCTitle: "第一章",
            requiresManga: false,
            hasBookSource: true
        )

        #expect(state == .complete)
    }

    @Test("a preserving reconcile keeps downloaded content even when every index mismatches")
    func preservingReconcileKeepsDownloadedContent() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let textFile = roots.storage.textBookDirectory(bookId: bookId)
            .appendingPathComponent("0.txt")
        try FileManager.default.createDirectory(
            at: textFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("text".utf8).write(to: textFile)
        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())

        // The shape of a background refresh that went wrong: the source answered with a
        // table of contents that matches nothing the book had. Under `.deleteMismatched`
        // this erases the download; a refresh nobody asked for must not be able to do that.
        let oldRefs = [OnlineChapterRef(index: 0, title: "One", url: "https://x/1")]
        let newRefs = [OnlineChapterRef(index: 0, title: "Other", url: "https://y/9")]

        try await store.reconcileBook(
            bookId: bookId,
            oldRefs: oldRefs,
            newRefs: newRefs,
            disposition: .preserveContent
        )

        #expect(FileManager.default.fileExists(atPath: textFile.path))

        // …and the user-initiated form still cleans up, so 換源 does not leave the old
        // source's bytes lying around.
        try await store.reconcileBook(
            bookId: bookId,
            oldRefs: oldRefs,
            newRefs: newRefs,
            disposition: .deleteMismatched
        )
        #expect(!FileManager.default.fileExists(atPath: textFile.path))
    }

    @Test("invalidating a chapter leaves no artifact and never re-creates the book directory")
    func invalidatingChapterLeavesNothingBehind() async throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.container) }
        let bookId = UUID()
        let repository = ChapterCacheRepository(rootDirectory: roots.storage.textRoot)

        // A failed fetch used to write a `.failed` marker, and writing it began with
        // `createDirectory(withIntermediateDirectories:)`. A fetch failing just after
        // 移除下載 therefore re-created the directory removal had deleted and refilled it,
        // which is why removing a download mid-flight left the book unreadable.
        let bookDirectory = roots.storage.textBookDirectory(bookId: bookId)
        repository.clearChapterCache(bookId: bookId, chapterIndex: 0)
        #expect(!FileManager.default.fileExists(atPath: bookDirectory.path))

        let store = OfflineChapterStore(roots: roots.storage, imageDownloader: StubImageDownloader())
        let state = await store.validationState(
            bookId: bookId,
            chapterIndex: 0,
            expectedSourceURL: "https://example.com/1",
            expectedTOCTitle: "第一章",
            requiresManga: false,
            hasBookSource: true
        )

        #expect(state == .incomplete)
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
