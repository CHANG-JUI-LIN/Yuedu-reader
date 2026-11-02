import Foundation
import ReadiumZIPFoundation

/// Brings a book converted into an EPUB at import — an Aozora Bunko text, a MOBI or
/// AZW3 file — up to this build's converter before it opens. One regenerator serves
/// every format (MOBI plan, step 4); a format gives only where its manifest is, its
/// versions, and how to convert its original.
///
/// Only a change that leaves every chapter's text as it was is applied: reading
/// positions index that text, and a text change ships with a position migration, never
/// alone. Opening never waits on a failure; the caller logs it and opens the EPUB it has.
@MainActor
enum ConvertedBookRegenerator {
    enum Outcome: Equatable, Sendable {
        /// The book was not converted at import on this device.
        case notConverted
        /// The EPUB was written by this converter.
        case current
        case regenerated
        /// A newer build wrote it: never downgrade.
        case newer
        /// Some chapter's text would change; positions need a migration first.
        case textChanged
        /// The EPUB's text version is older; the same reason.
        case olderTextVersion
        /// The original has not reached this device yet; a later open tries again.
        case originalMissing
        /// Another reader has the book open; a later open tries again.
        case inUse
    }

    /// What the regenerator reads of a converter's manifest; every format's has these.
    struct Recorded: Decodable, Equatable, Sendable {
        struct Chapter: Decodable, Equatable, Sendable {
            var length: Int
            var sha256: String
        }

        var converterVersion: Int
        var textVersion: Int
        var identifier: String
        var chapters: [Chapter]
    }

    /// A format's converter, as the regenerator calls it.
    struct Converter: Sendable {
        /// Names the format in log lines (`[Aozora]`) and the span (`aozora.regenerate`).
        let name: String
        let manifestPath: String
        let converterVersion: Int
        let textVersion: Int
        /// Whether the book's positions, bookmarks and highlights are stamped with the text
        /// version its EPUB holds (`ConvertedTextVersions`). Not Aozora's yet: its records
        /// are unstamped, and read as version 1 they would all be refused.
        var stampsTextVersion = false
        /// Converts the original into an EPUB in a work folder, keeping the package's
        /// identifier when one is given. Off the main actor.
        let convert: @Sendable (_ original: URL, _ identifier: String?) async throws -> Converted
    }

    struct Converted: Sendable {
        let epub: URL
        let recorded: Recorded
        /// Removed once the EPUB is in place.
        let workDirectory: URL
    }

    /// `readerID` is the reader asking, which does not count as another reader.
    static func prepare(book: ReadingBook, store: BookStore, readerID: UUID? = nil) async throws -> Outcome {
        let converter: Converter
        let original: String
        if let aozora = book.aozora {
            (converter, original) = (AozoraBookImporter.converter, aozora.originalFilename)
        } else if let mobi = book.mobi, let filename = mobi.originalFilename {
            (converter, original) = (MOBIBookImporter.converter, filename)
        } else {
            return .notConverted
        }
        let epub = StorageLocations.bookFile(book.contentFilename)
        let inUse = readerID.map { ReadingResourceUsage.shared.isInUse(bookID: book.id, besides: $0) }
            ?? ReadingResourceUsage.shared.isInUse(bookID: book.id)
        return try await prepare(bookID: book.id, epub: epub, original: StorageLocations.bookFile(original),
                                 converter: converter, isInUse: inUse, spineCache: localSpineCache(for: epub))
    }

