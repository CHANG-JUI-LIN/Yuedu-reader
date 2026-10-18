import Foundation

/// The one commit of 換源 for a book that already exists: rebinds it to `origin`, then carries
/// its reading place over to the new source's table of contents.
///
/// Until 2026-10-18 the place was carried over only inside the reader
/// (`ReaderView.switchToOrigin`), so the detail page's 換源 of a shelf book rebound the source
/// and left the stored chapter index pointing into the old source's list. Every switch — the
/// reader's, the detail page's, and 加入書架 of a work that is already on the shelf
/// (`ShelfWorkService`) — goes through here.
@MainActor
struct OnlineBookSourceSwitch {
    /// Where the switch reads the place from. The reader passes the place on screen; every other
    /// caller leaves it nil and the stored place is used.
    struct Anchor {
        var chapterIndex: Int
        var position: CoreTextReadingPosition?
    }

    let store: BookStore
    let positionStore: ReadingPositionStore
    let offlineChapterStore: any OfflineChapterStoring
    /// Its failure budget was earned by the source being left; nil where no fetcher is wired.
    let chapterFetcher: (any ChapterFetching)?

    init(
        store: BookStore,
        positionStore: ReadingPositionStore,
        offlineChapterStore: any OfflineChapterStoring,
        chapterFetcher: (any ChapterFetching)?
    ) {
        self.store = store
        self.positionStore = positionStore
        self.offlineChapterStore = offlineChapterStore
        self.chapterFetcher = chapterFetcher
    }

    init(store: BookStore, dependencies: AppDependencies) {
        self.init(
            store: store,
            positionStore: dependencies.readingPositionStore,
            offlineChapterStore: dependencies.offlineChapterStore,
            chapterFetcher: dependencies.chapterFetcher
        )
    }

    /// Rebinds `bookId` to `origin` with the table of contents already fetched, and returns the
    /// reading place mapped into it (nil when there was none to map). Throws, leaving the book on
    /// its old source, when the new list is empty (`BookStore.updateOnlineBookSource`).
    @discardableResult
    func commit(
        bookId: UUID,
        origin: BookOrigin,
        toc: TOCPackage,
        readingFrom anchor: Anchor? = nil
    ) async throws -> CoreTextReadingPosition? {
        let before = store.readingBook(id: bookId)
        let oldRefs = before?.onlineChapters ?? []
        let key = bookId.uuidString
        let start: Anchor? = anchor ?? positionStore.loadSync(for: key).map {
            Anchor(chapterIndex: $0.spineIndex, position: $0)
        }

        try await store.updateOnlineBookSource(
            bookId: bookId,
            origin: origin,
            preparedTOC: toc,
            offlineChapterStore: offlineChapterStore
        )
        // The failure budget and any automatic quarantine were earned by the source just left.
        // Neither used to be reset by anything short of deleting the book and adding it again.
        await chapterFetcher?.resetFailureBudget(for: bookId)
        store.clearAutomaticQuarantine(bookId: bookId)

        let newRefs = store.readingBook(id: bookId)?.onlineChapters ?? []
        if let before {
            mapImageAndAudioPlace(of: before, oldRefs: oldRefs, newRefs: newRefs)
        }
        guard let start else { return nil }
        let mapped = SourcePerfTrace.span("changeSource.align") {
            Self.mappedPosition(
                oldRefs: oldRefs, newRefs: newRefs,
                oldIndex: start.chapterIndex, livePosition: start.position
            )
        }
        guard let mapped else { return nil }
        // Persisted before the caller reloads, so any restore path that re-reads the position
        // store already sees the mapped chapter.
        await positionStore.save(mapped, for: key)
        return mapped
    }

    /// The chapter in the new list for the one being read in the old: the raw index means
    /// different things in different sources (extra 卷 headers, merged 序章 …), so it is found
    /// again by `ChapterAlignment` (title similarity + chapter number, Legado getDurChapter).
    /// The same text in another source starts at a different offset, so only a mapping that
    /// keeps the index keeps the offset.
    nonisolated static func mappedPosition(
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef],
        oldIndex: Int,
        livePosition: CoreTextReadingPosition?
    ) -> CoreTextReadingPosition? {
        guard !oldRefs.isEmpty, !newRefs.isEmpty else { return nil }
        let mapped = mappedChapterIndex(oldRefs: oldRefs, newRefs: newRefs, oldIndex: oldIndex)
        let keepOffset = (mapped == oldIndex && livePosition?.spineIndex == oldIndex)
            ? max(0, livePosition?.charOffset ?? 0)
            : 0
        return CoreTextReadingPosition(spineIndex: mapped, charOffset: keepOffset)
    }

    nonisolated static func mappedChapterIndex(
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef],
        oldIndex: Int
    ) -> Int {
        ChapterAlignment.mappedChapterIndex(
            oldIndex: oldIndex,
            oldTitle: oldRefs.indices.contains(oldIndex) ? oldRefs[oldIndex].title : nil,
            oldCount: oldRefs.count,
            newTitles: newRefs.map(\.title)
        )
    }

    /// Comics and audiobooks keep their place on the record (`mangaChapterIndex`,
    /// `audioChapterIndex`), not in the position store; the same alignment applies. A place
    /// inside a chapter (page, seconds) survives only when the chapter keeps its index.
    private func mapImageAndAudioPlace(
        of book: ReadingBook,
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef]
    ) {
        guard !oldRefs.isEmpty, !newRefs.isEmpty else { return }
        switch book.resolvedPipelineKind {
        case .manga where book.mangaChapterIndex > 0:
            let mapped = Self.mappedChapterIndex(oldRefs: oldRefs, newRefs: newRefs, oldIndex: book.mangaChapterIndex)
            store.updateMangaPosition(
                bookId: book.id, chapter: mapped,
                page: mapped == book.mangaChapterIndex ? book.mangaPage : 0,
                totalChapters: newRefs.count, forceSave: true
            )
        case .audio where book.audioChapterIndex > 0:
            let mapped = Self.mappedChapterIndex(oldRefs: oldRefs, newRefs: newRefs, oldIndex: book.audioChapterIndex)
            store.updateAudioPosition(
                bookId: book.id, chapter: mapped,
                time: mapped == book.audioChapterIndex ? book.audioTimeSeconds : 0,
                totalChapters: newRefs.count, forceSave: true
            )
        default:
            break
        }
    }
}
