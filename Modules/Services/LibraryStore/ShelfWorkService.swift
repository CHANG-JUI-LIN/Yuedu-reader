import Combine
import Foundation

// One book per work on the shelf (feedback #16, maintainer 2026-10-18).
//
// A reader with 1559 來源配置 added the same novel from several sources and got one shelf book
// per source. The decision: a work is on the shelf once. Adding it from another source switches
// the shelf book to that source through 換源 (`OnlineBookSourceSwitch`), and the copies already
// on the shelf are merged once at launch (`ShelfWorkMerger`).
//
// Only books read from a 來源配置 are in scope: imported files, remote libraries, Aozora,
// modules and browser imports keep their own rules.

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

    /// The order in which copies of a work are kept: the most recently read first, ties broken
    /// by id. The same inputs give the same order on every device, so two devices merging the
    /// same synced shelf keep the same book.
    static func keptFirst(_ lhs: ReadingBook, _ rhs: ReadingBook) -> Bool {
        let l = recency(lhs), r = recency(rhs)
        if l != r { return l > r }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// The shelf's source copies grouped by work; only groups of two or more, survivor first.
    /// Greedy in `keptFirst` order: each copy joins the first group whose survivor is the same
    /// work and was not split from it, so the result does not depend on the shelf's order.
    @MainActor
    static func duplicateSets(in books: [ReadingBook], decisions: [WorkDecision]) -> [[ReadingBook]] {
        var groups: [(key: Key, books: [ReadingBook])] = []
        for book in books.filter({ $0.isInBookshelf && isSourceCopy($0) }).sorted(by: keptFirst) {
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

    /// The shelf's source copy of the same work as `key`, other than `excluding`.
    @MainActor
    static func shelfCopy(of key: Key, candidate: ReadingBook? = nil, in store: BookStore, excluding: UUID? = nil) -> ReadingBook? {
        let decisions = store.workDecisions.decisions
        // Folds every shelf source copy's title and author (ICU) on the main actor; timed so a
        // large shelf shows up in the ⏱ lines.
        return SourcePerfTrace.span("shelf.workMatch", "\(store.books.count) books") {
            store.books
                .filter { $0.id != excluding && isSourceCopy($0) }
                .sorted(by: keptFirst)
                .first { book in
                    guard let other = Self.key(of: book), sameWork(key, other) else { return false }
                    guard let candidate else { return true }
                    return !keptApart(candidate, book, decisions: decisions)
                }
        }
    }
}

/// Merges one copy of a work into the copy that is kept. Shared by the launch merge and by
/// 加入書架 of a copy just read (`ShelfWorkService.shelveReadCopy`).
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
///
/// What does not move: downloaded chapters (they belong to the other source and go with it),
/// its 換源 cache, AI summaries / translations / character memory / chats (built from that
/// source's text), per-book fixed-page settings (online source books have none), 多角色朗讀
/// casts, work-index decisions anchored to its copy key. Reading statistics are left as they
/// are: sessions are summed by title, and the delete path never removes them.
@MainActor
struct ShelfWorkMerger {
    let store: BookStore
    let positionStore: ReadingPositionStore

    struct Report: Equatable {
        var survivor: UUID
        var merged: [UUID]
        var movedBookmarks: Int
    }

    /// Merges every set of shelf copies of one work into its most recently read copy and
    /// deletes the others through `BookStore.delete(bookId:)` — the path whose removal the
    /// iCloud merge turns into a tombstone, so another device does not bring them back.
    /// Offline: the kept copy keeps its own source. Idempotent.
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
            for duplicate in set.dropFirst() {
                report.movedBookmarks += await absorb(duplicate.id, into: survivor.id)
                report.merged.append(duplicate.id)
            }
            AppLogger.info("⟐ shelf: merged copies of one work", context: [
                "title": survivor.title,
                "kept": survivor.id.uuidString,
                "keptSource": survivor.bookSourceId?.uuidString ?? "",
                "merged": report.merged.map(\.uuidString).joined(separator: ","),
                "bookmarks": report.movedBookmarks,
            ])
            reports.append(report)
        }
        return reports
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

    init(store: BookStore, sourceSwitch: OnlineBookSourceSwitch) {
        self.store = store
        self.sourceSwitch = sourceSwitch
    }

    init(store: BookStore, dependencies: AppDependencies) {
        self.init(store: store, sourceSwitch: OnlineBookSourceSwitch(store: store, dependencies: dependencies))
    }

    private var merger: ShelfWorkMerger {
        ShelfWorkMerger(store: store, positionStore: sourceSwitch.positionStore)
    }

    /// Adds `copy` to the shelf, unless its work is there: then the shelf book switches to
    /// `copy`'s source through 換源 and keeps its place (mapped by chapter title).
    func add(_ copy: OnlineCopy) async throws -> Outcome {
        if let existing = store.onlineBook(sourceId: copy.sourceId, bookInfoURL: copy.bookInfoURL) {
            return .alreadyOnShelf(existing)
        }
        let kind = BookStore.inferredOnlineContentKind(
            explicit: copy.contentKind, sourceId: copy.sourceId, runtimeVariables: copy.runtimeVariables,
            bookInfoURL: copy.bookInfoURL, tocURL: copy.tocURL
        )
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
    /// and its bookmarks), and the read copy is deleted. Otherwise the copy joins the shelf.
    func shelveReadCopy(id: UUID) async throws -> ReadingBook? {
        guard let copy = store.readingBook(id: id) else { return nil }
        guard ShelfWork.isSourceCopy(copy), let sourceId = copy.bookSourceId,
              let chapters = copy.onlineChapters, !chapters.isEmpty,
              let key = ShelfWork.key(of: copy),
              let existing = ShelfWork.shelfCopy(of: key, candidate: copy, in: store, excluding: id)
        else {
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

    /// For importers that have no table of contents in hand (Legado backup): adds the book
    /// unless its work is already on the shelf, in which case it is skipped — switching would
    /// need a network fetch per book, and the shelf copy already is the work.
    @discardableResult
    func addWithoutNetwork(_ copy: OnlineCopy) -> ReadingBook? {
        if store.onlineBook(sourceId: copy.sourceId, bookInfoURL: copy.bookInfoURL) != nil { return nil }
        let kind = BookStore.inferredOnlineContentKind(
            explicit: copy.contentKind, sourceId: copy.sourceId, runtimeVariables: copy.runtimeVariables,
            bookInfoURL: copy.bookInfoURL, tocURL: copy.tocURL
        )
        if let key = ShelfWork.key(title: copy.name, author: copy.author, kind: ContentKind(kind.pipelineKind)),
           let existing = ShelfWork.shelfCopy(of: key, in: store) {
            AppLogger.info("⟐ shelf: import skipped, work already on the shelf", context: [
                "title": copy.name, "book": existing.id.uuidString,
            ])
            return nil
        }
        return store.addOnlineBook(
            name: copy.name, author: copy.author, sourceId: copy.sourceId,
            bookInfoURL: copy.bookInfoURL, tocURL: copy.tocURL, coverUrl: copy.coverUrl,
            runtimeVariables: copy.runtimeVariables, contentKind: copy.contentKind,
            chapters: copy.chapters
        )
    }

    private func switchSource(of bookId: UUID, to copy: OnlineCopy) async throws {
        let sourceName = BookSourceStore.shared.source(id: copy.sourceId)?.bookSourceName ?? ""
        let tocURL = copy.tocURL ?? copy.bookInfoURL
        let origin = BookOrigin(
            sourceId: copy.sourceId, sourceName: sourceName, bookUrl: copy.bookInfoURL,
            tocUrl: tocURL, coverUrl: copy.coverUrl, intro: "",
            lastChapter: copy.chapters.last?.title ?? "", wordCount: "", kind: "",
            runtimeVariables: copy.runtimeVariables
        )
        let toc = TOCPackage(
            sourceId: copy.sourceId, sourceName: sourceName, tocURL: tocURL,
            runtimeVariables: copy.runtimeVariables, chapters: copy.chapters,
            rawHTMLFilename: nil, savedAt: Date()
        )
        try await sourceSwitch.commit(bookId: bookId, origin: origin, toc: toc)
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
