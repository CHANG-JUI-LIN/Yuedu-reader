import Foundation

/// Moves app-internal data out of `Documents` and into Application Support, once.
///
/// Before `UIFileSharingEnabled` the two could share a directory harmlessly. Now
/// that `Documents` shows up in the Files app, anything left there is something the
/// user can delete — and `books_meta.json` is the whole bookshelf index, so deleting
/// it empties the shelf while every book file survives. See `StorageLocations` for the
/// boundary this establishes.
///
/// Must run before any store reads from disk: `BookStore.loadMeta()` and
/// `BookSourceStore.load()` both go straight to the new locations, so a launch that
/// skipped the migration would come up with an empty shelf. `yuedu_appApp.init()`
/// calls it as its first statement for that reason.
///
/// If any move fails the completion flag stays unset and the whole thing is retried
/// on the next launch. Individual `moveItem` calls are atomic, so a partial run
/// leaves every file intact at one location or the other — never truncated.
enum StorageMigration {
    private static let completedKey = "yd_app_storage_migration_v1_completed"

    static func runIfNeeded(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard !userDefaults.bool(forKey: completedKey) else { return }

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var succeeded = true

        // Covers first: their filenames are only knowable from the *old* metadata
        // file, so this has to happen while it is still where it always was.
        succeeded = moveCovers(documents: documents, fileManager: fileManager) && succeeded

        for item in relocations(documents: documents) {
            succeeded = move(from: item.source, to: item.destination, fileManager: fileManager) && succeeded
        }

        if succeeded {
            userDefaults.set(true, forKey: completedKey)
            AppLogger.info("StorageMigration complete")
        } else {
            AppLogger.error("StorageMigration incomplete — retrying next launch")
        }
    }

    /// Everything that keeps its name and simply changes parent directory.
    private static func relocations(documents: URL) -> [(source: URL, destination: URL)] {
        [
            (documents.appendingPathComponent("books_meta.json"), StorageLocations.booksMetadataFile),
            (documents.appendingPathComponent("book_sources.json"), StorageLocations.bookSourcesFile),
            (documents.appendingPathComponent("online_cache"), StorageLocations.onlineCache),
            (documents.appendingPathComponent("reading_position"), StorageLocations.readingPosition),
            (documents.appendingPathComponent("epub_charoffsets"), StorageLocations.epubCharOffsets),
            (documents.appendingPathComponent("toc_cache"), StorageLocations.tocCache),
            (documents.appendingPathComponent("book_info_cache"), StorageLocations.bookInfoCache),
            (documents.appendingPathComponent("txt_chapter_cache"), StorageLocations.txtChapterCache),
        ]
    }

    /// Cover JPEGs sat loose in the Documents root, mixed in with the user's own book
    /// files. The only record of which loose file is a cover is `coverImagePath` on
    /// each book, so read the old metadata to find them rather than guessing by
    /// extension — a `.jpg` the user put there themselves is not ours to move.
    private static func moveCovers(documents: URL, fileManager: FileManager) -> Bool {
        let legacyMetadata = documents.appendingPathComponent("books_meta.json")
        guard let data = try? Data(contentsOf: legacyMetadata) else {
            // No legacy metadata: either a fresh install or covers already moved.
            return true
        }
        guard let books = try? JSONDecoder().decode([ReadingBook].self, from: data) else {
            AppLogger.error(
                "StorageMigration could not decode legacy books_meta.json; covers left in place"
            )
            return false
        }

        var succeeded = true
        for name in Set(books.compactMap(\.coverImagePath)) where !name.isEmpty {
            succeeded = move(
                from: documents.appendingPathComponent(name),
                to: StorageLocations.coverFile(name),
                fileManager: fileManager
            ) && succeeded
        }
        return succeeded
    }

    /// - Returns: `true` when there is nothing left to do for this item, whether it
    ///   moved now, moved on an earlier attempt, or never existed.
    private static func move(from source: URL, to destination: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { return true }

        if fileManager.fileExists(atPath: destination.path) {
            // An earlier run already moved this and then failed further down the list,
            // so the new location is authoritative and the source is a stale copy.
            // Removing it is what keeps Documents clean for the Files app.
            do {
                try fileManager.removeItem(at: source)
                return true
            } catch {
                AppLogger.error(
                    "StorageMigration could not remove stale \(source.lastPathComponent)",
                    error: error
                )
                return false
            }
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            AppLogger.error(
                "StorageMigration could not move \(source.lastPathComponent)",
                error: error
            )
            return false
        }
    }
}
