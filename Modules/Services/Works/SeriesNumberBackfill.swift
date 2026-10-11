import Foundation

/// Unified library 5d-6b: reads every local EPUB copy's package once more, so copies imported
/// before series numbers were read get theirs (Phase 5 plan, decision 25). Until 5d-6b the
/// import kept no series at all, and 系列下一本 has nothing to go on without a number.
///
/// Decision 25 amends Phase 1's decision 8 (no background scan of the shelf) for this one pass:
/// it runs the first time 系列下一本 loads, which is when 探索 opens with that section, and never
/// again once it has gone through every copy. A copy whose file cannot be read is logged and not
/// retried. WebDAV files are not read again: theirs get a number when they are new or changed
/// (`WebDAVMetadataFiller`).
///
/// That the pass is done is a file beside the shelf (`Works/series-numbers-read`), not a
/// default: it belongs to this shelf, and a test's shelf in a temporary folder leaves the app's
/// own untouched.
@MainActor
final class SeriesNumberBackfill {
    private let store: BookStore
    private let doneMarker: URL
    private let reread: @MainActor (ReadingBook) async -> Bool
    private var running: Task<Void, Never>?

    /// - Parameter worksDirectory: the shelf's `Works` folder.
    init(store: BookStore, worksDirectory: URL, reread: (@MainActor (ReadingBook) async -> Bool)? = nil) {
        self.store = store
        self.doneMarker = worksDirectory.appendingPathComponent("series-numbers-read")
        self.reread = reread ?? { [store] copy in await ImportedMetadataCapture.reread(copy: copy, store: store) }
    }

    var isDone: Bool { FileManager.default.fileExists(atPath: doneMarker.path) }

    /// Runs the pass unless it has finished before; a caller arriving during it waits for it.
    func runOnce() async {
        guard !isDone else { return }
        if let running {
            await running.value
            return
        }
        let task = Task { await run() }
        running = task
        await task.value
        running = nil
    }

    private func run() async {
        let copies = store.readingBooks.filter { $0.remoteSource == nil && $0.source == "local_epub" }
        let started = SourcePerfTrace.now
        var read = 0
        for copy in copies {
            if await reread(copy) { read += 1 }
        }
        // The sidecars are written on their own queue; the index reads their stamps after them.
        SourcePerfTrace.record("works.series.backfill", "copies=\(copies.count) read=\(read) failed=\(copies.count - read)",
                               since: started, thresholdMs: 0)
        // Only after the whole pass: an app closed during it starts it again.
        do {
            try FileManager.default.createDirectory(at: doneMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: doneMarker, options: .atomic)
        } catch {
            AppLogger.cache("⟐ series numbers were read, but the pass could not be marked done; it runs again next time",
                            error: error)
        }
    }
}
