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

    static func resolve(copy book: ReadingBook, record: SourceRecord, decisions: [WorkDecision]) -> CopyMetadata {
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
            author: resolved(.authors, copyValue: .texts(record.authors))
        )
    }
}

extension BookStore {
    /// `CopyMetadata` for a shelf copy, with the record and decisions the work index uses.
    @MainActor
    func copyMetadata(of book: ReadingBook) -> CopyMetadata {
        let record = SourceRecord.derived(from: book, context: WorkIndexService.liveContext(for: [book]))
        return .resolve(copy: book, record: record, decisions: workDecisions.decisions(involving: record.copyKey ?? record.key))
    }
}
