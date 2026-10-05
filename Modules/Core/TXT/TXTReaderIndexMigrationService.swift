import Foundation
import UIKit

/// One owner for index publication and location migration. A prepared journal is
/// replayed only after an interrupted multi-file commit; it contains final targets,
/// not a delta, so reopening never applies the mapping twice. Remove this recovery
/// path only if bookmarks, positions and indexes acquire a shared atomic store.
@MainActor
enum TXTReaderIndexMigrationService {
    struct Result {
        let indexes: [TXTMappedChapterIndex]
        let restoredPosition: CoreTextReadingPosition?
    }

    private struct Journal: Codable {
        let version: Int
        let bookId: UUID
        let fingerprint: String
        let fileSize: Int
        let encoding: UInt
        let indexes: [TXTMappedChapterIndex]
        let originalPosition: CoreTextReadingPosition?
        let position: CoreTextReadingPosition?
        let originalBookmarks: [Bookmark]
        let bookmarks: [Bookmark]
    }

    static func complete(
        _ preparation: TXTReaderPreparation,
        store: BookStore,
        positions: any ReadingPositionStore,
        settings: ReaderRenderSettings
    ) async throws -> Result {
        let journalURL = StorageLocations.readingPosition
            .appendingPathComponent("\(preparation.bookId.uuidString).txt-reindex.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard [1, 2].contains(journal.version), journal.bookId == preparation.bookId,
                  journal.fingerprint == preparation.fingerprint, journal.fileSize == preparation.fileSize,
                  journal.encoding == preparation.encoding.rawValue else {
                throw TXTLocationMigration.Failure.missingSourceIdentity
            }
            // v1 targets predate ruby removal. They are still final targets for
            // ordinary TXT, but cannot be replayed as v7 offsets for marked text.
            // Keep that journal intact until its historical targets can be
            // proven and projected, rather than publishing an ambiguous offset.
            if journal.version == 1 {
                guard journal.indexes.allSatisfy({
                    !AozoraMarkupParser.parse(preparation.mappedTextFile.string(in: $0.byteRange)).hasChanges
                }) else {
                    AppLogger.error("TXT pre-ruby migration journal requires location projection",
                                    context: ["bookId": journal.bookId.uuidString])
                    throw TXTLocationMigration.Failure.missingSourceIdentity
                }
            }
            return try await commit(journal, preparation: preparation, store: store, positions: positions, url: journalURL)
        }
        guard let book = store.readingBook(id: preparation.bookId) else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        let originalPosition = positions.loadSync(for: preparation.bookId.uuidString)
        if let current = preparation.cachedChapterIndexes {
            return Result(indexes: current, restoredPosition: originalPosition)
        }
        // An absent old index is harmless only for an unread/unannotated import.
        // Never guess which historical parser produced persisted chapter numbers.
        guard preparation.previousChapterIndexes != nil
                || (originalPosition == nil && book.bookmarks.isEmpty) else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        let indexes = await Task.detached(priority: .userInitiated) {
            TXTReaderPreparationService.buildChapterIndexes(for: preparation)
        }.value
        let old = preparation.previousChapterIndexes ?? indexes
        let mapping = try TXTLocationMigration(file: preparation.mappedTextFile, oldIndexes: old, newIndexes: indexes)
        let oldBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile,
                                                       chapterIndexes: old, parsesAozoraMarkup: false)
        let newBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile, chapterIndexes: indexes)
        var oldStrings: [Int: String] = [:]
        var newStrings: [Int: String] = [:]

        func remap(_ position: CoreTextReadingPosition) async throws -> CoreTextReadingPosition {
            let target = try mapping.destination(for: position.spineIndex)
            // Source identity preserves ordinary TXT offsets. Markup removal needs
            // the historical and current rendered strings even at equal boundaries.
            if old[position.spineIndex].byteRange == indexes[target].byteRange,
               old[position.spineIndex].title == indexes[target].title,
               !AozoraMarkupParser.parse(preparation.mappedTextFile.string(in: old[position.spineIndex].byteRange)).hasChanges {
                guard position.charOffset >= 0 else { throw TXTLocationMigration.Failure.invalidPosition }
                return .init(spineIndex: target, charOffset: position.charOffset)
            }
            if oldStrings[position.spineIndex] == nil {
                oldStrings[position.spineIndex] = try await oldBuilder.buildChapter(
                    at: position.spineIndex, settings: settings,
                    themeTextColor: .label, themeBackgroundColor: .systemBackground
                ).attributedString.string
            }
            if newStrings[target] == nil {
                newStrings[target] = try await newBuilder.buildChapter(
                    at: target, settings: settings, themeTextColor: .label, themeBackgroundColor: .systemBackground
                ).attributedString.string
            }
            return try mapping.map(position, oldRendered: oldStrings[position.spineIndex]!, newRendered: newStrings[target]!)
        }

        let position: CoreTextReadingPosition?
        if let originalPosition { position = try await remap(originalPosition) } else { position = nil }
        var bookmarks: [Bookmark] = []
        for bookmark in book.bookmarks {
            let start = try await remap(bookmark.position)
            let (endOffset, overflow) = bookmark.position.charOffset.addingReportingOverflow(bookmark.length)
            guard !overflow else { throw TXTLocationMigration.Failure.invalidPosition }
            let end = try await remap(.init(spineIndex: bookmark.position.spineIndex, charOffset: endOffset))
            guard start.spineIndex == end.spineIndex, end.charOffset >= start.charOffset else {
                throw TXTLocationMigration.Failure.invalidPosition
            }
            bookmarks.append(Bookmark(
                chapterIndex: start.spineIndex, chapterTitle: indexes[start.spineIndex].title,
                position: start, length: end.charOffset - start.charOffset, kind: bookmark.kind,
                note: bookmark.note, excerpt: bookmark.excerpt, id: bookmark.id, date: bookmark.date,
                annotationStyle: bookmark.annotationStyle, annotationColor: bookmark.annotationColor
            ))
        }
        let journal = Journal(version: 2, bookId: preparation.bookId, fingerprint: preparation.fingerprint,
                              fileSize: preparation.fileSize, encoding: preparation.encoding.rawValue, indexes: indexes,
                              originalPosition: originalPosition, position: position,
                              originalBookmarks: book.bookmarks, bookmarks: bookmarks)
        guard positions.loadSync(for: preparation.bookId.uuidString) == originalPosition,
              store.readingBook(id: preparation.bookId)?.bookmarks == book.bookmarks else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        return try await commit(journal, preparation: preparation, store: store, positions: positions, url: journalURL)
    }

    private static func commit(_ journal: Journal, preparation: TXTReaderPreparation, store: BookStore,
                               positions: any ReadingPositionStore, url: URL) async throws -> Result {
        let current = positions.loadSync(for: journal.bookId.uuidString)
        guard current == journal.originalPosition || current == journal.position else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        _ = try TXTLocationMigration(file: preparation.mappedTextFile, oldIndexes: journal.indexes, newIndexes: journal.indexes)
        try store.commitTXTBookmarks(bookId: journal.bookId, original: journal.originalBookmarks, migrated: journal.bookmarks)
        if let position = journal.position {
            await positions.save(position, for: journal.bookId.uuidString)
            await positions.flush(for: journal.bookId.uuidString)
            guard positions.loadSync(for: journal.bookId.uuidString) == position else {
                throw TXTLocationMigration.Failure.invalidPosition
            }
        }
        try TXTChapterParser.writeCachedIndexes(journal.indexes, bookId: journal.bookId,
                                               fileSize: preparation.fileSize, fingerprint: preparation.fingerprint,
                                               encoding: preparation.encoding)
        try FileManager.default.removeItem(at: url)
        AppLogger.cache("TXT index migration committed bookId=\(journal.bookId) chapters=\(journal.indexes.count) bookmarks=\(journal.bookmarks.count)")
        return Result(indexes: journal.indexes, restoredPosition: journal.position)
    }
}
