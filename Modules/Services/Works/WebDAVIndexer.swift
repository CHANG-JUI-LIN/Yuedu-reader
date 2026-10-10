import Foundation

/// How far one connection's crawl may go (unified library 2d). Set from measurement; see the
/// Phase 2 plan's "What landed" for the numbers behind each value.
struct WebDAVIndexLimits: Hashable, Sendable {
    /// Folders below the root deeper than this are not listed.
    var maxDepth: Int
    /// Folders listed between two saves of the crawl's progress. A pause loses at most these.
    var foldersPerBatch: Int
    /// Book files per connection; the crawl stops there and reports the limit.
    var maxFiles: Int
    /// A completed crawl is not repeated sooner than this.
    var recrawlInterval: TimeInterval

    /// Measured against a real WebDAV server (Apache `mod_dav`, Phase 2 plan "What landed",
    /// 2d): a 20,000-book tree in 2,047 folders crawls in about 4 s locally, about 2 ms a
    /// folder plus the network's round trip, and its index file is 8.5 MB.
    /// - `foldersPerBatch` 100: each save rewrites the whole file, so 20 cost about 100 rewrites
    ///   of up to 8.5 MB on such a tree. 100 cost about 20, and the batch finished on entering
    ///   the background is about 3 s at a NAS's ~30 ms a folder.
    /// - `maxFiles` 20,000: the work index's refresh with that many records took 5.2 s in Debug.
    /// - `maxDepth` 10, `recrawlInterval` a day: not measured; a library deeper than ten folders
    ///   is rare, and a book library changes slowly.
    static let standard = WebDAVIndexLimits(maxDepth: 10, foldersPerBatch: 100, maxFiles: 20_000, recrawlInterval: 24 * 60 * 60)
}

/// One connection's crawl: breadth-first `PROPFIND Depth: 1` from the root, within the limits.
/// Every book file becomes a `SourceRecord` (1a's derivation); its ETag, modification date and
/// size are kept for fingerprinting. The frontier is saved after each batch, so a crawl resumes
/// where it stopped.
struct WebDAVIndexer: Sendable {
    let connectionID: String
    let root: URL
    let limits: WebDAVIndexLimits
    /// One folder's listing: `WebDAVBrowseClient.list` on the indexer's own client.
    let list: @Sendable (URL) async throws -> [WebDAVBrowseClient.Entry]
    let save: @Sendable (WebDAVIndexState) -> Void
    let now: @Sendable () -> Date

    /// Runs the crawl from `state` until it completes, reaches the file limit, fails, or is
    /// asked to stop. `stopAfterBatch` is checked between batches (the app is going to the
    /// background: finish the batch in hand); cancellation stops at once (Wi-Fi lost, setting
    /// turned off, connection removed) and the caller records why.
    func run(from state: WebDAVIndexState, stopAfterBatch: @Sendable () -> Bool) async -> WebDAVIndexState {
        var state = state
        if state.frontier.isEmpty {
            state.frontier = [PendingFolder(url: root, depth: 0)]
            state.inProgress = []
            state.crawlStartedAt = now()
        }
        // What 2e read from a file stays with it while the file is unchanged.
        let previous = Dictionary(state.records.map { ($0.record.key, $0) }, uniquingKeysWith: { first, _ in first })
        var skippedFolders = 0
        let started = SourcePerfTrace.now
        defer {
            SourcePerfTrace.record("works.webdav.crawl", "files=\(state.visibleFiles.count) pending=\(state.frontier.count) skipped=\(skippedFolders)",
                                   since: started, thresholdMs: 0)
        }
        while !state.frontier.isEmpty {
            var listed = 0
            while listed < limits.foldersPerBatch, let folder = state.frontier.first {
                let entries: [WebDAVBrowseClient.Entry]
                do {
                    try Task.checkCancellation()
                    // Only slow folders are logged: a crawl lists thousands.
                    entries = try await SourcePerfTrace.spanAsync("works.webdav.list", "depth=\(folder.depth)", thresholdMs: 500) {
                        try await list(folder.url)
                    }
                } catch {
                    return stopped(state, by: error)
                }
                state.frontier.removeFirst()
                listed += 1
                for entry in entries {
                    if entry.isDirectory {
                        if folder.depth + 1 <= limits.maxDepth {
                            state.frontier.append(PendingFolder(url: entry.url, depth: folder.depth + 1))
                        } else {
                            skippedFolders += 1
                        }
                    } else if entry.isImportableBook,
                              let record = SourceRecord.derived(from: entry, connectionID: connectionID, root: root) {
                        var file = IndexedFile(record: record, etag: entry.etag, lastModified: entry.lastModified, size: entry.size)
                        if let old = previous[record.key], old.isSameFile(as: file) {
                            file.identifiers = old.identifiers
                            file.values = old.values
                            file.cover = old.cover
                            file.filled = old.filled
                        }
                        state.inProgress.append(file)
                        if state.inProgress.count >= limits.maxFiles {
                            return finish(state, outcome: .limitReached(state.inProgress.count))
                        }
                    }
                }
            }
            guard !state.frontier.isEmpty else { break }
            state.outcome = nil
            save(state)
            if stopAfterBatch() {
                state.outcome = .paused(.background)
                save(state)
                return state
            }
        }
        return finish(state, outcome: state.inProgress.isEmpty ? .empty : .completed(state.inProgress.count))
    }

    private func finish(_ state: WebDAVIndexState, outcome: WebDAVIndexOutcome) -> WebDAVIndexState {
        var state = state
        state.records = state.inProgress
        state.inProgress = []
        state.frontier = []
        state.lastCompletedAt = now()
        state.outcome = outcome
        save(state)
        AppLogger.cache("⟐ WebDAV index finished", context: ["connection": connectionID, "files": "\(state.records.count)",
                                                             "outcome": Self.describe(outcome)])
        return state
    }

    /// A cancelled crawl keeps its frontier and lets the caller say why; a failed one records
    /// the failure and keeps its frontier too, so the next start resumes.
    private func stopped(_ state: WebDAVIndexState, by error: any Error) -> WebDAVIndexState {
        var state = state
        let failure: SourceFailure
        do {
            failure = try SourceFailure.classify(error)
        } catch {
            save(state)
            return state
        }
        state.outcome = .failed(failure.kind, message: failure.localizedDescription)
        save(state)
        // `AppLogger` writes only the error's description, which names no path; the code and
        // status are what diagnose it.
        let code = (failure.underlying as? URLError).map { "\($0.code.rawValue)" } ?? failure.status.map { "http \($0)" } ?? "-"
        AppLogger.network("WebDAV index failed", error: SourceFailure.loggable(failure),
                          context: ["connection": connectionID, "kind": failure.kind.rawValue, "code": code, "pending": "\(state.frontier.count)"])
        return state
    }

    static func describe(_ outcome: WebDAVIndexOutcome) -> String {
        switch outcome {
        case .completed(let count): "completed(\(count))"
        case .limitReached(let count): "limitReached(\(count))"
        case .paused(let reason): "paused(\(reason.rawValue))"
        case .failed(let kind, _): "failed(\(kind.rawValue))"
        case .empty: "empty"
        }
    }
}
