import Foundation
import os

/// Every book's table of contents on this device: one file per book, beside the shelf.
///
/// legado keeps chapters in a table of their own (`BookChapterDao`). The bookshelf reads
/// books; a book's list is read when something needs it (`getChapterList(bookUrl)`), and
/// a table-of-contents refresh replaces that one book's rows (`delByBook` + `insert`).
/// This is that table. `books_meta.json` holds the books, each with a summary of its list
/// (`ReadingBook.totalChapterNum` / `latestChapterTitle`, as legado's `Book` carries), and
/// the lists live here.
///
/// Until 2026-10 every list sat inside `books_meta.json`, and every shelf save — each
/// progress tick of 聽書 among them — encoded all of them on the main thread. A tester's
/// 110 online books made the file 138 MB, and the save made as the app left the
/// foreground outlasted the 10-second scene-update watchdog (0x8BADF00D; build 113
/// MetricKit: `flushPendingMetadataSave` → `encodeBooksMetadata`).
///
/// A changed list is written by the next shelf save (`flush`), so a run of chapter-cache
/// marks costs one write of that one book.
final class BookChapterStore: Sendable {
    private struct Entry {
        /// `nil`: the book has no list.
        var chapters: [OnlineChapterRef]?
        /// Changed since its file was last written. A changed entry is never evicted.
        var isDirty: Bool
        /// Advances on every change, so a flush cannot mark clean a change made while it wrote.
        var revision: Int
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        /// Clean entries holding a list, least recently used first.
        var recency: [UUID] = []
        var nextRevision = 0
    }

    /// Lists kept in memory once read. A reader holds the one it is on; a pass over the
    /// whole shelf (the launch refresh, AI 整理) reads one book after another and must not
    /// end up holding them all, as the shelf file used to.
    private static let cachedListLimit = 8

    let directoryURL: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func fileURL(for bookID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(bookID.uuidString).json")
    }

    /// The book's list, read from its file the first time it is asked for.
    func chapters(for bookID: UUID) -> [OnlineChapterRef]? {
        if let cached = state.withLock({ state -> Entry? in
            guard let entry = state.entries[bookID] else { return nil }
            Self.touch(bookID, entry: entry, in: &state)
            return entry
        }) {
            return cached.chapters
        }
        let loaded = readFile(for: bookID)
        return state.withLock { state in
            // Set while this read was in flight: that list is newer than the file.
            if let entry = state.entries[bookID] { return entry.chapters }
            let entry = Entry(chapters: loaded, isDirty: false, revision: state.nextRevision)
            state.entries[bookID] = entry
            Self.touch(bookID, entry: entry, in: &state)
            Self.evictLeastRecentlyUsed(in: &state)
            return loaded
        }
    }

