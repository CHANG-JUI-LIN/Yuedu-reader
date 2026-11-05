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
        /// v3: the chapter rules `indexes` came from. nil in v1/v2 journals, whose indexes
        /// the hard-coded patterns built, so the next open re-splits them again.
        let rulesFingerprint: String?
    }

    /// Journal version written now; v1 and v2 remain replayable.
    private static let journalVersion = 3

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
            guard [1, 2, journalVersion].contains(journal.version), journal.bookId == preparation.bookId,
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
        if let unchanged = try publishIfUnchanged(indexes, preparation: preparation) {
            return Result(indexes: unchanged, restoredPosition: originalPosition)
        }
        let old = preparation.previousChapterIndexes ?? indexes
        // v7 indexes (re-split because the chapter rules changed) rendered with Aozora markup
        // removed, as the current builder does; v5/v6 rendered the markup as text.
        let oldParsesAozora = preparation.previousIndexVersion == TXTChapterParser.indexVersion
        let mapping = try TXTLocationMigration(file: preparation.mappedTextFile, oldIndexes: old, newIndexes: indexes,
                                               oldParsesAozoraMarkup: oldParsesAozora)
        let oldBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile,
                                                       chapterIndexes: old, parsesAozoraMarkup: oldParsesAozora)
        let newBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile, chapterIndexes: indexes)
        var oldStrings: [Int: String] = [:]
        var newStrings: [Int: String] = [:]

        func newString(_ index: Int) async throws -> String {
            if let built = newStrings[index] { return built }
            let built = try await newBuilder.buildChapter(
                at: index, settings: settings, themeTextColor: .label, themeBackgroundColor: .systemBackground
            ).attributedString.string
            newStrings[index] = built
            return built
        }

        func remap(_ position: CoreTextReadingPosition) async throws -> CoreTextReadingPosition {
            // Source identity preserves offsets when the rendering is unchanged too: the
            // same builder, or no Aozora markup for the older one to have shown.
            if let same = mapping.identicalChapter(for: position.spineIndex),
               oldParsesAozora || !AozoraMarkupParser.parse(
                   preparation.mappedTextFile.string(in: old[position.spineIndex].byteRange)).hasChanges {
                guard position.charOffset >= 0 else { throw TXTLocationMigration.Failure.invalidPosition }
                return .init(spineIndex: same, charOffset: position.charOffset)
            }
            guard old.indices.contains(position.spineIndex) else { throw TXTLocationMigration.Failure.invalidPosition }
            if oldStrings[position.spineIndex] == nil {
                oldStrings[position.spineIndex] = try await oldBuilder.buildChapter(
                    at: position.spineIndex, settings: settings,
                    themeTextColor: .label, themeBackgroundColor: .systemBackground
                ).attributedString.string
            }
            let anchor = try mapping.anchor(for: position, oldRendered: oldStrings[position.spineIndex]!)
            let target = try mapping.destination(for: anchor)
            return try mapping.position(for: anchor, in: target, newRendered: try await newString(target))
        }

        let position: CoreTextReadingPosition?
        if let originalPosition { position = try await remap(originalPosition) } else { position = nil }
        var bookmarks: [Bookmark] = []
        for bookmark in book.bookmarks {
            let start = try await remap(bookmark.position)
            let (endOffset, overflow) = bookmark.position.charOffset.addingReportingOverflow(bookmark.length)
            guard !overflow else { throw TXTLocationMigration.Failure.invalidPosition }
            var end = try await remap(.init(spineIndex: bookmark.position.spineIndex, charOffset: endOffset))
            if end.spineIndex != start.spineIndex {
                // A new chapter boundary now falls inside the highlight: it keeps its start
                // and ends with its chapter, as a highlight cannot span chapters.
                let length = (try await newString(start.spineIndex) as NSString).length
                AppLogger.cache("TXT re-split cut a highlight at its chapter end bookId=\(preparation.bookId) bookmark=\(bookmark.id)")
                end = .init(spineIndex: start.spineIndex, charOffset: length)
            }
            guard end.charOffset >= start.charOffset else { throw TXTLocationMigration.Failure.invalidPosition }
            bookmarks.append(Bookmark(
                chapterIndex: start.spineIndex, chapterTitle: indexes[start.spineIndex].title,
                position: start, length: end.charOffset - start.charOffset, kind: bookmark.kind,
                note: bookmark.note, excerpt: bookmark.excerpt, id: bookmark.id, date: bookmark.date,
                annotationStyle: bookmark.annotationStyle, annotationColor: bookmark.annotationColor
            ))
        }
        let journal = Journal(version: journalVersion, bookId: preparation.bookId, fingerprint: preparation.fingerprint,
                              fileSize: preparation.fileSize, encoding: preparation.encoding.rawValue, indexes: indexes,
                              originalPosition: originalPosition, position: position,
                              originalBookmarks: book.bookmarks, bookmarks: bookmarks,
                              rulesFingerprint: preparation.ruleSet.fingerprint)
        guard positions.loadSync(for: preparation.bookId.uuidString) == originalPosition,
              store.readingBook(id: preparation.bookId)?.bookmarks == book.bookmarks else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        return try await commit(journal, preparation: preparation, store: store, positions: positions, url: journalURL)
    }

    /// The index a page outside the reader may list (作品詳情's 目錄): the published one, or
    /// the first one of a book neither read nor annotated, published as `complete` publishes
    /// it, so a position saved at one of its chapters is one the reader can open. nil when
    /// publishing needs the reader: a journal to replay, or locations to map onto a new index.
    static func indexForListing(
        _ preparation: TXTReaderPreparation,
        store: BookStore,
        positions: any ReadingPositionStore
    ) async throws -> [TXTMappedChapterIndex]? {
        let journalURL = StorageLocations.readingPosition
            .appendingPathComponent("\(preparation.bookId.uuidString).txt-reindex.json")
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        if let current = preparation.cachedChapterIndexes { return current }
        if preparation.previousChapterIndexes != nil {
            let indexes = await Task.detached(priority: .userInitiated) {
                TXTReaderPreparationService.buildChapterIndexes(for: preparation)
            }.value
            // Locations need no mapping when the new rules split the book the same way.
            return try publishIfUnchanged(indexes, preparation: preparation)
        }
        guard let book = store.readingBook(id: preparation.bookId),
              book.bookmarks.isEmpty, positions.loadSync(for: preparation.bookId.uuidString) == nil else { return nil }
        let indexes = await Task.detached(priority: .userInitiated) {
            TXTReaderPreparationService.buildChapterIndexes(for: preparation)
        }.value
        // A reader opened meanwhile owns the publication from here.
        guard !FileManager.default.fileExists(atPath: journalURL.path),
              store.readingBook(id: preparation.bookId)?.bookmarks.isEmpty == true,
              positions.loadSync(for: preparation.bookId.uuidString) == nil else { return nil }
        let journal = Journal(version: journalVersion, bookId: preparation.bookId, fingerprint: preparation.fingerprint,
                              fileSize: preparation.fileSize, encoding: preparation.encoding.rawValue, indexes: indexes,
                              originalPosition: nil, position: nil, originalBookmarks: [], bookmarks: [],
                              rulesFingerprint: preparation.ruleSet.fingerprint)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        return try await commit(journal, preparation: preparation, store: store, positions: positions, url: journalURL).indexes
    }

    /// Republishes an index from other chapter rules under the current ones when they split
    /// the book identically, so no saved location moves: same chapters, and (for a v7 index)
    /// the same rendering. nil when locations must be mapped through `complete`.
    private static func publishIfUnchanged(_ indexes: [TXTMappedChapterIndex],
                                           preparation: TXTReaderPreparation) throws -> [TXTMappedChapterIndex]? {
        guard preparation.previousIndexVersion == TXTChapterParser.indexVersion,
              preparation.previousChapterIndexes == indexes else { return nil }
        try TXTChapterParser.writeCachedIndexes(indexes, bookId: preparation.bookId, fileSize: preparation.fileSize,
                                               fingerprint: preparation.fingerprint, encoding: preparation.encoding,
                                               rulesFingerprint: preparation.ruleSet.fingerprint)
        AppLogger.cache("TXT index unchanged under new chapter rules bookId=\(preparation.bookId) chapters=\(indexes.count)")
        return indexes
    }

    private static func commit(_ journal: Journal, preparation: TXTReaderPreparation, store: BookStore,
                               positions: any ReadingPositionStore, url: URL) async throws -> Result {
        let current = positions.loadSync(for: journal.bookId.uuidString)
        guard current == journal.originalPosition || current == journal.position else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        _ = try TXTLocationMigration(file: preparation.mappedTextFile, oldIndexes: journal.indexes, newIndexes: journal.indexes)
        try await store.commitTXTBookmarks(bookId: journal.bookId, original: journal.originalBookmarks, migrated: journal.bookmarks)
        if let position = journal.position {
            await positions.save(position, for: journal.bookId.uuidString)
            await positions.flush(for: journal.bookId.uuidString)
            guard positions.loadSync(for: journal.bookId.uuidString) == position else {
                throw TXTLocationMigration.Failure.invalidPosition
            }
        }
        try TXTChapterParser.writeCachedIndexes(journal.indexes, bookId: journal.bookId,
                                               fileSize: preparation.fileSize, fingerprint: preparation.fingerprint,
                                               encoding: preparation.encoding, rulesFingerprint: journal.rulesFingerprint)
        try FileManager.default.removeItem(at: url)
        AppLogger.cache("TXT index migration committed bookId=\(journal.bookId) chapters=\(journal.indexes.count) bookmarks=\(journal.bookmarks.count)")
        return Result(indexes: journal.indexes, restoredPosition: journal.position)
    }
}
