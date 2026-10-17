import Foundation
import ReadiumShared

/// Unified library 1b: what each kind of import knows beyond title and author, as an
/// `ImportedMetadata` for the copy's sidecar. Pure functions over values the import already
/// holds; they never change the copy (design D1).
enum ImportedMetadataCapture {
    // MARK: - EPUB

    static func epub(
        copy: ReadingBook,
        sourceItem: SourceItemKey,
        identifiers: [PublicationSession.OPFIdentifier],
        languages: [String],
        description: String?,
        subjects: [String],
        publishers: [String],
        published: Date?,
        series: EPUBSeries? = nil,
        now: Date = Date()
    ) -> ImportedMetadata {
        let read = epubFields(sourceItem: sourceItem, identifiers: identifiers, languages: languages, description: description,
                              subjects: subjects, publishers: publishers, published: published, series: series, now: now)
        return ImportedMetadata(copyID: copy.id, sourceItem: sourceItem, identifiers: read.identifiers, values: read.values)
    }

    /// What an EPUB's package says, for a copy (1b) or for a record WebDAV indexing found (2e):
    /// one reading of the OPF either way.
    static func epubFields(
        sourceItem: SourceItemKey,
        identifiers: [PublicationSession.OPFIdentifier],
        languages: [String],
        description: String?,
        subjects: [String],
        publishers: [String],
        published: Date?,
        series: EPUBSeries? = nil,
        now: Date = Date()
    ) -> (identifiers: [ExternalIdentifier], values: [MetadataValue]) {
        var values: [MetadataValue] = []
        func add(_ field: MetadataField, _ payload: MetadataPayload?) {
            guard let payload else { return }
            values.append(MetadataValue(field: field, value: payload, provider: sourceItem.instance, sourceItem: sourceItem, fetchedAt: now))
        }
        add(.language, texts(languages))
        add(.intro, text(description.map(plainText)))
        add(.tags, texts(subjects))
        add(.publisher, text(publishers.first))
        add(.publishedDate, published.map(MetadataPayload.date))
        // 系列下一本 (5d-6b) reads the number; one without a series name says nothing.
        if let series, let name = text(series.name) {
            add(.series, name)
            if let position = series.position, position.isFinite { add(.seriesIndex, .number(position)) }
        }
        return (unique(identifiers.compactMap { classify($0, in: identifiers) }), values)
    }

    /// The series an EPUB's package names first, and the book's number in it: Calibre's
    /// `calibre:series`/`series_index`, or EPUB 3's `belongs-to-collection` with
    /// `group-position`, as Readium reads them (`Metadata.belongsToSeries`).
    struct EPUBSeries: Hashable, Sendable {
        var name: String
        var position: Double?

        init(name: String, position: Double?) {
            self.name = name
            self.position = position
        }

        init?(_ metadata: Metadata) {
            guard let first = metadata.belongsToSeries.first else { return nil }
            self.init(name: first.name, position: first.position)
        }
    }

    /// An OPF identifier as an `ExternalIdentifier`: ISBNs as `isbn13`, a Calibre book's uuid
    /// as `calibreUUID`, anything else compared only within `epubUniqueIdentifier`.
    ///
    /// Calibre writes two identifiers: its application id, the book's number in that library
    /// or a random uuid, and the book's uuid, the one its content server names entries by.
    /// - OPF 2 (`metadata_to_opf` in calibre's `opf2.py`): `opf:scheme="calibre"` and
    ///   `opf:scheme="uuid"`.
    /// - OPF 3 (`set_identifiers` in `opf3.py`), which has no `opf:scheme`: the text
    ///   `calibre:<id>` and `uuid:<uuid>`.
    ///
    /// Other tools (Sigil) also write `opf:scheme="UUID"`, so a uuid counts as Calibre's only
    /// in a package that also has Calibre's own identifier.
    static func classify(
        _ identifier: PublicationSession.OPFIdentifier,
        in package: [PublicationSession.OPFIdentifier] = []
    ) -> ExternalIdentifier? {
        let value = identifier.value
        let lowered = value.lowercased()
        let scheme = identifier.scheme?.lowercased()
        if isCalibreApplicationID(identifier) {
            // The application id: a library's book number, or a uuid made for one export.
            return nil
        }
        if package.contains(where: isCalibreApplicationID) {
            if scheme == "uuid", let uuid = ExternalIdentifier.normalized(.calibreUUID, value) { return uuid }
            if scheme == nil, lowered.hasPrefix("uuid:"),
               let uuid = ExternalIdentifier.normalized(.calibreUUID, String(value.dropFirst("uuid:".count))) {
                return uuid
            }
        }
        if scheme == "isbn" {
            return ExternalIdentifier.normalized(.isbn13, value)
        }
        if lowered.hasPrefix("urn:isbn:") || lowered.hasPrefix("isbn:") {
            return ExternalIdentifier.normalized(.isbn13, value)
        }
        let isbnShape = value.allSatisfy { $0.isNumber || $0 == "-" || $0 == " " || $0 == "X" || $0 == "x" }
        if isbnShape, let isbn = ExternalIdentifier.normalized(.isbn13, value) {
            return isbn
        }
        if lowered.hasPrefix("urn:uuid:") {
            return ExternalIdentifier.normalized(.epubUniqueIdentifier, String(lowered.dropFirst("urn:uuid:".count)))
        }
        return ExternalIdentifier.normalized(.epubUniqueIdentifier, value)
    }

