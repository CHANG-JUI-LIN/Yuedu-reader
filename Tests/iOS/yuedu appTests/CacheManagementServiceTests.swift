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

        let snapshot = CacheManagementService(roots: fixture.roots).snapshot()

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

        try CacheManagementService(roots: fixture.roots).clear(.chapters)

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

        try CacheManagementService(roots: fixture.roots).clearAll()
        let snapshot = CacheManagementService(roots: fixture.roots).snapshot()

        #expect(snapshot.total == 0)
        for category in CacheCategory.allCases {
            #expect(FileManager.default.fileExists(atPath: fixture.roots[category].path))
        }
    }

    private func makeFixture() throws -> (container: URL, roots: CacheStorageRoots) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheManagementServiceTests-(UUID().uuidString)")
        let roots = CacheStorageRoots(
            chapters: container.appendingPathComponent("chapters", isDirectory: true),
            ttsAudio: container.appendingPathComponent("tts", isDirectory: true),
            mangaImages: container.appendingPathComponent("manga", isDirectory: true),
            covers: container.appendingPathComponent("covers", isDirectory: true)
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

