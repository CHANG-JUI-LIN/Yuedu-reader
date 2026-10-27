import Combine
import Foundation

// One book per work on the shelf (feedback #16, maintainer 2026-10-18).
//
// A reader with 1559 來源配置 added the same novel from several sources and got one shelf book
// per source. The decision: a work is on the shelf once. Adding it from another source switches
// the shelf book to that source through 換源 (`OnlineBookSourceSwitch`), and the copies already
// on the shelf are merged once at launch (`ShelfWorkMerger`).
//
// Every origin, since 2026-10-26 (maintainer: 「自己導入的書、來源配置、WebDAV、Calibre、模組⋯
// 都是相同地位」): an imported file, a library's book, a module's, 青空文庫's and a 來源配置's are
// versions of the work alike. One is on the shelf; the others are kept beside it
// (`ReadingBook.versionOf`) for 換源 to switch to (`ShelfVersionSwitch`), each with its own file,
// place and highlights. A work keeps one 來源配置 copy: two are merged into one, as before.

/// The shelf's "same work" test: the work index's B-level rule (`WorkIndex`, design §7.2) —
/// equal `WorkMatchKey` titles and compatible named authors — plus the same content kind. Unlike
/// 換源's `SearchBook.isLikelySameBook`, a side without an author never matches: this test
/// deletes books, and 「三體」 with no author is not proof of anything.
enum ShelfWork {
    struct Key: Equatable {
        var title: String
        var authors: [String]
        var kind: ContentKind
    }

    /// Nil when the title folds to nothing or no real author is named (「未知作者」 is none).
    static func key(title: String, author: String, kind: ContentKind) -> Key? {
        let titleKey = WorkMatchKey.title(title)
        guard !titleKey.isEmpty else { return nil }
        let authors = WorkMatchKey.knownAuthors([author]).map(WorkMatchKey.author).filter { !$0.isEmpty }
        guard !authors.isEmpty else { return nil }
        return Key(title: titleKey, authors: authors, kind: kind)
    }

    static func key(of book: ReadingBook) -> Key? {
        key(title: book.title, author: book.author, kind: ContentKind(book.resolvedPipelineKind))
    }

    static func sameWork(_ lhs: Key, _ rhs: Key) -> Bool {
        lhs.title == rhs.title && lhs.kind == rhs.kind
            && WorkMatchKey.authorKeysCompatible(lhs.authors, rhs.authors)
    }

    /// A book read from a 來源配置: online, bound to a source, and nothing else.
    static func isSourceCopy(_ book: ReadingBook) -> Bool {
        book.isOnline && book.bookSourceId != nil && book.module == nil
            && book.remoteSource == nil && book.aozora == nil
    }

    /// The reader split these two into different works (作品詳情 →「不是同一部作品」).
    @MainActor
    static func keptApart(_ lhs: ReadingBook, _ rhs: ReadingBook, decisions: [WorkDecision]) -> Bool {
        let context = SourceRecordContext.live()
        let left: Set<SourceItemKey> = [.copy(lhs.id), SourceRecord.derived(from: lhs, context: context).key]
        let right: Set<SourceItemKey> = [.copy(rhs.id), SourceRecord.derived(from: rhs, context: context).key]
        return decisions.contains { decision in
            guard case .differentWorks(let a, let b, _) = decision else { return false }
            return (left.contains(a) && right.contains(b)) || (left.contains(b) && right.contains(a))
        }
    }

    /// When the book was last read, or added when never read.
    static func recency(_ book: ReadingBook) -> Date {
        book.lastOpenedDate ?? book.addedDate
    }

