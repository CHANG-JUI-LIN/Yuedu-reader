import Foundation
import ReadiumZIPFoundation

/// Brings a converted Aozora book up to this build's converter before it opens
/// (Phase 1b, Task 20). Only a change that leaves every chapter's text as it was is
/// applied: reading positions index that text, and a text change ships with a
/// position migration (Phase 1c), never alone. Opening never waits on a failure;
/// the caller logs it and opens the EPUB it has.
@MainActor
enum AozoraBookRegenerator {
    enum Outcome: Equatable, Sendable {
        case notAozora
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

    /// `readerID` is the reader asking, which does not count as another reader.
    static func prepare(book: ReadingBook, store: BookStore, readerID: UUID? = nil) async throws -> Outcome {
        guard let aozora = book.aozora else { return .notAozora }
        let epub = StorageLocations.bookFile(book.contentFilename)
        let original = StorageLocations.bookFile(aozora.originalFilename)
        let inUse = readerID.map { ReadingResourceUsage.shared.isInUse(bookID: book.id, besides: $0) }
            ?? ReadingResourceUsage.shared.isInUse(bookID: book.id)
        let manifest = await recordedManifest(in: epub)
        if let manifest {
            if manifest.converterVersion == AozoraEPUBWriter.converterVersion { return .current }
            if manifest.converterVersion > AozoraEPUBWriter.converterVersion {
                log("an EPUB from a newer converter stays as it is", book, manifest)
                return .newer
            }
            if manifest.textVersion < AozoraEPUBWriter.textVersion {
                log("an older text version needs a position migration first", book, manifest)
                return .olderTextVersion
            }
        }
        guard !inUse else {
            log("another reader has the book open; regenerating on a later open", book, manifest)
            return .inUse
        }
        guard FileManager.default.fileExists(atPath: original.path) else {
            log("the original is not on this device yet; regenerating on a later open", book, manifest)
            return .originalMissing
        }
        return try await SourcePerfTrace.spanAsync("aozora.regenerate", aozora.originalFilename) {
            let isZip = original.pathExtension.lowercased() == "zip"
            let identifier = manifest?.identifier
            guard let converted = try await Task.detached(priority: .userInitiated, operation: {
                try await AozoraBookImporter.convert(original, isZip: isZip, identifier: identifier)
            }).value else {
                throw AozoraBookImporter.ImportError.undecodable(aozora.originalFilename)
            }
            defer { AozoraBookImporter.remove(converted.workDirectory, reason: "work folder") }
            _ = try await PublicationSession.open(sourceURL: converted.epub)
            if let manifest, !sameText(manifest, converted.manifest) {
                log("a chapter's text would change; it needs a position migration first", book, manifest)
                return .textChanged
            }
            _ = try FileManager.default.replaceItemAt(epub, withItemAt: converted.epub)
            removeSpineCache(for: epub)
            AppLogger.parse("[Aozora] regenerated a converted book", context: [
                "book": book.id.uuidString,
                "from": manifest.map { "\($0.converterVersion)" } ?? "none",
                "to": "\(AozoraEPUBWriter.converterVersion)",
            ])
            return .regenerated
        }
    }

    /// The EPUB's `yuedu-aozora.json`; nil when it is missing or unreadable, which is
    /// logged and treated as version 0.
    nonisolated static func recordedManifest(in epub: URL) async -> AozoraEPUBManifest? {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-manifest-\(UUID().uuidString).json")
        defer { AozoraBookImporter.remove(staging, reason: "manifest copy") }
        do {
            let archive = try await Archive(url: epub, accessMode: .read)
            guard let entry = try await archive.get(AozoraEPUBWriter.manifestPath) else {
                AppLogger.parse("[Aozora] a converted book has no manifest", context: ["file": epub.lastPathComponent],
                                level: .notice)
                return nil
            }
            _ = try await archive.extract(entry, to: staging)
            return try JSONDecoder().decode(AozoraEPUBManifest.self, from: Data(contentsOf: staging))
        } catch {
            AppLogger.error("Aozora manifest could not be read", error: error, context: ["file": epub.lastPathComponent])
            return nil
        }
    }

    /// Every chapter's length and SHA-256, in order.
    static func sameText(_ old: AozoraEPUBManifest, _ new: AozoraEPUBManifest) -> Bool {
        old.chapters.count == new.chapters.count
            && zip(old.chapters, new.chapters).allSatisfy { $0.length == $1.length && $0.sha256 == $1.sha256 }
    }

    /// `PublicationSession` caches a book's spine by its file name, which
    /// regeneration keeps.
    private static func removeSpineCache(for epub: URL) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = epub.lastPathComponent.replacingOccurrences(of: ".epub", with: "")
        AozoraBookImporter.remove(caches.appendingPathComponent("spine_cache_\(name).json"), reason: "spine cache")
    }

    private static func log(_ message: String, _ book: ReadingBook, _ manifest: AozoraEPUBManifest?) {
        AppLogger.parse("[Aozora] \(message)", context: [
            "book": book.id.uuidString,
            "converterVersion": manifest.map { "\($0.converterVersion)" } ?? "none",
            "textVersion": manifest.map { "\($0.textVersion)" } ?? "none",
        ], level: .notice)
    }
}
