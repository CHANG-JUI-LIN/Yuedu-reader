import Combine
import Foundation

/// Unified library Phase 3d: when the filler runs (maintainer, 2026-10-14: 背景自動補齊
/// 「做，預設開啟」).
///
/// - A pass runs while the app is active, the network allows background work (Wi-Fi or wired,
///   not expensive or constrained: the rule WebDAV indexing uses), Low Power Mode is off and
///   設定 → 網路設定 → 自動補齊書籍資料 is on.
/// - It starts when the app becomes active, when the shelf has loaded, when a book joins the
///   shelf, and when an import writes more about a shelf copy (`announcedWrites`); it stops
///   when any condition stops holding. Each copy is asked once per
///   provider (`MetadataFillLedger`), so a pass after the first asks only new or changed
///   copies.
@MainActor
final class MetadataFillCoordinator {
    private let store: BookStore
    private let makeProviders: @MainActor () -> [any MetadataFillProvider]
    private let network: NetworkPathProviding
    private let isEnabled: @MainActor () -> Bool
    private let isLowPower: @MainActor () -> Bool
    private var isActive = false
    private var running: Task<Void, Never>?
    /// Asked to run again while a pass was running: a book joined, or the app came back.
    private var rerun = false
    private var generation = 0
    private var knownShelf: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(store: BookStore,
         makeProviders: (@MainActor () -> [any MetadataFillProvider])? = nil,
         network: NetworkPathProviding = NetworkPathMonitor.shared,
         isEnabled: (@MainActor () -> Bool)? = nil,
         isLowPower: (@MainActor () -> Bool)? = nil) {
        self.store = store
        self.makeProviders = makeProviders ?? { [OpenLibraryFillProvider(), BookSourceFillProvider()] }
        self.network = network
        self.isEnabled = isEnabled ?? { GlobalSettings.shared.autoFillBookMetadata }
        self.isLowPower = isLowPower ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
        network.allowsBackgroundWorkPublisher
            .sink { [weak self] _ in self?.conditionsChanged() }
            .store(in: &cancellables)
        store.shelfPublisher
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .sink { [weak self] ids in self?.shelfChanged(ids) }
            .store(in: &cancellables)
        store.importedMetadata.announcedWrites
            .sink { [weak self] id in self?.sidecarWritten(id) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.conditionsChanged() }
            .store(in: &cancellables)
    }

    var isRunning: Bool { running != nil }

    func setActive(_ active: Bool) {
        isActive = active
        conditionsChanged()
    }

    /// The setting, the network or the power state changed.
    func conditionsChanged() {
        if mayRun { start() } else { stop() }
    }

    private var mayRun: Bool { isActive && isEnabled() && network.allowsBackgroundWork && !isLowPower() }

    private func shelfChanged(_ ids: Set<UUID>) {
        let added = !ids.subtracting(knownShelf).isEmpty
        knownShelf = ids
        if added, mayRun { start() }
    }

    /// An import or re-read wrote more about a shelf copy (an ISBN, a description) after it
    /// joined the shelf.
    private func sidecarWritten(_ id: UUID) {
        if knownShelf.contains(id), mayRun { start() }
    }

    private func start() {
        guard running == nil else {
            rerun = true
            return
        }
        rerun = false
        generation += 1
        let mine = generation
        running = Task { [weak self] in
            await self?.runPass()
            // A pass stopped and replaced since does not clear its successor.
            guard let self, self.generation == mine else { return }
            self.running = nil
            if self.rerun, self.mayRun { self.start() }
        }
    }

    private func stop() {
        running?.cancel()
        running = nil
        rerun = false
        generation += 1
    }

    #if DEBUG
    /// Waits for the running pass, and any pass it starts again, to end; for tests.
    func waitUntilIdleForTesting() async {
        while let running { await running.value }
    }
    #endif

    /// One pass over the shelf as it is now. The ledger is saved after every answer, so a pass
    /// stopped half-way goes on from where it was next time.
    private func runPass() async {
        let runner = MetadataFillRunner(providers: makeProviders(), ledger: store.metadataFillLedger,
                                        write: { [store] in Self.write($0, to: store) })
        store.metadataFillLedger.keep(only: Set(store.books.map(\.id)))
        let candidates = await candidates()
        guard !Task.isCancelled else { return }
        let started = SourcePerfTrace.now
        let report = await runner.fill(candidates)
        SourcePerfTrace.record("metadata.fill.pass", "copies=\(candidates.count) asked=\(report.asked) filled=\(report.filled) failed=\(report.failed)",
                               since: started, thresholdMs: 0)
    }

    /// A sidecar write, and a filled cover straight into the shelf's index.
    private static func write(_ metadata: ImportedMetadata, to store: BookStore) {
        store.importedMetadata.write(metadata, announces: false)
        if let name = metadata.values.first(where: { $0.field == .cover }).flatMap({ FilledMetadata.coverFileName($0.value) }) {
            store.filledCovers.set(FilledMetadata.coverDirectory.appendingPathComponent(name).path, for: metadata.copyID)
        }
    }

    private struct Input: Sendable {
        var id: UUID
        var title: String
        var record: SourceRecord
        var hasOwnCover: Bool
        var decisions: [WorkDecision]
    }

    /// The shelf's text copies as the filler sees them; sidecars are read off the main thread.
    private func candidates() async -> [MetadataFillCandidate] {
        let books = store.books
        let context = WorkIndexService.liveContext(for: books)
        let inputs = books.compactMap { book -> Input? in
            let record = SourceRecord.derived(from: book, context: context)
            guard record.contentKind == .text else { return nil }
            return Input(id: book.id, title: book.title, record: record, hasOwnCover: book.hasOwnCoverArtwork,
                         decisions: store.workDecisions.decisions(involving: .copy(book.id)))
        }
        let sidecars = store.importedMetadata
        return await Task.detached(priority: .utility) {
            inputs.map { input in
                let sidecar = sidecars.read(copyID: input.id)
                var identifiers = input.record.identifiers
                identifiers.formUnion(sidecar?.identifiers ?? [])
                return MetadataFillCandidate(
                    copyID: input.id, title: input.title, authors: input.record.authors,
                    identifiers: identifiers.sorted { ($0.scheme.rawValue, $0.value) < ($1.scheme.rawValue, $1.value) },
                    copySource: input.record.key.instance, sidecarSourceItem: sidecar?.sourceItem ?? input.record.key,
                    hasOwnCover: input.hasOwnCover, values: sidecar?.values ?? [], decisions: input.decisions)
            }
        }.value
    }
}
