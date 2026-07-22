import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter cache migration", .serialized)
struct ChapterCacheMigrationTests {
    @Test("package loader upgrades a downloaded legacy chapter")
    func packageLoaderUpgradesDownloadedLegacyChapter() throws {
        let bookId = UUID()
        let chapterIndex = 3
        let sourceURL = "https://example.com/book/3"
        let tocTitle = "第三章 舊下載"
        let content = "這是已經下載到本機的章節正文。"
        let cacheDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("online_cache")
            .appendingPathComponent(bookId.uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try content.write(
            to: cacheDirectory.appendingPathComponent("\(chapterIndex).txt"),
            atomically: true,
            encoding: .utf8
        )
        let metadata = CachedChapterMetadata(
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: tocTitle,
            contentChecksum: checksum(content),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: nil,
            failureReason: nil
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(
            to: cacheDirectory.appendingPathComponent("\(chapterIndex).meta.json"),
            options: .atomic
        )

        let package = ChapterCacheRepository().loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: sourceURL,
            expectedTOCTitle: tocTitle
        )

        #expect(package?.state == .cached)
        #expect(package?.content == content)
        #expect(package?.contentChecksum == checksum(content))
        #expect(
            FileManager.default.fileExists(
                atPath: cacheDirectory.appendingPathComponent("\(chapterIndex).package.json").path
            )
        )
    }

    private func checksum(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