    private static func isCalibreApplicationID(_ identifier: PublicationSession.OPFIdentifier) -> Bool {
        let scheme = identifier.scheme?.lowercased()
        return scheme == "calibre" || (scheme == nil && identifier.value.lowercased().hasPrefix("calibre:"))
    }

    // MARK: - Remote libraries

    static func remote(
        item: RemoteLibraryItem,
        copy: ReadingBook,
        sourceItem: SourceItemKey,
        connectionKind: RemoteLibraryKind?,
        now: Date = Date()
    ) -> ImportedMetadata {
        var values: [MetadataValue] = []
        func add(_ field: MetadataField, _ payload: MetadataPayload?) {
            guard let payload else { return }
            values.append(MetadataValue(field: field, value: payload, provider: sourceItem.instance, sourceItem: sourceItem, fetchedAt: now))
        }
        add(.intro, text(item.summary))
        if item.authorNames.count > 1 { add(.authors, texts(item.authorNames)) }
        // `.texts`, as every other capture writes it: one field has one shape.
        add(.language, texts([item.language].compactMap { $0 }))
        let kind = connectionKind ?? .opds
        let identifiers = item.identifiers.flatMap { SourceRecord.identifiers(inEntryID: $0, connectionKind: kind) }
            + SourceRecord.identifiers(inEntryID: item.id, connectionKind: kind)
        return ImportedMetadata(copyID: copy.id, sourceItem: sourceItem, identifiers: unique(identifiers), values: values)
    }

    // MARK: - Calibre wireless

    /// From the metadata dictionary Calibre sends with a book: `uuid`, `isbn`,
    /// `identifiers`, `languages`, `tags`, `comments`, `series`, `series_index`, `publisher`
    /// and `pubdate`.
    ///
    /// The copy itself stays a local copy (`sourceItem` is `.copy`), but its values are
    /// Calibre's: they are attributed to the sending library, so they sit beside the OPF's
    /// values from the EPUB import instead of replacing them.
    static func calibre(
        metadata: [String: CalibreJSON],
        copy: ReadingBook,
        libraryID: String,
        now: Date = Date()
    ) -> ImportedMetadata {
        let provider = calibreWirelessInstance(libraryID: libraryID)
        let calibreItem = SourceItemKey(instance: provider, item: metadata["uuid"]?.string?.lowercased() ?? copy.id.uuidString.lowercased())
        var values: [MetadataValue] = []
        func add(_ field: MetadataField, _ payload: MetadataPayload?) {
            guard let payload else { return }
            values.append(MetadataValue(field: field, value: payload, provider: provider, sourceItem: calibreItem, fetchedAt: now))
        }
        var identifiers: [ExternalIdentifier] = []
        if let uuid = metadata["uuid"]?.string, let identifier = ExternalIdentifier.normalized(.calibreUUID, uuid) {
            identifiers.append(identifier)
        }
        let isbns = [metadata["isbn"]?.string, metadata["identifiers"]?.object?["isbn"]?.string].compactMap { $0 }
        identifiers += isbns.compactMap { ExternalIdentifier.normalized(.isbn13, $0) }

        add(.language, texts(metadata["languages"]?.array?.compactMap(\.string) ?? []))
        add(.tags, texts(metadata["tags"]?.array?.compactMap(\.string) ?? []))
        add(.intro, text(metadata["comments"]?.string.map(plainText)))
        add(.series, text(metadata["series"]?.string))
        if case .number(let index) = metadata["series_index"], index.isFinite, metadata["series"]?.string?.isEmpty == false {
            add(.seriesIndex, .number(index))
        }
        add(.publisher, text(metadata["publisher"]?.string))
        add(.publishedDate, metadata["pubdate"]?.string.flatMap(isoDate).map(MetadataPayload.date))
        return ImportedMetadata(copyID: copy.id, sourceItem: .copy(copy.id), identifiers: unique(identifiers), values: values)
    }