    /// The order in which copies of a work are kept: a copy read before one never opened, then
    /// the most recently read (or added) first, ties broken by id — a file imported today does
    /// not take the shelf from the copy being read. The same inputs give the same order on
    /// every device, so two devices merging the same synced shelf keep the same book.
    static func keptFirst(_ lhs: ReadingBook, _ rhs: ReadingBook) -> Bool {
        if (lhs.lastOpenedDate == nil) != (rhs.lastOpenedDate == nil) { return lhs.lastOpenedDate != nil }
        let l = recency(lhs), r = recency(rhs)
        if l != r { return l > r }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// The shelf's books grouped by work, whatever they are read from; only groups of two or
    /// more, survivor first. Greedy in `keptFirst` order: each copy joins the first group whose
    /// survivor is the same work and was not split from it, so the result does not depend on
    /// the shelf's order.
    @MainActor
    static func duplicateSets(in books: [ReadingBook], decisions: [WorkDecision]) -> [[ReadingBook]] {
        var groups: [(key: Key, books: [ReadingBook])] = []
        for book in books.filter(\.isInBookshelf).sorted(by: keptFirst) {
            guard let bookKey = Self.key(of: book) else { continue }
            if let index = groups.firstIndex(where: { group in
                sameWork(group.key, bookKey) && !keptApart(group.books[0], book, decisions: decisions)
            }) {
                groups[index].books.append(book)
            } else {
                groups.append((bookKey, [book]))
            }
        }
        return groups.map(\.books).filter { $0.count > 1 }
    }

    /// The shelf's book of the same work as `key`, whatever it is read from, other than
    /// `excluding`.
    @MainActor
    static func shelfCopy(of key: Key, candidate: ReadingBook? = nil, in store: BookStore, excluding: UUID? = nil) -> ReadingBook? {
        let decisions = store.workDecisions.decisions
        // Folds every shelf book's title and author (ICU) on the main actor; timed so a large
        // shelf shows up in the ⏱ lines.
        return SourcePerfTrace.span("shelf.workMatch", "\(store.books.count) books") {
            store.books
                .filter { $0.id != excluding }
                .sorted(by: keptFirst)
                .first { book in
                    guard let other = Self.key(of: book), sameWork(key, other) else { return false }
                    guard let candidate else { return true }
                    return !keptApart(candidate, book, decisions: decisions)
                }
        }
    }
}

/// Merges the copies of a work on the shelf (`mergeDuplicates`): two 來源配置 copies become one
/// (`absorb`), and every other copy is kept beside the shelf book as a version of it (`keep`).
/// `absorb` is shared with 加入書架 of a copy just read (`ShelfWorkService.shelveReadCopy`).
///
/// What moves, and how:
/// - Bookmarks, highlights, underlines and their notes (`ReadingBook.bookmarks`, the only place
///   annotations live). They are anchored by chapter index + UTF-16 offset, and an offset into
///   one source's text means nothing in another's. So, as 換源 does for the reading position,
///   the chapter is found again by `ChapterAlignment` and the offset is kept only when the
///   chapter keeps its index. A highlight or underline whose offset cannot be kept becomes a
///   bookmark at the start of its chapter, with its excerpt and note — never a range drawn over
///   the wrong text. Same id = already moved, so a merge cut short and run again is a no-op.
/// - Group (書架分組), custom cover and custom intro, when the kept copy has none.
/// - The reading place, only when the merged copy was read more recently (never at launch,
///   where the kept copy is the most recent by definition).
/// - The book's reader settings — reading mode and the fixed-page reader's toggles — when
///   they are the later choice or the kept copy has none (`BookReaderSettingsStore.carrySettings`).
///   An online manga has them like any other book: a copy set to 條漫 lost it to the shelf book
///   it joined (feedback #74).
///
/// What does not move: downloaded chapters (they belong to the other source and go with it),
/// its 換源 cache, AI summaries / translations / character memory / chats (built from that
/// source's text), 多角色朗讀 casts, work-index decisions anchored to its copy key. Reading
/// statistics are left as they are: sessions are summed by title, and the delete path never
/// removes them.
@MainActor
struct ShelfWorkMerger {
    let store: BookStore
    let positionStore: ReadingPositionStore

    struct Report: Equatable {
        var survivor: UUID
        /// The 來源配置 copies merged into the work's one and deleted.
        var merged: [UUID]
        var movedBookmarks: Int
        /// The copies kept beside the shelf book as versions of it.
        var kept: [UUID] = []
    }

