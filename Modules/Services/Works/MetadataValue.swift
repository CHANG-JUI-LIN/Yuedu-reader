import Foundation

// Unified library 1b: metadata values with their provenance (design §5, §8). Imports keep
// what they read in a per-copy sidecar (`ImportedMetadataStore`), never in `ReadingBook`,
// whose sync hash must not change (design D1).

enum MetadataField: String, Codable, Hashable, Sendable {
    case title, authors, cover, intro, tags, series, seriesIndex, language, publisher, publishedDate,
         wordCount, serialStatus
}

enum MetadataPayload: Hashable, Codable, Sendable {
    case text(String)
    case texts([String])
    case number(Double)
    case date(Date)
}

/// One field's value as one place gave it.
struct MetadataValue: Hashable, Codable, Sendable {
    var field: MetadataField
    var value: MetadataPayload
    /// The place the value came from; a reader's override uses `.library` / "user" (design §5).
    var provider: SourceInstanceKey
    var sourceItem: SourceItemKey?
    var fetchedAt: Date
}

/// What an import knew about a copy beyond its title and author: identifiers and metadata
/// values, written once per copy to `Works/metadata/<copy id>.json`.
struct ImportedMetadata: Hashable, Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var copyID: UUID
    /// The record of the copy's source at import, so a value's place survives a later 換源.
    var sourceItem: SourceItemKey
    var identifiers: [ExternalIdentifier]
    var values: [MetadataValue]

    /// True when there is nothing worth a file.
    var isEmpty: Bool { identifiers.isEmpty && values.isEmpty }
}
