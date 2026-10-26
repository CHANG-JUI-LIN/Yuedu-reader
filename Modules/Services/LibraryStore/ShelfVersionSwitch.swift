import Foundation

/// 換源 between versions of one work (maintainer 2026-10-26: 「自己導入的書、來源配置、WebDAV、
/// Calibre、模組⋯都是相同地位」): the shelf book moves to another version, and the one it was
/// becomes a version of it, kept off the shelf so 換源 can switch back.
///
/// A version is a copy of its own (`ReadingBook`): its file, chapters, caches, AI data and
/// highlights belong to its text, so a switch never rewrites a copy's origin — only which copy
/// the shelf shows. The one exception stays where it was: between two 來源配置 the shelf book is
/// rebound in place (`OnlineBookSourceSwitch`), as a work has one 來源配置 copy (feedback #16).
///
/// What moves to the version taken on, and what stays with each copy:
/// - Moves: being on the shelf, the versions kept beside it (`versionOf`), 書架分組, a custom
///   cover and custom intro, the date it was added (the shelf keeps its place), 繼續閱讀's
///   hidden state, the book's reader settings (`BookReaderSettingsStore.carrySettings`), the
///   reading place and the bookmarks, each found again in the new chapter list
///   (`VersionPlaceMapping`).
/// - Stays: the copy's file and downloaded chapters, its sidecar (what its import read), AI
///   summaries / translations / character memory / chats and 多角色朗讀 casts (built from its
///   text), its own highlights (their ranges are offsets into its text), its 換源 cache, and the
///   work-index decisions anchored to its copy key.
@MainActor
struct ShelfVersionSwitch {
    /// A copy's chapter list, as its reader opens chapters; nil when it has none to list.
    typealias ChapterList = @MainActor (ReadingBook) async throws -> [OnlineChapterRef]?

    /// A copy the switch names is gone: deleted, or removed by a sync, since the list was shown.
    struct CopyMissing: LocalizedError {
        let id: UUID
        var errorDescription: String? { localized("這個版本已不在這台裝置上。") }
    }

    let store: BookStore
    let positionStore: ReadingPositionStore
    let chapters: ChapterList

    init(store: BookStore, positionStore: ReadingPositionStore, chapters: @escaping ChapterList) {
        self.store = store
        self.positionStore = positionStore
        self.chapters = chapters
    }

    init(store: BookStore, dependencies: AppDependencies) {
        self.init(store: store, positionStore: dependencies.readingPositionStore) { [store] book in
            if book.isOnline { return book.onlineChapters }
            return try await WorkTableOfContents.chapters(
                of: book, store: store, remoteLibrary: dependencies.remoteLibrary,
                positions: dependencies.readingPositionStore
            )
        }
    }

    /// The work's 來源配置 copy, reading from `origin`, for shelf book `shelfID` read from elsewhere:
    /// the one kept beside it, rebound to `origin` (a work has one 來源配置 copy, feedback #16);
    /// else a copy of `origin` read before and never shelved; else a new one, off the shelf until
    /// `commit` puts it there. Throws, changing nothing, when the rebind does
    /// (`OnlineBookSourceSwitch.commit`: an empty list).
    func sourceCopy(of shelfID: UUID, origin: BookOrigin, toc: TOCPackage,
                    sourceSwitch: OnlineBookSourceSwitch) async throws -> UUID {
        if let kept = store.keptVersions(of: shelfID).first(where: ShelfWork.isSourceCopy) {
            if kept.bookSourceId != origin.sourceId
                || OnlineBookURLKey.normalize(kept.bookInfoURL ?? kept.source) != OnlineBookURLKey.normalize(origin.bookUrl) {
                try await sourceSwitch.commit(bookId: kept.id, origin: origin, toc: toc)
            }
            return kept.id
        }
        guard let shelf = store.readingBook(id: shelfID) else { throw CopyMissing(id: shelfID) }
        if let read = store.onlineBook(sourceId: origin.sourceId, bookInfoURL: origin.bookUrl, onShelf: false),
           read.versionOf == nil {
            store.updateOnlineChapters(bookId: read.id, chapters: toc.chapters, runtimeVariables: toc.runtimeVariables)
            return read.id
        }
        return store.addOnlineBook(
            name: shelf.title, author: shelf.author, sourceId: origin.sourceId,
            bookInfoURL: origin.bookUrl, tocURL: origin.tocUrl.isEmpty ? nil : origin.tocUrl,
            coverUrl: origin.coverUrl, runtimeVariables: origin.runtimeVariables,
            chapters: toc.chapters, isInBookshelf: false
        ).id
    }