    /// Merges every set of shelf copies of one work, keeping its most recently read copy on the
    /// shelf (`ShelfWork.keptFirst`). The work's 來源配置 copies are merged into the most recently
    /// read of them, the others deleted through `BookStore.delete(bookId:)` — the path whose
    /// removal the iCloud merge turns into a tombstone, so another device does not bring them
    /// back. Every other copy, and that source copy when it is not the one on the shelf, is kept
    /// beside the shelf book (`keep`): nothing of what it is read from is deleted. Offline: the
    /// kept copy keeps its own source. Idempotent.
    @discardableResult
    func mergeDuplicates() async -> [Report] {
        let books = store.books
        let sets = SourcePerfTrace.span("shelf.duplicateSets", "\(books.count) books") {
            ShelfWork.duplicateSets(in: books, decisions: store.workDecisions.decisions)
        }
        var reports: [Report] = []
        for set in sets {
            let survivor = set[0]
            var report = Report(survivor: survivor.id, merged: [], movedBookmarks: 0)
            let sourceCopies = set.filter(ShelfWork.isSourceCopy)
            if let sourceCopy = sourceCopies.first {
                for duplicate in sourceCopies.dropFirst() {
                    report.movedBookmarks += await absorb(duplicate.id, into: sourceCopy.id)
                    report.merged.append(duplicate.id)
                }
            }
            for version in set.dropFirst() where !report.merged.contains(version.id) {
                keep(version.id, beside: survivor.id)
                report.kept.append(version.id)
            }
            AppLogger.info("⟐ shelf: merged copies of one work", context: [
                "title": survivor.title,
                "kept": survivor.id.uuidString,
                "keptSource": survivor.bookSourceId?.uuidString ?? "",
                "merged": report.merged.map(\.uuidString).joined(separator: ","),
                "versions": report.kept.map(\.uuidString).joined(separator: ","),
                "bookmarks": report.movedBookmarks,
            ])
            reports.append(report)
        }
        return reports
    }

    /// Keeps shelf copy `versionID` beside shelf book `survivorID` as a version of it, off the
    /// shelf: its file, place, bookmarks and highlights stay its own, as a version's do
    /// (`ShelfVersionSwitch`), and 換源 switches to it. What is the shelf's — 書架分組, a custom
    /// cover and a custom intro — goes to the shelf book when it has none; the versions kept
    /// beside the copy follow it.
    func keep(_ versionID: UUID, beside survivorID: UUID) {
        guard versionID != survivorID,
              var version = store.shelfRecord(id: versionID),
              var survivor = store.shelfRecord(id: survivorID) else { return }
        if survivor.group.isEmpty, !version.group.isEmpty { survivor.group = version.group }
        if survivor.customIntro == nil, let intro = version.customIntro { survivor.customIntro = intro }
        if !survivor.hasCustomCover, version.hasCustomCover {
            // Both point at the cover files: each copy keeps the files it points at until deleted.
            survivor.customCoverUrl = version.customCoverUrl
            survivor.coverImagePath = version.coverImagePath
            survivor.originalCoverImagePath = version.originalCoverImagePath ?? survivor.originalCoverImagePath
        }
        version.isInBookshelf = false
        version.versionOf = survivorID
        // Each saved as a whole: `saveReadingBook` replaces the record.
        store.saveReadingBook(survivor)
        store.saveReadingBook(version)
        for var kept in store.keptVersions(of: versionID) {
            kept.onlineChapters = nil
            kept.versionOf = survivorID
            store.saveReadingBook(kept)
        }
    }

