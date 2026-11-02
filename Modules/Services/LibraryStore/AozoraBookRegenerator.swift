import Foundation

/// Brings a converted Aozora book up to this build's converter before it opens
/// (Phase 1b, Task 20), through the regenerator every converted format shares
/// (`ConvertedBookRegenerator`).
@MainActor
enum AozoraBookRegenerator {
    typealias Outcome = ConvertedBookRegenerator.Outcome

    /// `readerID` is the reader asking, which does not count as another reader.
    static func prepare(book: ReadingBook, store: BookStore, readerID: UUID? = nil) async throws -> Outcome {
        guard book.aozora != nil else { return .notConverted }
        return try await ConvertedBookRegenerator.prepare(book: book, store: store, readerID: readerID)
    }

    /// The EPUB's `yuedu-aozora.json`; nil when it is missing or unreadable, which is
    /// logged and treated as version 0.
    nonisolated static func recordedManifest(in epub: URL) async -> AozoraEPUBManifest? {
        await ConvertedBookRegenerator.manifest(AozoraEPUBManifest.self, at: AozoraEPUBWriter.manifestPath,
                                                in: epub, name: "Aozora")
    }
}
