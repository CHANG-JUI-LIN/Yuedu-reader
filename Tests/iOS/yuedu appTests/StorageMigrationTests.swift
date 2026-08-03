import Foundation
import Testing
@testable import yuedu_app

/// The migration runs once, before any store reads from disk, and moves the shelf
/// index out of the now user-visible Documents directory. If it silently no-ops or
/// half-completes, the user opens the app to an empty bookshelf — so these cover the
/// retry path and the cover lookup that depends on reading the *old* metadata first.
@Suite("App storage migration", .serialized)
struct StorageMigrationTests {
    @Test("moves the shelf index, sources and caches out of Documents")
    func movesInternalDataOutOfDocuments() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.writeLegacy("books_meta.json", contents: "[]")
        try fixture.writeLegacy("book_sources.json", contents: "[]")
        try fixture.writeLegacyDirectory("online_cache", file: "1.txt", contents: "chapter")
        try fixture.writeLegacyDirectory("toc_cache", file: "a.json", contents: "{}")

        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        #expect(!fixture.legacyExists("books_meta.json"))
        #expect(!fixture.legacyExists("book_sources.json"))
        #expect(!fixture.legacyExists("online_cache"))
        #expect(!fixture.legacyExists("toc_cache"))

        #expect(fixture.text(at: StorageLocations.booksMetadataFile) == "[]")
        #expect(fixture.text(at: StorageLocations.bookSourcesFile) == "[]")
        #expect(fixture.text(at: StorageLocations.onlineCache.appendingPathComponent("1.txt")) == "chapter")
        #expect(fixture.text(at: StorageLocations.tocCache.appendingPathComponent("a.json")) == "{}")
    }

    @Test("moves cover images named by the legacy metadata, leaving other files alone")
    func movesCoversNamedByLegacyMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let coverName = "\(UUID().uuidString)_cover.jpg"
        let userFileName = "\(UUID().uuidString)-holiday-snap.jpg"
        try fixture.writeLegacy(coverName, contents: "cover-bytes")
        // A loose .jpg the user put there is not ours to move, which is why the
        // migration reads coverImagePath instead of sweeping by file extension.
        try fixture.writeLegacy(userFileName, contents: "user-bytes")

        var book = ReadingBook(title: "T", author: "A", contentFilename: "a.txt")
        book.coverImagePath = coverName
        try fixture.writeLegacyMetadata([book])

        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        #expect(!fixture.legacyExists(coverName))
        #expect(fixture.text(at: StorageLocations.coverFile(coverName)) == "cover-bytes")
        #expect(fixture.legacyExists(userFileName))
    }

    @Test("leaves the user's book files in Documents")
    func leavesBookFilesInPlace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let bookName = "\(UUID().uuidString).epub"
        try fixture.writeLegacy(bookName, contents: "epub-bytes")
        try fixture.writeLegacyMetadata([
            ReadingBook(title: "T", author: "A", contentFilename: bookName)
        ])

        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        #expect(fixture.legacyExists(bookName))
        #expect(fixture.text(at: StorageLocations.bookFile(bookName)) == "epub-bytes")
    }

    @Test("runs once, then no-ops")
    func runsOnlyOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.writeLegacy("books_meta.json", contents: "first")
        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)
        #expect(fixture.text(at: StorageLocations.booksMetadataFile) == "first")

        // A file reappearing at the legacy path after a completed migration is not
        // picked up: the flag is set, so nothing overwrites the live index.
        try fixture.writeLegacy("books_meta.json", contents: "second")
        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        #expect(fixture.text(at: StorageLocations.booksMetadataFile) == "first")
        #expect(fixture.legacyExists("books_meta.json"))
    }

    @Test("repairs covers imported to Documents after the migration")
    func repairsMisplacedCoversAfterMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        // Complete the normal one-time migration first.
        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        let coverName = "\(UUID().uuidString)_cover.jpg"
        var book = ReadingBook(title: "T", author: "A", contentFilename: "book.epub")
        book.coverImagePath = coverName
        try fixture.writeCurrentMetadata([book])
        try fixture.writeLegacy(coverName, contents: "cover-bytes")

        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        #expect(!fixture.legacyExists(coverName))
        #expect(fixture.text(at: StorageLocations.coverFile(coverName)) == "cover-bytes")
    }

    @Test("a stale legacy copy is removed when the destination already exists")
    func removesStaleLegacyCopyOnRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        // Simulates an earlier run that moved this file and then failed further down
        // the list: the new location is authoritative, the old one is a leftover.
        try fixture.write("authoritative", to: StorageLocations.booksMetadataFile)
        try fixture.writeLegacy("books_meta.json", contents: "stale")

        StorageMigration.runIfNeeded(userDefaults: fixture.defaults)

        #expect(!fixture.legacyExists("books_meta.json"))
        #expect(fixture.text(at: StorageLocations.booksMetadataFile) == "authoritative")
    }

    // MARK: - Helpers

    /// Isolates each test: a private `UserDefaults` suite so the completion flag never
    /// leaks between tests, and tracked paths so nothing is left behind in the
    /// simulator's real Documents / Application Support directories. A class because
    /// it accumulates paths to clean up.
    private final class Fixture {
        struct SetUpFailure: Error {}

        let defaults: UserDefaults
        private let suiteName: String
        private var createdPaths: [URL] = []

        init() throws {
            let suiteName = "StorageMigrationTests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw SetUpFailure()
            }
            self.suiteName = suiteName
            self.defaults = defaults
        }

        var documents: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }

        func writeLegacy(_ name: String, contents: String) throws {
            try write(contents, to: documents.appendingPathComponent(name))
        }

        func writeLegacyMetadata(_ books: [ReadingBook]) throws {
            let data = try JSONEncoder().encode(books)
            let url = documents.appendingPathComponent("books_meta.json")
            try data.write(to: url, options: .atomic)
            createdPaths.append(url)
        }

        func writeCurrentMetadata(_ books: [ReadingBook]) throws {
            let data = try JSONEncoder().encode(books)
            try FileManager.default.createDirectory(
                at: StorageLocations.booksMetadataFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: StorageLocations.booksMetadataFile, options: .atomic)
            createdPaths.append(StorageLocations.booksMetadataFile)
        }

        func writeLegacyDirectory(_ name: String, file: String, contents: String) throws {
            let directory = documents.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(
                to: directory.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
            createdPaths.append(directory)
        }

        func write(_ contents: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            createdPaths.append(url)
        }

        func legacyExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path)
        }

        func text(at url: URL) -> String? {
            try? String(contentsOf: url, encoding: .utf8)
        }

        func cleanUp() {
            for path in createdPaths {
                try? FileManager.default.removeItem(at: path)
            }
            // Destinations the migration itself created.
            for destination in [
                StorageLocations.booksMetadataFile,
                StorageLocations.bookSourcesFile,
                StorageLocations.covers,
                StorageLocations.onlineCache,
                StorageLocations.tocCache,
            ] {
                try? FileManager.default.removeItem(at: destination)
            }
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