    /// Moves `duplicateID`'s data onto `survivorID` (see the type's notes), then deletes the
    /// duplicate. Returns how many bookmarks moved.
    @discardableResult
    func absorb(_ duplicateID: UUID, into survivorID: UUID) async -> Int {
        guard duplicateID != survivorID,
              let duplicate = store.readingBook(id: duplicateID),
              let survivorWithList = store.readingBook(id: survivorID)
        else { return 0 }
        var survivor = store.shelfRecord(id: survivorID) ?? recordOnly(survivorWithList)
        let oldRefs = duplicate.onlineChapters ?? []
        let newRefs = survivorWithList.onlineChapters ?? []

        var moved = 0
        let known = Set(survivor.bookmarks.map(\.id))
        for bookmark in duplicate.bookmarks where !known.contains(bookmark.id) {
            let carried = Self.carried(bookmark, oldRefs: oldRefs, newRefs: newRefs)
            if survivor.bookmarks.contains(where: { $0.kind == carried.kind && $0.hasSameStableLocation(as: carried) }) {
                continue
            }
            survivor.bookmarks.append(carried)
            moved += 1
        }
        survivor.bookmarks = survivor.bookmarks.sortedByStablePosition()
        if survivor.group.isEmpty, !duplicate.group.isEmpty { survivor.group = duplicate.group }
        if survivor.customIntro == nil, let intro = duplicate.customIntro { survivor.customIntro = intro }
        if !survivor.hasCustomCover, duplicate.hasCustomCover {
            // Delete leaves cover files on disk on purpose, so the kept copy can point at them.
            survivor.customCoverUrl = duplicate.customCoverUrl
            survivor.coverImagePath = duplicate.coverImagePath
            survivor.originalCoverImagePath = duplicate.originalCoverImagePath ?? survivor.originalCoverImagePath
        }
        let takesPlace = ShelfWork.recency(duplicate) > ShelfWork.recency(survivor)
        if takesPlace {
            survivor.lastOpenedDate = duplicate.lastOpenedDate
            survivor.currentPosition = duplicate.currentPosition
        }
        store.saveReadingBook(survivor)

        if takesPlace, let place = positionStore.loadSync(for: duplicateID.uuidString),
           let mapped = OnlineBookSourceSwitch.mappedPosition(
               oldRefs: oldRefs, newRefs: newRefs, oldIndex: place.spineIndex, livePosition: place
           ) {
            await positionStore.save(mapped, for: survivorID.uuidString)
        }
        store.readerSettings.carrySettings(from: duplicateID, to: survivorID)
        // The versions kept beside the merged copy are the kept copy's now: deleting the merged
        // copy deletes its own (`BookStore.delete`).
        for var version in store.readingBooks where version.versionOf == duplicateID {
            version.versionOf = survivorID
            store.saveReadingBook(version)
        }
        store.delete(bookId: duplicateID)
        return moved
    }

    private func recordOnly(_ book: ReadingBook) -> ReadingBook {
        var record = book
        record.onlineChapters = nil
        return record
    }

    /// A bookmark of the merged copy, re-anchored in the kept copy's table of contents.
    ///
    /// With either list missing — a copy synced from another device arrives without its list
    /// (`strippedForSync`), a Legado import has none — the chapter cannot be found again: it
    /// keeps its index, and nothing keeps an offset.
    nonisolated static func carried(_ bookmark: Bookmark, oldRefs: [OnlineChapterRef], newRefs: [OnlineChapterRef]) -> Bookmark {
        let oldIndex = bookmark.position.spineIndex
        let listsKnown = !oldRefs.isEmpty && !newRefs.isEmpty
        let mapped = listsKnown
            ? OnlineBookSourceSwitch.mappedChapterIndex(oldRefs: oldRefs, newRefs: newRefs, oldIndex: oldIndex)
            : oldIndex
        let title = newRefs.indices.contains(mapped) ? newRefs[mapped].title : bookmark.chapterTitle
        let keepsOffset = listsKnown && mapped == oldIndex
            && oldRefs.indices.contains(oldIndex) && newRefs.indices.contains(mapped)
            && WorkMatchKey.title(oldRefs[oldIndex].title) == WorkMatchKey.title(newRefs[mapped].title)
        if keepsOffset {
            return Bookmark(
                chapterIndex: mapped, chapterTitle: title, position: bookmark.position,
                length: bookmark.length, kind: bookmark.kind, note: bookmark.note,
                excerpt: bookmark.excerpt, id: bookmark.id, date: bookmark.date,
                annotationStyle: bookmark.annotationStyle, annotationColor: bookmark.annotationColor
            )
        }
        return Bookmark(
            chapterIndex: mapped, chapterTitle: title,
            position: CoreTextReadingPosition(spineIndex: mapped, charOffset: 0),
            length: 0, kind: .bookmark, note: bookmark.note,
            excerpt: bookmark.excerpt, id: bookmark.id, date: bookmark.date
        )
    }
}

/// 加入書架 for books read from a 來源配置 — the one use case every entry point calls.
@MainActor
struct ShelfWorkService {
    /// What the detail page has in hand for the copy being added.
    struct OnlineCopy {
        var name: String
        var author: String
        var sourceId: UUID
        var bookInfoURL: String
        var tocURL: String?
        var coverUrl: String = ""
        var runtimeVariables: [String: String]?
        var contentKind: OnlineBookContentKind?
        var chapters: [OnlineChapterRef]
    }

