import Foundation

/// Unified library 1c: keeps the work index of the copies on this device (design §10.1,
/// §10.2; Phase 1 plan, decision 9).
///
/// - Nothing is built until `refresh()` is called; Phase 1 has no caller.
/// - A refresh derives each copy's record on the main actor, from plain maps of the book
///   sources and connections, then reads sidecars and builds off it. The result is applied
///   only if `BookStore.mutationRevision` is unchanged; otherwise it is dropped and the call
///   returns false. Nothing polls the revision.
/// - Incremental: a copy whose record and sidecar stamp are what the last index saw keeps
///   its entry; only the others have their sidecar read. The union-find always runs over
///   every entry, since removing a copy can split a work.
/// - `Works/index.json` is derived. A file of another `schemaVersion`, or one that does not
///   decode, is discarded and rebuilt; one that cannot be read at all is never written over,
///   and the index then lives in memory only (design §10.1).
///
/// Spans carry counts only, never titles or authors (plan decision 11).
@MainActor
final class WorkIndexService {
    private let store: BookStore
    private let fileURL: URL
    private let makeContext: @MainActor ([ReadingBook]) -> SourceRecordContext
    private let decisions: @MainActor () -> [WorkDecision]

    private(set) var index: WorkIndex?
    private var file: WorkIndexFile?
    private var loaded = false
    private var writesBlocked = false

    private static let writeQueue = DispatchQueue(label: "com.yuedu.works.index", qos: .utility)

    init(
        store: BookStore,
        directory: URL,
        makeContext: @escaping @MainActor ([ReadingBook]) -> SourceRecordContext = WorkIndexService.liveContext,
        decisions: @escaping @MainActor () -> [WorkDecision] = { [] }
    ) {
        self.store = store
        self.fileURL = directory.appendingPathComponent("index.json")
        self.makeContext = makeContext
        self.decisions = decisions
    }

    #if DEBUG
    /// Runs after the index is computed and before it is applied, for tests that change the
    /// shelf in between.
    var willApplyForTesting: (@MainActor () -> Void)?
    #endif

    /// Brings the index up to date with the copies. Returns false when the shelf changed
    /// while it was being built, and the result was dropped.
    @discardableResult
    func refresh() async -> Bool {
        let revision = store.mutationRevision
        let books = store.readingBooks
        let records = SourcePerfTrace.span("works.index.snapshot", "copies=\(books.count)", thresholdMs: 5) {
            let context = makeContext(books)
            return books.map { SourceRecord.derived(from: $0, context: context) }
        }
        let decisions = decisions()
        let sidecars = store.importedMetadata
        let fileURL = fileURL
        let needsLoad = !loaded
        let previous = file

        let result = await Task.detached(priority: .utility) {
            let load = needsLoad ? Self.load(fileURL) : .unchanged
            var base = previous
            if case .loaded(let file) = load { base = file }
            let computed = Self.compute(records: records, decisions: decisions, previous: base, sidecars: sidecars)
            return (load, base, computed)
        }.value
        let (load, base, computed) = result

        if needsLoad {
            loaded = true
            if case .unreadable = load { writesBlocked = true }
            file = base
        }
        #if DEBUG
        willApplyForTesting?()
        #endif
        guard store.mutationRevision == revision else {
            AppLogger.cache("⟐ works index dropped: the shelf changed while it was built",
                            context: ["copies": "\(records.count)"])
            return false
        }
        file = computed.file
        index = computed.file.index
        if computed.changed { save(computed.file) }
        return true
    }

    /// Local search over the current index; empty before the first refresh.
    func search(_ query: String) -> [Work] {
        guard let index else { return [] }
        return SourcePerfTrace.span("works.search.local", "works=\(index.works.count)", thresholdMs: 1) {
            index.search(query)
        }
    }

    // MARK: - Loading and saving

    enum LoadOutcome: Sendable {
        case unchanged, missing, loaded(WorkIndexFile), discarded, unreadable
    }

