import Combine
import Foundation

/// Unified library Phase 3d: when the filler runs (maintainer, 2026-10-14: 背景自動補齊
/// 「做，預設開啟」).
///
/// - A pass runs while the app is active, the network allows background work (Wi-Fi or wired,
///   not expensive or constrained: the rule WebDAV indexing uses), Low Power Mode is off and
///   設定 → 網路設定 → 自動補齊書籍資料 is on.
/// - It starts when the app becomes active, when the shelf has loaded, when a book joins the
///   shelf, when an import writes more about a shelf copy (`announcedWrites`), and when the
///   book sources there are to ask change (imported, turned on); it stops
///   when any condition stops holding. Each copy is asked once per
///   provider (`MetadataFillLedger`), so a pass after the first asks only new or changed
///   copies.
/// - The places it asks, and their order, are 資料來源's (`MetadataFillOrder`, Phase 6h). When
///   that list or the installed modules change, a running pass stops at once and starts again
///   with the new places: a module just unchecked or removed is asked nothing more.
@MainActor
final class MetadataFillCoordinator {
    private let store: BookStore
    private let makeProviders: @MainActor () -> [any MetadataFillProvider]
    /// What the providers need read first: the installed modules, which nothing else may have
    /// loaded yet when 探索, 資源庫 and 搜索 were never opened.
    private let prepare: @MainActor () async -> Void
    private let network: NetworkPathProviding
    private let isEnabled: @MainActor () -> Bool
    private let isLowPower: @MainActor () -> Bool
    private var isActive = false
    private var running: Task<Void, Never>?
    /// Asked to run again while a pass was running: a book joined, or the app came back.
    private var rerun = false
    private var generation = 0
    private var knownShelf: [UUID: String] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - placesChanged: the places to ask changed; by default 資料來源's order or the
    ///     installed modules that can fill.
    ///   - sourcesChanged: the book sources to ask changed; by default the ones
    ///     `BookSourceFillProvider` would ask. Nothing by default with injected providers.
    init(store: BookStore,
         makeProviders: (@MainActor () -> [any MetadataFillProvider])? = nil,
         placesChanged: AnyPublisher<Void, Never>? = nil,
         sourcesChanged: AnyPublisher<Void, Never>? = nil,
         network: (any NetworkPathProviding)? = nil,
         isEnabled: (@MainActor () -> Bool)? = nil,
         isLowPower: (@MainActor () -> Bool)? = nil) {
        let network = network ?? NetworkPathMonitor.shared
        self.store = store
        self.makeProviders = makeProviders ?? Self.liveProviders
        prepare = makeProviders == nil ? { await RuleModuleLibrary.shared.loadIfNeeded() } : {}
        self.network = network
        self.isEnabled = isEnabled ?? { GlobalSettings.shared.autoFillBookMetadata }
        self.isLowPower = isLowPower ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
        network.allowsBackgroundWorkPublisher
            .sink { [weak self] _ in self?.conditionsChanged() }
            .store(in: &cancellables)
        store.shelfPublisher
            // What a copy is asked by: a new copy, or a title or author edited (編輯資訊, a TXT
            // whose author was recovered), is asked again.
            .map { Dictionary($0.map { ($0.id, $0.title + "\u{1F}" + $0.author) }, uniquingKeysWith: { first, _ in first }) }
            .removeDuplicates()
            .sink { [weak self] shelf in self?.shelfChanged(shelf) }
            .store(in: &cancellables)
        store.importedMetadata.announcedWrites
            .sink { [weak self] id in self?.sidecarWritten(id) }
            .store(in: &cancellables)
        (placesChanged ?? Self.livePlacesChanged)
            .sink { [weak self] in self?.placesChanged() }
            .store(in: &cancellables)
        (sourcesChanged ?? (makeProviders == nil ? Self.liveSourcesChanged : Empty().eraseToAnyPublisher()))
            .sink { [weak self] in self?.sourcesChanged() }
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

    /// A running pass holds the providers it started with: it is replaced, not left to finish.
    private func placesChanged() {
        stop()
        if mayRun { start() }
    }

    /// 資料來源's checked places, first first. AI 推薦's missing covers are asked of them too
    /// (`AIRecommendationService.fillCovers`). The installed modules must have been read.
    static func liveProviders() -> [any MetadataFillProvider] {
        let modules = RuleModuleLibrary.shared.fillingModules
        return MetadataFillOrderStore.shared.order(modules: modules.map(\.id)).providers(modules: modules)
    }

    /// Each value is published once on subscribing: only later changes count.
    private static var livePlacesChanged: AnyPublisher<Void, Never> {
        let order = MetadataFillOrderStore.shared.$stored.dropFirst().map { _ in () }
        let modules = RuleModuleLibrary.shared.$modules
            .map { $0.map(\.module).filter(\.canFill).map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .map { _ in () }
        return order.merge(with: modules).eraseToAnyPublisher()
    }

    /// The sources `BookSourceFillProvider` asks (at most its 40), after the first value.
    private static var liveSourcesChanged: AnyPublisher<Void, Never> {
        BookSourceStore.shared.sourcesPublisher
            // The published value: the publisher sends before the store holds it.
            .map { BookSourceFillProvider.eligibleSources(in: $0).map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// A copy no source could be asked about leaves no ledger entry: the pass asks it now. A
    /// running pass finishes with the providers it has and runs again.
    private func sourcesChanged() {
        if mayRun { start() }
    }

    private func shelfChanged(_ shelf: [UUID: String]) {
        let askedAgain = shelf.contains { knownShelf[$0.key] != $0.value }
        knownShelf = shelf
        if askedAgain, mayRun { start() }
    }

    /// An import or re-read wrote more about a shelf copy (an ISBN, a description) after it
    /// joined the shelf.
    private func sidecarWritten(_ id: UUID) {
        if knownShelf[id] != nil, mayRun { start() }
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
        await prepare()
        guard !Task.isCancelled else { return }
        let runner = MetadataFillRunner(providers: makeProviders(), ledger: store.metadataFillLedger,
                                        write: { [store] in Self.write($0, to: store) },
                                        nameAuthor: { [store] in store.nameUnknownAuthor($1, for: $0) })
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

    /// The shelf's text and comic copies as the filler sees them; sidecars are read off the main thread.
    private func candidates() async -> [MetadataFillCandidate] {
        let books = store.books
        let context = WorkIndexService.liveContext(for: books)
        let inputs = books.compactMap { book -> Input? in
            let record = SourceRecord.derived(from: book, context: context)
            guard record.contentKind == .text || record.contentKind == .comic else { return nil }
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
                    hasOwnCover: input.hasOwnCover, values: sidecar?.values ?? [], decisions: input.decisions,
                    contentKind: input.record.contentKind)
            }
        }.value
    }
}