    enum Outcome {
        /// A new shelf book.
        case added(ReadingBook)
        /// This source's copy was already on the shelf (same source + URL).
        case alreadyOnShelf(ReadingBook)
        /// The work was on the shelf from another source; that book now reads from this one.
        case switchedSource(ReadingBook)

        var book: ReadingBook {
            switch self {
            case .added(let book), .alreadyOnShelf(let book), .switchedSource(let book): book
            }
        }
    }

    let store: BookStore
    let sourceSwitch: OnlineBookSourceSwitch
    /// For a work on the shelf read from elsewhere — an imported file, a library, a module:
    /// the copy added takes the shelf, and that book is kept beside it.
    let versions: ShelfVersionSwitch

    init(store: BookStore, sourceSwitch: OnlineBookSourceSwitch, versions: ShelfVersionSwitch) {
        self.store = store
        self.sourceSwitch = sourceSwitch
        self.versions = versions
    }

    init(store: BookStore, dependencies: AppDependencies) {
        self.init(store: store, sourceSwitch: OnlineBookSourceSwitch(store: store, dependencies: dependencies),
                  versions: ShelfVersionSwitch(store: store, dependencies: dependencies))
    }

    private var merger: ShelfWorkMerger {
        ShelfWorkMerger(store: store, positionStore: sourceSwitch.positionStore)
    }

