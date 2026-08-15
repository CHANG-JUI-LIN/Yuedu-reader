import Foundation

/// Where the app keeps things on disk, in one place.
///
/// The split matters because `Documents` is user-visible in the Files app
/// (`UIFileSharingEnabled` in Info.plist): whatever lives there, the user can open,
/// copy — and delete. So `Documents` holds only files the user owns and would
/// recognise: the books they imported, the fonts and tab icons they added.
///
/// Everything the app maintains for itself lives under Application Support, which
/// the Files app cannot show. That boundary is the point: `books_meta.json` is the
/// entire bookshelf index, and deleting it by hand empties the shelf even though
/// every book file is still on disk. Covers and caches are there too — losing them
/// is only a re-download, but a folder of UUID-named JPEGs next to the user's books
/// is noise they would reasonably try to clean up.
///
/// Legacy installs kept all of it in `Documents`; `StorageMigration` moves them
/// once on launch.
enum StorageLocations {
    // MARK: - User-visible (Documents)

    /// The user's own book files (`.epub` / `.txt` / `.md`), manga archives and
    /// audiobook audio, plus the fonts (`fonts/`) and tab icons (`root-tab-icons/`)
    /// they imported. Visible in the Files app.
    ///
    /// Two legacy items also stay here, deliberately: `<id>_epub.json` and its
    /// `<id>_epub_assets/` directory, from an EPUB import format no longer written by
    /// any code path (`ReadingBook.isLegacyParsedEPUB`). The JSON *is* that book's
    /// `contentFilename`, so it belongs in Documents anyway, and its asset directory
    /// is only meaningful next to it.
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// A book's content file, resolved from the filename stored on `ReadingBook`.
    static func bookFile(_ filename: String) -> URL {
        documents.appendingPathComponent(filename)
    }

    // MARK: - App-internal (Application Support)

    /// Root for everything the app maintains itself. Backed up like Documents, but
    /// not reachable from the Files app.
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Unlike Documents, Application Support is not guaranteed to exist on iOS.
        ensureDirectory(url)
        return url
    }

    /// The bookshelf index. Deleting this used to empty the user's shelf.
    static var booksMetadataFile: URL {
        support.appendingPathComponent("books_meta.json")
    }

    /// Installed book sources.
    static var bookSourcesFile: URL {
        support.appendingPathComponent("book_sources.json")
    }

    /// Downloaded cover images, named by `ReadingBook.coverImagePath`.
    static var covers: URL {
        directory("Covers")
    }

    /// Covers the user set by hand in 書籍資訊 (封面搜索 / 相簿).
    ///
    /// Deliberately outside `covers`: 設定 → 快取管理 empties that directory
    /// wholesale on the premise that every cover in it can be downloaded again,
    /// and a picture the user chose from their photo library cannot.
    static var customCovers: URL {
        directory("CustomCovers")
    }

    /// Marker inside the filename that says a cover is user-set and therefore
    /// lives in `customCovers`. Encoded in the name so resolving a cover stays a
    /// string test — the bookshelf resolves one per row while scrolling, and a
    /// filesystem probe per cover is not worth paying for.
    static let customCoverFilenameMarker = "_cover_custom_"

    /// A cover image, resolved from the filename stored on `ReadingBook`.
    /// Every cover read in the app goes through here — the lookup used to be
    /// copy-pasted into five call sites, which is exactly how one gets missed.
    static func coverFile(_ filename: String) -> URL {
        if filename.contains(customCoverFilenameMarker) {
            return customCovers.appendingPathComponent(filename)
        }
        return covers.appendingPathComponent(filename)
    }

    /// Downloaded chapters of online books, per book id.
    static var onlineCache: URL {
        directory("online_cache")
    }

    /// Offline manga pages downloaded for online books, per book id.
    static var mangaCache: URL {
        directory("manga")
    }

    /// Temporary audio data synthesized by HTTP TTS.
    ///
    /// The current TTS engine keeps active chunks in memory; this directory is
    /// reserved for file-backed audio cache entries so cache management has one
    /// stable location if a provider writes synthesized audio to disk.
    static var ttsAudioCache: URL {
        directory("tts_audio_cache")
    }

    /// Per-book reading positions.
    static var readingPosition: URL {
        directory("reading_position")
    }

    /// Fixed-layout EPUB character-offset stores, per book id.
    static var epubCharOffsets: URL {
        directory("epub_charoffsets")
    }

    /// Book-source table-of-contents cache.
    static var tocCache: URL {
        directory("toc_cache")
    }

    /// Book-source book-detail cache.
    static var bookInfoCache: URL {
        directory("book_info_cache")
    }

    /// Parsed TXT chapter indexes.
    static var txtChapterCache: URL {
        directory("txt_chapter_cache")
    }

    // MARK: - Helpers

    /// Every internal subdirectory is created on first access, so callers never have
    /// to remember to; writes into a missing directory fail silently otherwise.
    private static func directory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    private static func ensureDirectory(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            AppLogger.error("StorageLocations could not create \(url.lastPathComponent)", error: error)
        }
    }
}