    /// Whether the book's list is on disk, without reading it.
    func hasStoredList(for bookID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: bookID).path)
    }

    /// Whether the book has a list — in memory, possibly not yet written, or on disk —
    /// without reading it.
    func hasList(for bookID: UUID) -> Bool {
        if let entry = state.withLock({ $0.entries[bookID] }) { return entry.chapters != nil }
        return hasStoredList(for: bookID)
    }

    /// Replaces the book's list; an empty one removes it. Written by the next `flush`.
    func setChapters(_ chapters: [OnlineChapterRef], for bookID: UUID) {
        let list: [OnlineChapterRef]? = chapters.isEmpty ? nil : chapters
        state.withLock { state in
            if let entry = state.entries[bookID], entry.chapters == list { return }
            Self.markChanged(bookID, chapters: list, in: &state)
        }
    }

    /// The book is gone: its list goes with it at the next `flush`.
    func removeChapters(for bookID: UUID) {
        state.withLock { state in
            Self.markChanged(bookID, chapters: nil, in: &state)
        }
    }

    /// Removes the list of every book not in `bookIDs`. Pass only a shelf known to be
    /// complete, never the result of a load that may have failed.
    func removeChapters(notIn bookIDs: Set<UUID>) {
        var stored: [String] = []
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            do {
                stored = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            } catch {
                AppLogger.error("Tables of contents could not be listed", error: error)
            }
        }
        let storedIDs = stored.compactMap { name -> UUID? in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(".json".count)))
        }
        let cachedIDs = state.withLock { Array($0.entries.keys) }
        let orphans = Set(storedIDs + cachedIDs).subtracting(bookIDs)
        guard !orphans.isEmpty else { return }
        AppLogger.cache("目錄：移除已不在書架與閱讀紀錄中的書的目錄", context: ["count": orphans.count])
        for bookID in orphans {
            removeChapters(for: bookID)
        }
    }

    var hasUnwrittenChanges: Bool {
        state.withLock { $0.entries.values.contains(where: \.isDirty) }
    }

    /// Writes every changed list and deletes the removed ones. A list that cannot be
    /// written stays changed, and the next flush tries again.
    func flush() {
        let pending = state.withLock { state in
            state.entries.filter { $0.value.isDirty }
        }
        guard !pending.isEmpty else { return }
        // Bytes are part of the line: the field's disk-write exceptions (≈1 GB within a minute
        // of launch) were this flush rewriting every list, which time alone did not show.
        var bytes = 0
        SourcePerfTrace.span("library.chapters.write", "books=\(pending.count) bytes=\(bytes) main=\(Thread.isMainThread)", thresholdMs: 5) {
            var written: [UUID: Int] = [:]
            for (bookID, entry) in pending {
                do {
                    bytes += try write(entry.chapters, for: bookID)
                    written[bookID] = entry.revision
                } catch {
                    AppLogger.error(
                        "Table of contents could not be saved",
                        error: error,
                        context: ["book": bookID.uuidString, "chapters": entry.chapters?.count ?? 0]
                    )
                }
            }
            state.withLock { [written] state in
                for (bookID, revision) in written {
                    guard var entry = state.entries[bookID], entry.revision == revision else { continue }
                    entry.isDirty = false
                    state.entries[bookID] = entry
                    Self.touch(bookID, entry: entry, in: &state)
                }
                Self.evictLeastRecentlyUsed(in: &state)
            }
        }
    }

    // MARK: - Files

    private func readFile(for bookID: UUID) -> [OnlineChapterRef]? {
        let url = fileURL(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try SourcePerfTrace.span("library.chapters.read", "bytes=\(data.count)", thresholdMs: 5) {
                try JSONDecoder().decode([OnlineChapterRef].self, from: data)
            }
        } catch {
            // Read as "no list": the book's next table-of-contents refresh writes a new one.
            AppLogger.error(
                "Table of contents could not be read",
                error: error,
                context: ["book": bookID.uuidString]
            )
            return nil
        }
    }

    /// Returns the bytes written: none for a list its file already holds.
    ///
    /// `setChapters` compares only with the lists held in memory, `cachedListLimit` of them,
    /// so a launch refresh over a larger shelf set every other list again unchanged, and each
    /// was rewritten: 173 books, 1.08 GB within a minute (MetricKit disk-write exception,
    /// build 129). The file is compared here rather than there: `setChapters` runs on the
    /// main thread during a refresh, and shelf saves flush on `BookStore.persistQueue`.
    private func write(_ chapters: [OnlineChapterRef]?, for bookID: UUID) throws -> Int {
        let url = fileURL(for: bookID)
        guard let chapters else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return 0
        }
        if readFile(for: bookID) == chapters { return 0 }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(chapters)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    // MARK: - Cache

    private static func markChanged(_ bookID: UUID, chapters: [OnlineChapterRef]?, in state: inout State) {
        state.nextRevision &+= 1
        state.entries[bookID] = Entry(chapters: chapters, isDirty: true, revision: state.nextRevision)
        state.recency.removeAll { $0 == bookID }
    }

    private static func touch(_ bookID: UUID, entry: Entry, in state: inout State) {
        guard !entry.isDirty, entry.chapters != nil else { return }
        state.recency.removeAll { $0 == bookID }
        state.recency.append(bookID)
    }

    private static func evictLeastRecentlyUsed(in state: inout State) {
        while state.recency.count > cachedListLimit {
            state.entries.removeValue(forKey: state.recency.removeFirst())
        }
    }
}