    // MARK: - TXT

    /// What a TXT's own header says beyond title and author: its 文案／内容简介 and 标签 line.
    /// Nil when it says neither.
    static func txt(copy: ReadingBook, metadata: TXTBookMetadata, now: Date = Date()) -> ImportedMetadata? {
        let sourceItem = SourceItemKey.copy(copy.id)
        var values: [MetadataValue] = []
        if let intro = text(metadata.intro) {
            values.append(MetadataValue(field: .intro, value: intro, provider: sourceItem.instance, sourceItem: sourceItem, fetchedAt: now))
        }
        if let tags = texts(metadata.tags) {
            values.append(MetadataValue(field: .tags, value: tags, provider: sourceItem.instance, sourceItem: sourceItem, fetchedAt: now))
        }
        guard !values.isEmpty else { return nil }
        return ImportedMetadata(copyID: copy.id, sourceItem: sourceItem, identifiers: [], values: values)
    }

    /// A Calibre library that sends books over the wireless connection. It has no
    /// `RemoteLibraryConnection`, so its id is Calibre's own library id, marked as wireless.
    static func calibreWirelessInstance(libraryID: String) -> SourceInstanceKey {
        SourceInstanceKey(type: .calibre, id: "wireless:\(libraryID)")
    }

    // MARK: - Aozora Bunko

    static func aozora(work: AozoraWork, copy: ReadingBook, sourceItem: SourceItemKey, now: Date = Date()) -> ImportedMetadata {
        var values = [MetadataValue(field: .language, value: .texts(["ja"]), provider: sourceItem.instance, sourceItem: sourceItem, fetchedAt: now)]
        if let tags = texts([work.ndc, work.kanaStyle]) {
            values.append(MetadataValue(field: .tags, value: tags, provider: sourceItem.instance, sourceItem: sourceItem, fetchedAt: now))
        }
        return ImportedMetadata(
            copyID: copy.id,
            sourceItem: sourceItem,
            identifiers: [ExternalIdentifier.normalized(.aozoraWork, work.id)].compactMap { $0 },
            values: values
        )
    }

    // MARK: - Helpers

    private static func text(_ value: String?) -> MetadataPayload? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return .text(trimmed)
    }

    private static func texts(_ values: [String]) -> MetadataPayload? {
        var seen = Set<String>()
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return cleaned.isEmpty ? nil : .texts(cleaned)
    }

    private static func unique(_ identifiers: [ExternalIdentifier]) -> [ExternalIdentifier] {
        var seen = Set<ExternalIdentifier>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    /// Descriptions and Calibre comments are often HTML; the sidecar keeps plain text.
    static func plainText(_ html: String) -> String {
        OPDSClient.plainMetadata(html, limit: 20_000)
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: - Reading a copy's package again

extension ImportedMetadataCapture {
    /// Reads a local EPUB copy's OPF and writes its sidecar, when it has none yet. A later
    /// work page calls this; nothing in Phase 1 does (Phase 1 plan, decision 8).
    @MainActor
    static func captureIfMissing(copy: ReadingBook, store: BookStore) async {
        guard store.importedMetadata.read(copyID: copy.id) == nil else { return }
        await reread(copy: copy, store: store)
    }

    /// Reads a local EPUB copy's OPF again and merges what it says into the copy's sidecar
    /// (`ImportedMetadataStore.write`: a value replaces the same field from the same place).
    /// Remote copies are skipped: the feed that described them is not at hand. Returns whether
    /// the package was read; a failure is logged.
    @MainActor
    @discardableResult
    static func reread(copy: ReadingBook, store: BookStore) async -> Bool {
        guard copy.remoteSource == nil, copy.source == "local_epub" else { return false }
        let url = StorageLocations.bookFile(copy.contentFilename)
        let package: PublicationSession.LocalPackageMetadata
        do {
            package = try await PublicationSession.localPackageMetadata(sourceURL: url)
        } catch {
            AppLogger.cache("⟐ imported metadata: the copy's EPUB could not be read", error: error,
                            context: ["copy": copy.id.uuidString])
            return false
        }
        let metadata = package.metadata
        let sourceItem = SourceRecord.derived(from: copy, context: .live()).key
        store.importedMetadata.write(epub(
            copy: copy,
            sourceItem: sourceItem,
            identifiers: package.identifiers,
            languages: metadata.languages,
            description: metadata.description,
            subjects: metadata.subjects.map(\.name),
            publishers: metadata.publishers.map(\.name),
            published: metadata.published,
            series: EPUBSeries(metadata)
        ))
        return true
    }
}