    /// Adds `copy` to the shelf, unless its work is there: then the shelf book switches to
    /// `copy`'s source through 換源 and keeps its place (mapped by chapter title). A shelf book
    /// read from elsewhere is kept beside the work's source copy, which takes the shelf.
    func add(_ copy: OnlineCopy) async throws -> Outcome {
        if let existing = store.onlineBook(sourceId: copy.sourceId, bookInfoURL: copy.bookInfoURL) {
            return .alreadyOnShelf(existing)
        }
        // This source's copy was read without being added and is still here: the app ended
        // while its reader was open, or 作品詳情's 「加入書架？」 was declined. It is the book
        // being added, so it goes on the shelf the way a read copy does, with its reading mode,
        // place and bookmarks. A new record beside it left all of those behind (feedback #74).
        if let readCopy = store.onlineBook(sourceId: copy.sourceId, bookInfoURL: copy.bookInfoURL, onShelf: false) {
            // The page's list is the newer one, as when 立即閱讀 reopens this copy.
            if !copy.chapters.isEmpty {
                store.updateOnlineChapters(bookId: readCopy.id, chapters: copy.chapters, runtimeVariables: copy.runtimeVariables)
            }
            if let shelved = try await shelveReadCopy(id: readCopy.id) {
                return shelved.id == readCopy.id ? .added(shelved) : .switchedSource(shelved)
            }
        }
        let kind = BookStore.inferredOnlineContentKind(
            explicit: copy.contentKind, sourceId: copy.sourceId, runtimeVariables: copy.runtimeVariables,
            bookInfoURL: copy.bookInfoURL, tocURL: copy.tocURL
        )
        if !copy.chapters.isEmpty,
           let key = ShelfWork.key(title: copy.name, author: copy.author, kind: ContentKind(kind.pipelineKind)),
           let existing = ShelfWork.shelfCopy(of: key, in: store), !ShelfWork.isSourceCopy(existing) {
            let copyID = try await versions.sourceCopy(of: existing.id, origin: Self.origin(of: copy),
                                                       toc: Self.toc(of: copy), sourceSwitch: sourceSwitch)
            try await versions.commit(from: existing.id, to: copyID)
            AppLogger.info("⟐ shelf: work on the shelf from elsewhere, its source copy took the shelf", context: [
                "title": existing.title, "kept": existing.id.uuidString, "book": copyID.uuidString,
                "source": copy.sourceId.uuidString,
            ])
            return .switchedSource(store.readingBook(id: copyID) ?? existing)
        }
        if !copy.chapters.isEmpty,
           let key = ShelfWork.key(title: copy.name, author: copy.author, kind: ContentKind(kind.pipelineKind)),
           let existing = ShelfWork.shelfCopy(of: key, in: store) {
            try await switchSource(of: existing.id, to: copy)
            AppLogger.info("⟐ shelf: work already on the shelf, switched its source", context: [
                "title": existing.title,
                "book": existing.id.uuidString,
                "from": existing.bookSourceId?.uuidString ?? "",
                "to": copy.sourceId.uuidString,
            ])
            return .switchedSource(store.readingBook(id: existing.id) ?? existing)
        }
        let book = store.addOnlineBook(
            name: copy.name, author: copy.author, sourceId: copy.sourceId,
            bookInfoURL: copy.bookInfoURL, tocURL: copy.tocURL, coverUrl: copy.coverUrl,
            runtimeVariables: copy.runtimeVariables, contentKind: copy.contentKind,
            chapters: copy.chapters
        )
        return .added(book)
    }

    /// 加入書架 for a copy only read so far (立即閱讀 → the reader closed → 「加入書架？」).
    /// When its work is on the shelf from another source, that shelf book switches to this
    /// copy's source, takes over what was just read (the place, since this copy was read last,
    /// and its bookmarks), and the read copy is deleted. When the work's shelf book is read
    /// from elsewhere, or the copy is (an imported file, a library's, a module's), the copy takes
    /// the shelf with its own place and that book is kept beside it. Otherwise the copy joins
    /// the shelf.
    func shelveReadCopy(id: UUID) async throws -> ReadingBook? {
        guard let copy = store.readingBook(id: id) else { return nil }
        guard let key = ShelfWork.key(of: copy),
              let existing = ShelfWork.shelfCopy(of: key, candidate: copy, in: store, excluding: id)
        else {
            return store.addReadingBookToShelf(id: id)
        }
        guard ShelfWork.isSourceCopy(copy), ShelfWork.isSourceCopy(existing) else {
            try await versions.commit(from: existing.id, to: id, carriesPlace: false)
            // A work keeps one 來源配置 copy: one kept beside the shelf book is merged into the
            // source copy now on the shelf.
            if ShelfWork.isSourceCopy(copy) {
                for kept in store.keptVersions(of: id) where ShelfWork.isSourceCopy(kept) {
                    await merger.absorb(kept.id, into: id)
                }
            }
            AppLogger.info("⟐ shelf: read copy took the shelf, the work's book kept beside it", context: [
                "title": existing.title, "kept": existing.id.uuidString, "readCopy": id.uuidString,
            ])
            return store.readingBook(id: id)
        }
        guard let sourceId = copy.bookSourceId, let chapters = copy.onlineChapters, !chapters.isEmpty else {
            return store.addReadingBookToShelf(id: id)
        }
        try await switchSource(of: existing.id, to: OnlineCopy(
            name: copy.title, author: copy.author, sourceId: sourceId,
            bookInfoURL: copy.bookInfoURL ?? copy.source, tocURL: copy.tocURL,
            runtimeVariables: copy.runtimeVariables, chapters: chapters
        ))
        await merger.absorb(id, into: existing.id)
        AppLogger.info("⟐ shelf: read copy joined the work's shelf book", context: [
            "title": existing.title, "book": existing.id.uuidString, "readCopy": id.uuidString,
        ])
        return store.readingBook(id: existing.id)
    }