    nonisolated static func load(_ url: URL) -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLogger.cache("⟐ works index could not be read; it will not be written over", error: error)
            return .unreadable
        }
        return SourcePerfTrace.span("works.index.load", "bytes=\(data.count)", thresholdMs: 1) {
            do {
                let file = try JSONDecoder.works.decode(WorkIndexFile.self, from: data)
                guard file.schemaVersion == WorkIndexFile.currentSchemaVersion else {
                    AppLogger.cache("⟐ works index has another schema; rebuilding",
                                    context: ["schemaVersion": "\(file.schemaVersion)"])
                    return .discarded
                }
                return .loaded(file)
            } catch {
                // Derived data: rebuilding loses nothing.
                AppLogger.cache("⟐ works index could not be decoded; rebuilding", error: error)
                return .discarded
            }
        }
    }

    private func save(_ file: WorkIndexFile) {
        guard !writesBlocked else { return }
        let url = fileURL
        Self.writeQueue.async {
            do {
                let data = try JSONEncoder.works.encode(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.cache("⟐ works index could not be saved", error: error)
            }
        }
    }

    #if DEBUG
    /// Drains queued saves, for tests.
    static func waitForPendingSavesForTesting() {
        writeQueue.sync {}
    }
    #endif

    // MARK: - Building

    struct Computed: Sendable {
        var file: WorkIndexFile
        /// False when nothing differs from `previous`, which is then kept as it is.
        var changed: Bool
    }

    nonisolated static func compute(
        records: [SourceRecord],
        decisions: [WorkDecision],
        previous: WorkIndexFile?,
        sidecars: ImportedMetadataStore
    ) -> Computed {
        let previousInputs = Dictionary((previous?.inputs ?? []).map { ($0.record.copyID, $0) }, uniquingKeysWith: { first, _ in first })
        let previousEntries = Dictionary((previous?.index.entries ?? []).map { ($0.nodeKey, $0) }, uniquingKeysWith: { first, _ in first })
        var inputs: [WorkIndexFile.Input] = []
        var entries: [WorkIndexEntry] = []
        var reread = 0
        let stamps = sidecars.stamps()
        for record in records {
            guard let copyID = record.copyID else { continue }
            let stamp = stamps[copyID]
            inputs.append(WorkIndexFile.Input(record: record, sidecar: stamp))
            if let old = previousInputs[copyID], old.record == record, old.sidecar == stamp,
               let entry = previousEntries[record.copyKey ?? record.key] {
                entries.append(entry)
            } else {
                reread += 1
                entries.append(entry(for: record, sidecar: stamp == nil ? nil : sidecars.read(copyID: copyID)))
            }
        }
        inputs.sort { $0.record.copyID?.uuidString ?? "" < $1.record.copyID?.uuidString ?? "" }
        if let previous, reread == 0, inputs == previous.inputs, decisions == previous.decisions {
            return Computed(file: previous, changed: false)
        }
        let index = SourcePerfTrace.span("works.index.build", "entries=\(entries.count) reread=\(reread)", thresholdMs: 1) {
            WorkIndex.build(entries: entries, decisions: decisions)
        }
        return Computed(
            file: WorkIndexFile(schemaVersion: WorkIndexFile.currentSchemaVersion, inputs: inputs, decisions: decisions, index: index),
            changed: true
        )
    }

    /// A copy's entry: its record, plus the identifiers and language its sidecar holds.
    nonisolated static func entry(for record: SourceRecord, sidecar: ImportedMetadata?) -> WorkIndexEntry {
        WorkIndexEntry(
            record: record,
            extraIdentifiers: sidecar?.identifiers ?? [],
            language: sidecar.flatMap { language(in: $0, for: record) } ?? LanguageTag(record.language)
        )
    }

    /// One language per copy, by a fixed priority, never a union: what the copy's own file
    /// says (the local library), then the place the copy came from, then any other place in
    /// key order. A Calibre `zho` beside an OPF `en` gives the copy `en`.
    nonisolated static func language(in metadata: ImportedMetadata, for record: SourceRecord) -> LanguageTag? {
        func rank(_ provider: SourceInstanceKey) -> (Int, String) {
            if provider == .localLibrary { return (0, "") }
            if provider == record.key.instance { return (1, "") }
            return (2, "\(provider.type.rawValue)\u{1F}\(provider.id)")
        }
        let candidates = metadata.values
            .filter { $0.field == .language }
            .sorted { rank($0.provider) < rank($1.provider) }
        for value in candidates {
            let texts: [String]
            switch value.value {
            case .text(let text): texts = [text]
            case .texts(let list): texts = list
            case .number, .date: texts = []
            }
            if let tag = texts.lazy.compactMap(LanguageTag.init).first { return tag }
        }
        return nil
    }

    // MARK: - Context

    /// The book sources and connections the copies refer to, copied into plain maps. Building a
    /// WebDAV client per copy would read the keychain each time; the root is computed the way
    /// `WebDAVBrowseClient.rootURL` computes it.
    static func liveContext(for books: [ReadingBook]) -> SourceRecordContext {
        var sourceURLs: [UUID: String] = [:]
        for id in Set(books.compactMap(\.bookSourceId)) {
            sourceURLs[id] = BookSourceStore.shared.source(id: id)?.bookSourceUrl
        }
        var kinds: [String: RemoteLibraryKind] = [:]
        var roots: [String: URL] = [:]
        for connection in RemoteLibraryConnectionStore.shared.connections {
            kinds[connection.id] = connection.kind
            if connection.kind == .webDAV {
                roots[connection.id] = RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV)
            }
        }
        return SourceRecordContext(
            bookSourceURL: { sourceURLs[$0] },
            connectionKind: { kinds[$0] },
            webDAVRoot: { roots[$0] }
        )
    }
}

/// `Works/index.json`.
struct WorkIndexFile: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    /// What each copy's entry was built from. A copy whose record and sidecar stamp are the
    /// same next time keeps its entry.
    struct Input: Codable, Hashable, Sendable {
        var record: SourceRecord
        var sidecar: SidecarStamp?
    }

    var schemaVersion: Int
    /// Sorted by copy id.
    var inputs: [Input]
    var decisions: [WorkDecision]
    var index: WorkIndex
}

// Dates keep the default strategy, a `Double` that round-trips exactly. ISO 8601 drops the
// sub-second part of a sidecar's modification date, and every copy would look changed on
// the next launch.
private extension JSONEncoder {
    static var works: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var works: JSONDecoder { JSONDecoder() }
}
