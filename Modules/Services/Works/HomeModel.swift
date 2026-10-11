import Combine
import Foundation

/// Unified library 5b: the Explore home's rows, loaded by each section's policy (design
/// §13.3–§13.4; Phase 5 plan, 5b step 5). Drawn by `ExploreHome` (5c-3).
///
/// - Rows are built only after the book-source library is read, so a cold launch never shows
///   a source as deleted.
/// - 「最新」 expands into one row per source that serves it; every other section is served by
///   the first provider that takes it. A section nothing serves (a removed connection, a
///   binding from a later build) has no row.
/// - 我的書庫 is not drawn (unified library 5d-1, settled decision 12): the libraries are
///   reached from 範圍. A saved page keeps its section, so an older build still shows it.
/// - A row loads when its view asks: book-source rows one at a time per source, bundled and
///   on-device rows at once. Gutenberg's load as soon as the home shows (`homeAppeared`),
///   wherever they sit on the page (Phase 5 plan, decision 15).
@MainActor
final class HomeModel: ObservableObject {
    enum RowState: Equatable {
        case idle
        case loading
        case loaded([CollectionEntry])
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        var section: HomeSection
        let source: SourceInstanceKey
        let sourceName: String
        let policy: SectionLoadPolicy
        var state: RowState
    }

    @Published private(set) var rows: [Row] = []
    /// False until the first `sync` has read the book-source library.
    @Published private(set) var isReady = false

    private let makeProviders: () -> [any HomeSectionProviding]
    private let waitForSources: () async -> Void
    private var providers: [String: any HomeSectionProviding] = [:]
    private var requested: Set<String> = []
    private var queueTails: [SourceInstanceKey: Task<Void, Never>] = [:]
    /// Rows queued or loading, so a 重試 or pull to refresh never starts a second load.
    private var active: Set<String> = []

    /// - Parameters:
    ///   - providers: the sources now, asked again at each `sync`
    ///     (`SourceProviderRegistry.homeProviders(shelf:)`).
    ///   - waitForSources: returns once the book-source library is read
    ///     (`BookSourceStore.waitUntilLoaded`).
    init(providers: @escaping () -> [any HomeSectionProviding], waitForSources: @escaping () async -> Void) {
        makeProviders = providers
        self.waitForSources = waitForSources
    }

    // MARK: - Building

    /// Builds the rows for `page` as it now stands.
    /// - A row whose source and content are unchanged keeps what it loaded, and takes the
    ///   section's new title and layout (呈現方式, 5d-3).
    /// - A row whose content changed under the same id starts again at once if it had been
    ///   asked for: its view is the same view, so nothing else would ask again.
    /// - `hiddenFromLatest`: the libraries 聚合設定's 顯示在最新 turns off (5d-3f). They get
    ///   no 最新 row, so they are not asked for one.
    func sync(with page: HomePage, hiddenFromLatest: Set<SourceInstanceKey> = []) async {
        await waitForSources()
        let available = makeProviders()
        let existing = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var built: [Row] = []
        var restarted: [String] = []
        var servedBy: [String: any HomeSectionProviding] = [:]
        for section in page.sections where section.isEnabled {
            if case .myLibrary = section.binding { continue }
            let serving: [any HomeSectionProviding]
            if case .latest = section.binding {
                serving = available.filter { $0.loadPolicy(for: section) != nil && !hiddenFromLatest.contains($0.instance) }
            } else {
                serving = available.first { $0.loadPolicy(for: section) != nil }.map { [$0] } ?? []
            }
            if serving.isEmpty, section.binding.isKnown, !isLatest(section) {
                AppLogger.cache("⟐ home section has no source to serve it", context: ["section": section.id.uuidString])
            }
            for provider in serving {
                guard let policy = provider.loadPolicy(for: section) else { continue }
                let id = Self.rowID(section: section.id, source: provider.instance)
                servedBy[id] = provider
                if var kept = existing[id], kept.section.loadsSameContent(as: section), kept.policy == policy {
                    kept.section = section
                    built.append(kept)
                } else {
                    if existing[id] != nil, requested.contains(id) { restarted.append(id) }
                    requested.remove(id)
                    built.append(Row(id: id, section: section, source: provider.instance, sourceName: provider.displayName,
                                     policy: policy, state: .idle))
                }
            }
        }
        providers = servedBy
        requested.formIntersection(servedBy.keys)
        rows = built
        isReady = true
        for id in restarted { load(id) }
    }

    private func isLatest(_ section: HomeSection) -> Bool {
        if case .latest = section.binding { return true }
        return false
    }

    static func rowID(section: UUID, source: SourceInstanceKey) -> String {
        "\(section.uuidString)|\(source.type.rawValue):\(source.id)"
    }

    func row(_ id: String) -> Row? {
        rows.first { $0.id == id }
    }

    // MARK: - Loading

    /// The row came into view.
    func load(_ rowID: String) {
        guard !requested.contains(rowID), let row = row(rowID) else { return }
        requested.insert(rowID)
        start(row)
    }

    /// The reader tapped 重試 on a failed row.
    func request(_ rowID: String) {
        guard let row = row(rowID) else { return }
        requested.insert(rowID)
        start(row)
    }

    /// Pull to refresh: rows already loaded load again.
    func reload() {
        for row in rows where requested.contains(row.id) && !active.contains(row.id) {
            start(row)
        }
    }

    /// The rows read from this device load again, when the home comes back into view: a book
    /// read meanwhile moves in 繼續閱讀. Not on every shelf change, which a page turn makes.
    func reloadLocal() {
        for row in rows where row.policy == .local && requested.contains(row.id) && !active.contains(row.id) {
            start(row)
        }
    }

    private func start(_ row: Row) {
        guard active.insert(row.id).inserted else { return }
        switch row.policy {
        case .serialPerSource:
            let previous = queueTails[row.source]
            queueTails[row.source] = Task { [weak self] in
                await previous?.value
                await self?.fetch(row.id)
            }
        case .local, .parallel, .withHome:
            Task { [weak self] in await self?.fetch(row.id) }
        }
    }

    private func fetch(_ rowID: String) async {
        defer { active.remove(rowID) }
        guard let row = row(rowID), let provider = providers[rowID] else { return }
        setState(.loading, of: rowID)
        let started = SourcePerfTrace.now
        do {
            let entries = try await provider.load(row.section)
            SourcePerfTrace.record("home.row", "source=\(row.source.type.rawValue) entries=\(entries.count)",
                                   since: started, thresholdMs: 0)
            // The row may have been removed or changed while this loaded.
            guard self.row(rowID)?.section.loadsSameContent(as: row.section) == true else { return }
            setState(.loaded(entries), of: rowID)
        } catch is CancellationError {
            setState(.idle, of: rowID)
        } catch {
            AppLogger.network("⟐ home row failed", error: error, context: [
                "source": "\(row.source.type.rawValue):\(row.source.id)", "section": row.section.id.uuidString,
            ])
            guard self.row(rowID)?.section.loadsSameContent(as: row.section) == true else { return }
            setState(.failed(error.localizedDescription), of: rowID)
        }
    }

    private func setState(_ state: RowState, of rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].state = state
    }
}