    private func switchSource(of bookId: UUID, to copy: OnlineCopy) async throws {
        try await sourceSwitch.commit(bookId: bookId, origin: Self.origin(of: copy), toc: Self.toc(of: copy))
    }

    private static func origin(of copy: OnlineCopy) -> BookOrigin {
        BookOrigin(
            sourceId: copy.sourceId, sourceName: BookSourceStore.shared.source(id: copy.sourceId)?.bookSourceName ?? "",
            bookUrl: copy.bookInfoURL, tocUrl: copy.tocURL ?? copy.bookInfoURL, coverUrl: copy.coverUrl, intro: "",
            lastChapter: copy.chapters.last?.title ?? "", wordCount: "", kind: "",
            runtimeVariables: copy.runtimeVariables
        )
    }

    private static func toc(of copy: OnlineCopy) -> TOCPackage {
        TOCPackage(
            sourceId: copy.sourceId, sourceName: BookSourceStore.shared.source(id: copy.sourceId)?.bookSourceName ?? "",
            tocURL: copy.tocURL ?? copy.bookInfoURL, runtimeVariables: copy.runtimeVariables, chapters: copy.chapters,
            rawHTMLFilename: nil, savedAt: Date()
        )
    }
}

/// Runs `ShelfWorkMerger` once per launch, on the app's own shelf.
///
/// With iCloud 自動同步 on it waits for the launch sync to finish: the survivor is chosen by
/// `lastOpenedDate`, and two devices agree on it only when they see the same dates. Merging
/// before the sync, a device that read copy B since the last sync would keep B while another
/// keeps A, and each would tombstone the other's survivor — the work would be gone from both.
/// A sync that fails or never runs (no iCloud account) leaves the merge for a later launch.
@MainActor
enum ShelfWorkLaunchMerge {
    private static var waitingForSync: AnyCancellable?

    static func schedule(store: BookStore) {
        // Built when it runs, not here: this is called from the shelf's initializer, and
        // `AppDependencies.live` must not be forced that early.
        func merge() async {
            await ShelfWorkMerger(store: store, positionStore: AppDependencies.live.readingPositionStore)
                .mergeDuplicates()
        }
        guard GlobalSettings.shared.iCloudAutoSync else {
            // After the launch turn, so building the store never deletes anything under its caller.
            Task { @MainActor in await merge() }
            return
        }
        // `lastSyncDate` is set by a sync that completed; the current value is replayed first.
        waitingForSync = ICloudSyncManager.shared.$lastSyncDate
            .dropFirst()
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    waitingForSync = nil
                    Task { @MainActor in await merge() }
                }
            }
    }
}

extension BookStore {
    /// The content kind an online book is stored with: the caller's, or inferred from its
    /// source and URLs. `addOnlineBook` and the shelf's same-work test both read it here, so a
    /// book is compared under the kind it will be stored as.
    static func inferredOnlineContentKind(
        explicit: OnlineBookContentKind?,
        sourceId: UUID,
        runtimeVariables: [String: String]?,
        bookInfoURL: String,
        tocURL: String?
    ) -> OnlineBookContentKind {
        if let explicit { return explicit }
        let source = BookSourceStore.shared.source(id: sourceId)
        return OnlineBookContentInference.infer(
            sourceType: source?.bookSourceType,
            runtimeVariables: runtimeVariables,
            urls: [bookInfoURL, tocURL ?? ""],
            metadataText: OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        )
    }
}
