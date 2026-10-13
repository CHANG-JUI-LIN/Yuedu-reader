import Foundation

/// 作品詳情's 目錄 (maintainer, 2026-10-13): the chapters of the copy a version is read from,
/// read as soon as the page opens, by the reader's own paths: an EPUB through the session its
/// reader opens (a library's in ranges, as reading does), a TXT through the index its reader
/// publishes. A chapter's `index` is where a reading position points: an EPUB's spine item, a
/// TXT's chapter.
///
/// Reading the chapters never opens the copy: it stays off the shelf, out of 繼續閱讀, and
/// unasked about by 「加入書架？」, which asks only about a copy that was read.
@MainActor
enum WorkTableOfContents {
    /// Whether the copy's reader opens at a chapter: an EPUB's or a TXT's. A PDF, a Markdown
    /// file, a comic and an audiobook have no chapters to list here.
    static func lists(_ book: ReadingBook) -> Bool {
        switch book.resolvedPipelineKind {
        case .epub:
            return true
        case .txt:
            let ext = (book.contentFilename as NSString).pathExtension.lowercased()
            return ext != "md" && ext != "markdown"
        case .html, .manga, .fixedPage, .audio:
            return false
        }
    }

    /// The copy's chapters; nil when it has none to list (`lists`), or when a TXT's index waits
    /// on its reader to map the old locations (`TXTReaderIndexMigrationService.indexForListing`).
    static func chapters(of book: ReadingBook, store: BookStore, remoteLibrary: any RemoteLibraryServing,
                         positions: any ReadingPositionStore) async throws -> [OnlineChapterRef]? {
        guard lists(book) else { return nil }
        // A library's copy is prepared as its reader prepares it, and held as a reader holds it:
        // the session is released only when no reader still reads it.
        let ownerID = UUID()
        let holdsRemote = book.remoteSource != nil
        if holdsRemote { ReadingResourceUsage.shared.retain(bookID: book.id, ownerID: ownerID) }
        defer {
            if holdsRemote, ReadingResourceUsage.shared.release(bookID: book.id, ownerID: ownerID) {
                remoteLibrary.release(bookID: book.id)
            }
        }
        switch book.resolvedPipelineKind {
        case .epub:
            let session = try await EPUBBookService.shared.openSession(for: book, using: store, remoteLibrary: remoteLibrary)
            return epubChapters(of: session)
        case .txt:
            let prepared = holdsRemote ? try await remoteLibrary.prepare(bookID: book.id, store: store) : book
            let url = StorageLocations.bookFile(prepared.contentFilename)
            let id = prepared.id
            let title = prepared.title
            let preparation = try await Task.detached(priority: .userInitiated) {
                try TXTReaderPreparationService.prepare(url: url, bookId: id, bookTitle: title)
            }.value
            guard let indexes = try await TXTReaderIndexMigrationService.indexForListing(
                preparation, store: store, positions: positions) else {
                AppLogger.cache("Work TOC waits on the reader to publish the TXT index bookId=\(id)")
                return nil
            }
            return indexes.enumerated().map { offset, index in
                OnlineChapterRef(index: offset, title: index.title, url: index.sourceHref)
            }
        case .html, .manga, .fixedPage, .audio:
            return nil
        }
    }

    /// The reader's chapters: the EPUB's own table of contents, else its spine. An entry inside
    /// a spine item keeps its anchor in `url`, as the EPUB writes it (`href#fragment`).
    static func epubChapters(of session: PublicationSession) -> [OnlineChapterRef] {
        if !session.tocEntries.isEmpty {
            return ReaderTOCChapterMapper.chapters(from: session.tocEntries, session: session).map { entry in
                OnlineChapterRef(index: entry.index, title: entry.title,
                                 url: entry.fragment.map { "\(entry.href)#\($0)" } ?? entry.href)
            }
        }
        return session.chapters.map { OnlineChapterRef(index: $0.index, title: $0.title, url: $0.href) }
    }

    /// Where the reader opens `chapter`: its spine item (a TXT's chapter), at the entry's anchor
    /// when it has one. A TXT chapter's `url` is its index's number, which has no anchor.
    static func target(of chapter: OnlineChapterRef) -> ReaderTOCTarget {
        guard let hash = chapter.url.firstIndex(of: "#") else {
            return ReaderTOCTarget(spineIndex: chapter.index, fragment: nil)
        }
        let fragment = String(chapter.url[chapter.url.index(after: hash)...])
        return ReaderTOCTarget(spineIndex: chapter.index, fragment: fragment.isEmpty ? nil : fragment)
    }
}
