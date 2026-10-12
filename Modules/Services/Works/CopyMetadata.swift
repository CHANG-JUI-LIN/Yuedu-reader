import Foundation

/// What a detail page shows of a book on the shelf (unified library 5f-4d, decision 32): each
/// field by `MetadataResolver`'s precedence, so the reader's own edits come before what the
/// book's source says. A page reads it through `BookStore.copyMetadata(of:)` and never ranks
/// values itself. A nil field means the copy decides nothing, and the page shows its source's.
///
/// The cover is not here: a page draws the copy's own artwork (`HomeCardContent.Cover.shelf`),
/// custom cover included, as the shelf does.
struct CopyMetadata: Hashable {
    var title: String?
    var author: String?
    /// The description (decision 33): the reader's own (`ReadingBook.customIntro`), then by
    /// `MetadataResolver` the copy's own file, the place it came from (the page's live
    /// value first), other places.
    var intro: Intro?

    struct Intro: Hashable {
        var text: String
        /// Written by the reader in 編輯資訊.
        var isEdited: Bool
        /// The current book source's own description, as its page fetched it. Only then may
        /// the page read Legado's formats in it and run its actions (decision 33); any other
        /// description is plain text.
        var isSourcesOwn: Bool
    }

    /// - `sidecar`: the copy's sidecar values (`BookStore.copyIntroValues(of:)`).
    /// - `liveIntro`: the description the page's source just gave, if it is a source's page.
    static func resolve(copy book: ReadingBook, record: SourceRecord, decisions: [WorkDecision],
                        sidecar: [MetadataValue] = [], liveIntro: String? = nil, now: Date = Date()) -> CopyMetadata {
        let anchor = record.copyKey ?? record.key
        func resolved(_ field: MetadataField, copyValue: MetadataPayload) -> String? {
            let value = MetadataResolver.resolve(field, anchor: anchor, copySource: record.key.instance,
                                                 copyValue: copyValue, values: [], decisions: decisions)?.value
            let text: String
            switch value {
            case .text(let single): text = single
            case .texts(let names): text = names.joined(separator: "、")
            case .number, .date, nil: return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return CopyMetadata(
            title: resolved(.title, copyValue: .text(book.title)),
            author: resolved(.authors, copyValue: .texts(record.authors)),
            intro: intro(of: book, anchor: anchor, copySource: record.key.instance, sourceItem: record.key,
                         decisions: decisions, sidecar: sidecar, liveIntro: liveIntro, now: now)
        )
    }

    private static func intro(of book: ReadingBook, anchor: SourceItemKey, copySource: SourceInstanceKey, sourceItem: SourceItemKey,
                              decisions: [WorkDecision], sidecar: [MetadataValue], liveIntro: String?, now: Date) -> Intro? {
        if let own = book.customIntro?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty {
            return Intro(text: own, isEdited: true, isSourcesOwn: false)
        }
        var values = sidecar
        let live = liveIntro?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let live, !live.isEmpty {
            // The place the copy came from, newer than anything it stored.
            values.append(MetadataValue(field: .intro, value: .text(live), provider: copySource, sourceItem: sourceItem, fetchedAt: now))
        }
        guard let resolved = MetadataResolver.resolve(.intro, anchor: anchor, copySource: copySource, copyValue: nil,
                                                      values: values, decisions: decisions),
              case .text(let text) = resolved.value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isLive = live != nil && resolved.provenance == .provider(copySource, sourceItem: sourceItem, fetchedAt: now)
        return Intro(text: trimmed, isEdited: false, isSourcesOwn: isLive && copySource.type == .bookSource)
    }
}

extension BookStore {
    /// `CopyMetadata` for a shelf copy, with the record and decisions the work index uses.
    /// `sidecar` comes from `copyIntroValues(of:)`, read once by the page, not on every render.
    @MainActor
    func copyMetadata(of book: ReadingBook, sidecar: [MetadataValue] = [], liveIntro: String? = nil) -> CopyMetadata {
        let record = SourceRecord.derived(from: book, context: WorkIndexService.liveContext(for: [book]))
        return .resolve(copy: book, record: record, decisions: workDecisions.decisions(involving: record.copyKey ?? record.key),
                        sidecar: sidecar, liveIntro: liveIntro)
    }

    /// A copy's sidecar values for `copyMetadata(of:sidecar:liveIntro:)`. Reads a file.
    ///
    /// A Gutenberg copy imported before d7aa65ab stored the book's whole bibliographic record
    /// as its description (LoC No., Credits, EBook No., Downloads…). Its Summary field replaces
    /// it here, or it is dropped when the record has none, and the sidecar is written back so
    /// this happens once per copy. Delete this when no shelf can still hold such a sidecar.
    nonisolated func copyIntroValues(of book: ReadingBook) -> [MetadataValue] {
        guard let values = importedMetadata.read(copyID: book.id)?.values else { return [] }
        let repaired = Self.repairingGutenbergRecords(values)
        if repaired != values {
            AppLogger.cache("⟐ a Gutenberg record stored as a description was cut to its Summary", context: ["copy": book.id.uuidString])
            importedMetadata.rewriteValues(copyID: book.id) { Self.repairingGutenbergRecords($0) }
        }
        return repaired
    }

    nonisolated static func repairingGutenbergRecords(_ values: [MetadataValue]) -> [MetadataValue] {
        values.compactMap { value in
            guard value.field == .intro, value.provider.type == .gutenberg, case .text(let text) = value.value,
                  text.contains("EBook No.:") else { return value }
            var summary = value
            guard let kept = GutenbergBookDetail.recordSummary(text) else { return nil }
            summary.value = .text(kept)
            return summary
        }
    }
}
