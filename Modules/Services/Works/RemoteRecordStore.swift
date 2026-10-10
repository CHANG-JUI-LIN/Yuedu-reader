import Foundation

// Unified library 2d: what WebDAV indexing found, one file per connection,
// `Works/remote/<connection id>.json` beside the shelf file (design §10.1).

/// A book file a crawl found, with what tells a later crawl whether it changed.
struct IndexedFile: Codable, Hashable, Sendable {
    var record: SourceRecord
    var etag: String?
    var lastModified: String?
    var size: Int64
    /// What the EPUB's package said (2e), nil until read.
    var identifiers: [ExternalIdentifier]? = nil
    var values: [MetadataValue]? = nil
    /// The cover's file name in `Caches/Works/covers` (2e).
    var cover: String? = nil
    var filled: FillOutcome? = nil

    enum FillOutcome: Codable, Hashable, Sendable {
        case read
        /// The package could not be read (`SourceFailure.Kind`); not retried until the file changes.
        case failed(SourceFailure.Kind)
    }

    /// Whether this is the same file a previous crawl found, so what was read from it still holds.
    func isSameFile(as other: IndexedFile) -> Bool {
        record.key == other.record.key && etag == other.etag && lastModified == other.lastModified && size == other.size
    }

    /// The fields design §8.3 scores: cover, summary, authors, tags, language, series. Constant
    /// weights; the fewest are filled first.
    var completeness: Int {
        let fields = Set((values ?? []).map(\.field))
        return [cover != nil, fields.contains(.intro), !record.authors.isEmpty || fields.contains(.authors),
                fields.contains(.tags), fields.contains(.language), fields.contains(.series)].filter { $0 }.count
    }

    /// An EPUB whose package has not been read yet.
    var needsFill: Bool { filled == nil && record.key.item.lowercased().hasSuffix(".epub") }
}

/// A folder still to list, and how deep it is below the root.
struct PendingFolder: Codable, Hashable, Sendable {
    var url: URL
    var depth: Int
}

enum WebDAVIndexPauseReason: String, Codable, Hashable, Sendable {
    case notOnWiFi, background, disabled
}

enum WebDAVIndexOutcome: Codable, Hashable, Sendable {
    case completed(Int)
    case limitReached(Int)
    case paused(WebDAVIndexPauseReason)
    /// The failure's kind and its text as shown (the underlying error's own).
    case failed(SourceFailure.Kind, message: String)
    case empty
}

/// One connection's index.
struct WebDAVIndexState: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = WebDAVIndexState.currentSchemaVersion
    var connectionID: String
    /// What the records were found under. Another root, or another user, starts over.
    var root: URL
    var username: String?
    /// The last complete crawl's files.
    var records: [IndexedFile] = []
    /// Files the crawl in progress has found so far.
    var inProgress: [IndexedFile] = []
    /// Folders the crawl in progress has still to list; empty between crawls.
    var frontier: [PendingFolder] = []
    var crawlStartedAt: Date?
    var lastCompletedAt: Date?
    var outcome: WebDAVIndexOutcome?

    /// What the work index sees: the last complete crawl, updated by what the crawl in progress
    /// has found. A file removed on the server leaves only when a crawl completes.
    var visibleFiles: [IndexedFile] {
        guard !inProgress.isEmpty else { return records }
        let found = Set(inProgress.map(\.record.key))
        return inProgress + records.filter { !found.contains($0.record.key) }
    }

    var isCrawling: Bool { !frontier.isEmpty }
}

/// Serial, atomic writes on one queue; a file that does not decode is discarded (the index is
/// derived: crawling again rebuilds it); one that cannot be read is never written over.
final class RemoteRecordStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.yuedu.works.remote")
    private let lock = NSLock()
    private var blocked: Set<String> = []
    /// Connections removed this launch. A crawl's last save can arrive after the removal and
    /// must not bring the file back.
    private var retired: Set<String> = []
    private var revisionValue: UInt64 = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// `<shelf folder>/Works/remote`.
    convenience init(besideShelfFile shelfFile: URL) {
        self.init(directory: shelfFile.deletingLastPathComponent()
            .appendingPathComponent("Works", isDirectory: true)
            .appendingPathComponent("remote", isDirectory: true))
    }

    /// Bumped by every save and removal, so the work index can tell its snapshot is stale.
    var revision: UInt64 { lock.withLock { revisionValue } }

    func state(connectionID: String) -> WebDAVIndexState? {
        queue.sync { read(fileURL(connectionID), connectionID: connectionID) }
    }

    func save(_ state: WebDAVIndexState) {
        lock.withLock { revisionValue &+= 1 }
        queue.async { [self] in
            guard !lock.withLock({ retired.contains(state.connectionID) }) else { return }
            guard !lock.withLock({ blocked.contains(state.connectionID) }) else {
                AppLogger.cache("⟐ WebDAV index not saved: its file could not be read", context: ["connection": state.connectionID])
                return
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(state)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL(state.connectionID), options: .atomic)
            } catch {
                AppLogger.cache("⟐ WebDAV index could not be saved", error: error, context: ["connection": state.connectionID])
            }
        }
    }

    func remove(connectionID: String) {
        lock.withLock {
            revisionValue &+= 1
            blocked.remove(connectionID)
            retired.insert(connectionID)
        }
        queue.async { [self] in
            let url = fileURL(connectionID)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do { try FileManager.default.removeItem(at: url) }
            catch { AppLogger.cache("⟐ WebDAV index could not be removed", error: error, context: ["connection": connectionID]) }
        }
    }

    /// The connections that have an index file.
    func connectionIDs() -> [String] {
        queue.sync {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            } catch {
                AppLogger.cache("⟐ WebDAV index folder could not be listed", error: error)
                return []
            }
            return urls.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        }
    }

    /// Every connection's visible files, for the work index.
    func allVisibleFiles() -> [IndexedFile] {
        queue.sync {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            } catch {
                AppLogger.cache("⟐ WebDAV index folder could not be listed", error: error)
                return []
            }
            return urls.filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .flatMap { read($0, connectionID: $0.deletingPathExtension().lastPathComponent)?.visibleFiles ?? [] }
        }
    }

    #if DEBUG
    func waitForPendingWritesForTesting() {
        queue.sync {}
    }
    #endif

    // MARK: - Files

    private func fileURL(_ connectionID: String) -> URL {
        directory.appendingPathComponent("\(connectionID).json")
    }

    /// On the queue.
    private func read(_ url: URL, connectionID: String) -> WebDAVIndexState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLogger.cache("⟐ WebDAV index could not be read; it will not be written over", error: error, context: ["connection": connectionID])
            lock.withLock { _ = blocked.insert(connectionID) }
            return nil
        }
        do {
            let state = try JSONDecoder().decode(WebDAVIndexState.self, from: data)
            guard state.schemaVersion == WebDAVIndexState.currentSchemaVersion else {
                AppLogger.cache("⟐ WebDAV index has another schema; crawling again", context: ["connection": connectionID])
                return nil
            }
            return state
        } catch {
            // Derived data: crawling again loses nothing.
            AppLogger.cache("⟐ WebDAV index could not be decoded; crawling again", error: error, context: ["connection": connectionID])
            return nil
        }
    }
}