    /// Moves `currentID`'s place to `targetID`, and keeps `currentID` as a version of it.
    ///
    /// - Parameters:
    ///   - spine: the place on screen; nil reads the stored one.
    ///   - carriesPlace: false when the target was read last and keeps its own place
    ///     (加入書架 of a copy just read, `ShelfWorkService.shelveReadCopy`).
    /// - Returns: where the target's reader opens — its entry for the chapter being read — or
    ///   nil when no chapter could be found again (either list is empty), or the place is not
    ///   carried, and it opens where it was left.
    @discardableResult
    func commit(from currentID: UUID, to targetID: UUID, readingFrom spine: Int? = nil,
                carriesPlace: Bool = true) async throws -> ReaderTOCTarget? {
        guard currentID != targetID else { return nil }
        guard let current = store.readingBook(id: currentID) else { throw CopyMissing(id: currentID) }
        guard let target = store.readingBook(id: targetID) else { throw CopyMissing(id: targetID) }
        let place = carriesPlace ? spine ?? positionStore.loadSync(for: currentID.uuidString)?.spineIndex : nil
        let oldList = try await chapters(current) ?? []
        let newList = try await chapters(target) ?? []
        try Task.checkCancellation()

        var taken = target
        taken.onlineChapters = nil
        taken.versionOf = nil
        taken.isInBookshelf = current.isInBookshelf
        taken.addedDate = current.addedDate
        taken.continueReadingHiddenAt = current.continueReadingHiddenAt
        // The copy read from now on: 繼續閱讀 and 最近閱讀 lead with it, as an open does. A reader
        // the shelf's card opened never stamps its own open (`BookReaderView`).
        if current.lastOpenedDate != nil { taken.lastOpenedDate = Date() }
        if !current.group.isEmpty { taken.group = current.group }
        if let intro = current.customIntro { taken.customIntro = intro }
        if current.hasCustomCover {
            // Every copy keeps the cover files it points at until it is deleted.
            taken.customCoverUrl = current.customCoverUrl
            taken.coverImagePath = current.coverImagePath
        }
        let known = Set(taken.bookmarks.map(\.id))
        for bookmark in current.bookmarks where !known.contains(bookmark.id) {
            let carried = VersionPlaceMapping.carried(bookmark, from: oldList, to: newList)
            if taken.bookmarks.contains(where: { $0.kind == carried.kind && $0.hasSameStableLocation(as: carried) }) { continue }
            taken.bookmarks.append(carried)
        }
        taken.bookmarks = taken.bookmarks.sortedByStablePosition()

        var left = current
        left.onlineChapters = nil
        left.isInBookshelf = false
        left.versionOf = targetID
        // Each saved as a whole: `saveReadingBook` replaces the record.
        store.saveReadingBook(taken)
        store.saveReadingBook(left)
        for var kept in store.keptVersions(of: currentID) where kept.id != targetID {
            kept.onlineChapters = nil
            kept.versionOf = targetID
            store.saveReadingBook(kept)
        }
        store.readerSettings.carrySettings(from: currentID, to: targetID)

        let opening = place.flatMap { VersionPlaceMapping.target(forSpine: $0, from: oldList, to: newList) }
        if let opening {
            // Saved before the target's reader opens, so its restore already reads it.
            await positionStore.save(CoreTextReadingPosition(spineIndex: opening.spineIndex, charOffset: 0),
                                     for: targetID.uuidString)
        }
        AppLogger.info("⟐ shelf: switched to another version of the work", context: [
            "title": current.title,
            "from": currentID.uuidString,
            "to": targetID.uuidString,
            "mapped": opening.map { "\($0.spineIndex)" } ?? "none",
        ])
        return opening
    }
}

extension BookStore {
    /// The versions kept beside shelf book `id` (`ReadingBook.versionOf`), the one read most
    /// recently first.
    func keptVersions(of id: UUID) -> [ReadingBook] {
        readingBooks.filter { $0.versionOf == id }.sorted(by: ShelfWork.keptFirst)
    }
}
