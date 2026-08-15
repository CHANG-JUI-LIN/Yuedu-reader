import Foundation
import Testing
@testable import yuedu_app

/// The custom-cover (封面搜索 / 相簿) storage contract.
///
/// The routing exists for one reason: 設定 → 快取管理 empties the cover cache
/// wholesale, and a cover the user picked from their photo library cannot be
/// downloaded again. If a custom cover ever resolves back into the cache root,
/// clearing the cache silently destroys it.
@Suite("Custom cover storage")
struct CustomCoverStorageTests {
    @Test("a user-set cover resolves outside the wipeable cover cache")
    func customCoverLivesOutsideCoverCache() {
        let filename = UUID().uuidString
            + StorageLocations.customCoverFilenameMarker
            + "abcd1234.jpg"

        let resolved = StorageLocations.coverFile(filename)

        #expect(resolved.deletingLastPathComponent() == StorageLocations.customCovers)
        #expect(resolved.deletingLastPathComponent() != StorageLocations.covers)
    }

    @Test("a downloaded source cover still resolves into the cover cache")
    func downloadedCoverStaysInCoverCache() {
        let resolved = StorageLocations.coverFile("\(UUID().uuidString)_cover.jpg")

        #expect(resolved.deletingLastPathComponent() == StorageLocations.covers)
    }

    @Test("a book only counts as customized once the user sets a cover")
    func hasCustomCoverTracksTheUsersChoice() {
        var book = ReadingBook(title: "測試書", author: "測試作者", contentFilename: "test.txt")
        #expect(!book.hasCustomCover)

        book.customCoverUrl = "https://example.com/cover.jpg"
        #expect(book.hasCustomCover)

        book.customCoverUrl = ReadingBook.localCustomCoverMarker
        #expect(book.hasCustomCover)

        book.customCoverUrl = nil
        #expect(!book.hasCustomCover)
    }

    @Test("cover fields survive a metadata round trip")
    func coverFieldsRoundTrip() throws {
        var book = ReadingBook(title: "測試書", author: "測試作者", contentFilename: "test.txt")
        book.coverUrl = "https://example.com/source-cover.jpg"
        book.coverImagePath = "custom\(StorageLocations.customCoverFilenameMarker)aaaa1111.jpg"
        book.customCoverUrl = "https://example.com/picked-cover.jpg"
        book.originalCoverImagePath = "original_cover.jpg"

        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: data)

        #expect(decoded.customCoverUrl == book.customCoverUrl)
        #expect(decoded.originalCoverImagePath == book.originalCoverImagePath)
        #expect(decoded.coverImagePath == book.coverImagePath)
    }
}