    /// `epub` need not exist yet: a remote library's book is converted on its first open,
    /// into its cache folder. `isInUse` says another reader has the EPUB open, and
    /// `spineCache` is where `PublicationSession` keeps its spine, removed with the EPUB
    /// it indexes.
    ///
    /// Runs before the book's reader exists (`BookReaderView`, `RemoteLibraryService`), so it
    /// also records the text version of the EPUB the reader will read, before anything
    /// restores a position against it: the manifest's, then the converter's once rebuilt.
    static func prepare(bookID: UUID, epub: URL, original: URL, converter: Converter,
                        isInUse: Bool, spineCache: URL) async throws -> Outcome {
        let exists = FileManager.default.fileExists(atPath: epub.path)
        let manifest = exists
            ? await manifest(Recorded.self, at: converter.manifestPath, in: epub, name: converter.name) : nil
        if converter.stampsTextVersion {
            ConvertedTextVersions.shared.set(manifest?.textVersion, for: bookID.uuidString)
        }
        if let manifest {
            if manifest.converterVersion == converter.converterVersion { return .current }
            if manifest.converterVersion > converter.converterVersion {
                log("an EPUB from a newer converter stays as it is", bookID, manifest, converter)
                return .newer
            }
            if manifest.textVersion < converter.textVersion {
                log("an older text version needs a position migration first", bookID, manifest, converter)
                return .olderTextVersion
            }
        }
        guard !(exists && isInUse) else {
            log("another reader has the book open; regenerating on a later open", bookID, manifest, converter)
            return .inUse
        }
        guard FileManager.default.fileExists(atPath: original.path) else {
            log("the original is not on this device yet; regenerating on a later open", bookID, manifest, converter)
            return .originalMissing
        }
        return try await SourcePerfTrace.spanAsync(converter.name.lowercased() + ".regenerate", original.lastPathComponent) {
            let identifier = manifest?.identifier
            let convert = converter.convert
            let converted = try await Task.detached(priority: .userInitiated) {
                try await convert(original, identifier)
            }.value
            defer { remove(converted.workDirectory, reason: "work folder", converter) }
            // Its spine cache stays in the work folder: by file name it would be every
            // conversion's `spine_cache_book.json`, read back unchecked by the next one.
            _ = try await PublicationSession.open(sourceURL: converted.epub, cacheDirectory: converted.workDirectory)
            if let manifest, !sameText(manifest, converted.recorded) {
                log("a chapter's text would change; it needs a position migration first", bookID, manifest, converter)
                return .textChanged
            }
            if exists {
                _ = try FileManager.default.replaceItemAt(epub, withItemAt: converted.epub)
            } else {
                try FileManager.default.moveItem(at: converted.epub, to: epub)
            }
            remove(spineCache, reason: "spine cache", converter)
            if converter.stampsTextVersion {
                ConvertedTextVersions.shared.set(converter.textVersion, for: bookID.uuidString)
            }
            AppLogger.parse("[\(converter.name)] \(exists ? "regenerated a converted book" : "converted a book on its first open")", context: [
                "book": bookID.uuidString,
                "from": manifest.map { "\($0.converterVersion)" } ?? "none",
                "to": "\(converter.converterVersion)",
            ])
            return .regenerated
        }
    }

    /// A converter's manifest in the EPUB; nil when it is missing or unreadable, which
    /// is logged and treated as version 0.
    nonisolated static func manifest<Manifest: Decodable>(_ type: Manifest.Type, at path: String, in epub: URL,
                                                          name: String) async -> Manifest? {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.lowercased())-manifest-\(UUID().uuidString).json")
        defer { remove(staging, reason: "manifest copy", name: name) }
        do {
            let archive = try await Archive(url: epub, accessMode: .read)
            guard let entry = try await archive.get(path) else {
                AppLogger.parse("[\(name)] a converted book has no manifest", context: ["file": epub.lastPathComponent],
                                level: .notice)
                return nil
            }
            _ = try await archive.extract(entry, to: staging)
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: staging))
        } catch {
            AppLogger.error("\(name) manifest could not be read", error: error, context: ["file": epub.lastPathComponent])
            return nil
        }
    }

    /// Every chapter's length and SHA-256, in order.
    static func sameText(_ old: Recorded, _ new: Recorded) -> Bool {
        old.chapters.count == new.chapters.count
            && zip(old.chapters, new.chapters).allSatisfy { $0.length == $1.length && $0.sha256 == $1.sha256 }
    }

    /// Where `PublicationSession` caches a local book's spine: by its file name, which
    /// regeneration keeps.
    private static func localSpineCache(for epub: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = epub.lastPathComponent.replacingOccurrences(of: ".epub", with: "")
        return caches.appendingPathComponent("spine_cache_\(name).json")
    }

    nonisolated private static func remove(_ url: URL, reason: String, _ converter: Converter) {
        remove(url, reason: reason, name: converter.name)
    }

    nonisolated private static func remove(_ url: URL, reason: String, name: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.error("\(name) regeneration could not remove its \(reason)", error: error,
                            context: ["file": url.lastPathComponent])
        }
    }

    private static func log(_ message: String, _ bookID: UUID, _ manifest: Recorded?, _ converter: Converter) {
        AppLogger.parse("[\(converter.name)] \(message)", context: [
            "book": bookID.uuidString,
            "converterVersion": manifest.map { "\($0.converterVersion)" } ?? "none",
            "textVersion": manifest.map { "\($0.textVersion)" } ?? "none",
        ], level: .notice)
    }
}

extension ReadingBook {
    /// The original a book converted at import keeps beside its EPUB, in the book files'
    /// folder: it is deleted, synced and sent back to Calibre with the book.
    var convertedOriginalFilename: String? { aozora?.originalFilename ?? mobi?.originalFilename }

    /// Converted into an EPUB at import, from an original kept beside it.
    var isConvertedAtImport: Bool { convertedOriginalFilename != nil }
}
