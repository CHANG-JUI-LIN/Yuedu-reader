import Foundation
import Testing
@testable import yuedu_app

@Suite("Cache management service", .serialized)
struct CacheManagementServiceTests {
    @Test("snapshot counts regular files in every managed cache root")
    func snapshotCountsFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        try Data(repeating: 1, count: 3).write(
            to: fixture.roots.chapters.appendingPathComponent("chapter.txt")
        )
        try Data(repeating: 2, count: 5).write(
            to: fixture.roots.ttsAudio.appendingPathComponent("chunk.audio")
        )
        try Data(repeating: 3, count: 7).write(
            to: fixture.roots.mangaImages.appendingPathComponent("page.jpg")
        )
        try Data(repeating: 4, count: 11).write(
            to: fixture.roots.covers.appendingPathComponent("cover.jpg")
        )

        let snapshot = CacheManagementService(roots: fixture.roots, diagnosticLog: nil).snapshot()

        #expect(snapshot.chapters == 3)
        #expect(snapshot.ttsAudio == 5)
        #expect(snapshot.mangaImages == 7)
        #expect(snapshot.covers == 11)
        #expect(snapshot.total == 26)
    }

    @Test("clearing one category leaves the other cache roots intact")
    func clearOneCategory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let chapter = fixture.roots.chapters.appendingPathComponent("chapter.txt")
        let cover = fixture.roots.covers.appendingPathComponent("cover.jpg")
        try Data("chapter".utf8).write(to: chapter)
        try Data("cover".utf8).write(to: cover)

        try CacheManagementService(roots: fixture.roots, diagnosticLog: nil).clear(.chapters)

        #expect(!FileManager.default.fileExists(atPath: chapter.path))
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(FileManager.default.fileExists(atPath: fixture.roots.chapters.path))
    }

    @Test("clearing all caches removes files but preserves cache roots")
    func clearAllCaches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        for (index, category) in CacheCategory.allCases.enumerated() {
            let file = fixture.roots[category].appendingPathComponent("(index).cache")
            try Data(repeating: UInt8(index), count: index + 1).write(to: file)
        }

        try CacheManagementService(roots: fixture.roots, diagnosticLog: nil).clearAll()
        let snapshot = CacheManagementService(roots: fixture.roots, diagnosticLog: nil).snapshot()

        #expect(snapshot.total == 0)
        for category in CacheCategory.allCases {
            #expect(FileManager.default.fileExists(atPath: fixture.roots[category].path))
        }
    }

    @Test("remote cleanup preserves active books, explicit offline files and reading metadata")
    func remoteCleanupKeepsActiveReading() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let cache = RemoteLibraryCache(root: fixture.roots.remoteBooks)
        let activeID = UUID()
        let inactiveID = UUID()
        let active = try cache.directory(bookID: activeID, version: "v1").appendingPathComponent("chapter.range")
        let inactive = try cache.directory(bookID: inactiveID, version: "v1").appendingPathComponent("chapter.range")
        let offline = fixture.container.appendingPathComponent("saved.epub")
        let progress = fixture.container.appendingPathComponent("books_meta.reading.json")
        try Data(repeating: 1, count: 13).write(to: active)
        try Data(repeating: 2, count: 17).write(to: inactive)
        try Data("owned book".utf8).write(to: offline)
        try Data("reading progress".utf8).write(to: progress)
        cache.retain(activeID)
        let service = CacheManagementService(roots: fixture.roots, diagnosticLog: nil, remoteLibraryCache: cache)
        #expect(service.snapshot().remoteBooks == 30)
        try service.clear(.remoteBooks)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: inactive.path))
        #expect(service.snapshot().remoteBooks == 13)
        #expect(FileManager.default.fileExists(atPath: offline.path))
        #expect(FileManager.default.fileExists(atPath: progress.path))
        cache.release(activeID)
        try service.clear(.remoteBooks)
        #expect(service.snapshot().remoteBooks == 0)
        #expect(FileManager.default.fileExists(atPath: offline.path))
        #expect(FileManager.default.fileExists(atPath: progress.path))
    }

    private func makeFixture() throws -> (container: URL, roots: CacheStorageRoots) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheManagementServiceTests-(UUID().uuidString)")
        let roots = CacheStorageRoots(
            chapters: container.appendingPathComponent("chapters", isDirectory: true),
            ttsAudio: container.appendingPathComponent("tts", isDirectory: true),
            mangaImages: container.appendingPathComponent("manga", isDirectory: true),
            covers: container.appendingPathComponent("covers", isDirectory: true),
            diagnostics: container.appendingPathComponent("diagnostics", isDirectory: true)
        )
        for category in CacheCategory.allCases {
            try FileManager.default.createDirectory(
                at: roots[category],
                withIntermediateDirectories: true
            )
        }
        return (container, roots)
    }
}

