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
/// - A row loads when its view asks: book-source rows one at a time per source, Gutenberg's
///   only when the reader asks, bundled and on-device rows at once.
@MainActor
final class HomeModel: ObservableObject {
    enum RowState: Equatable {
        case idle
        /// Shown with 載入; nothing is sent until the reader taps it.
        case awaitingRequest
        case loading
        case loaded([CollectionEntry])
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let section: HomeSection
        let source: SourceInstanceKey
        let sourceName: String
        let policy: SectionLoadPolicy
        var state: RowState
    }

    /// A place in 我的書庫. The browser and the custom pages lead, as on 探索 before the home:
    /// a reader with thousands of book sources would otherwise find them below every source.
    enum Tile: Hashable {
        case browser
        case customPage(id: UUID, name: String)
        /// A library connection, a public library or a book source. Never the shelf itself:
        /// nothing in Explore shows the shelf's own page.
        case source(SourceInstanceKey, name: String)

        var name: String {
            switch self {
            case .browser: localized("瀏覽器")
            case .customPage(_, let name), .source(_, let name): name
            }
        }
    }

    enum Item: Identifiable, Equatable {
        /// 我的書庫: the browser, the custom pages, then a tile for every source.
        case tiles(sectionID: UUID, [Tile])
        case row(Row)

        var id: String {
            switch self {
            case .tiles(let sectionID, _): "tiles|\(sectionID.uuidString)"
            case .row(let row): row.id
            }
        }
    }

    @Published private(set) var items: [Item] = []
    /// False until the first `sync` has read the book-source library.
    @Published private(set) var isReady = false

    private let makeProviders: () -> [any HomeSectionProviding]
    private let customPages: () -> [CustomExplorePage]
    private let waitForSources: () async -> Void
    private var providers: [String: any HomeSectionProviding] = [:]
    private var requested: Set<String> = []
    private var queueTails: [SourceInstanceKey: Task<Void, Never>] = [:]
    /// Rows queued or loading, so a 重試, 載入 or pull to refresh never starts a second load.
    private var active: Set<String> = []

    /// - Parameters:
    ///   - providers: the sources now, asked again at each `sync`
    ///     (`SourceProviderRegistry.homeProviders(shelf:)`).
    ///   - customPages: the reader's custom pages now, for 我的書庫.
    ///   - waitForSources: returns once the book-source library is read
    ///     (`BookSourceStore.waitUntilLoaded`).
    init(providers: @escaping () -> [any HomeSectionProviding], customPages: @escaping () -> [CustomExplorePage] = { [] },
         waitForSources: @escaping () async -> Void) {
        makeProviders = providers
        self.customPages = customPages
        self.waitForSources = waitForSources
    }

    // MARK: - Building

    /// Builds the rows for `page` as it now stands. A row whose section and source are
    /// unchanged keeps what it loaded.
    func sync(with page: HomePage) async {
        await waitForSources()
        let available = makeProviders()
        let existing = Dictionary(items.compactMap { item -> (String, Row)? in
            if case .row(let row) = item { return (row.id, row) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        var built: [Item] = []
        var servedBy: [String: any HomeSectionProviding] = [:]
        for section in page.sections where section.isEnabled {
            if case .myLibrary = section.binding {
                let pages = customPages().map { Tile.customPage(id: $0.id, name: $0.name) }
                let sources = available.filter { $0.instance.type != .library }.map { Tile.source($0.instance, name: $0.displayName) }
                built.append(.tiles(sectionID: section.id, [.browser] + pages + sources))
                continue
            }
            let serving: [any HomeSectionProviding]
            if case .latest = section.binding {
                serving = available.filter { $0.loadPolicy(for: section) != nil }
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
                if let kept = existing[id], kept.section == section, kept.policy == policy {
                    built.append(.row(kept))
                } else {
                    requested.remove(id)
                    built.append(.row(Row(id: id, section: section, source: provider.instance, sourceName: provider.displayName,
                                          policy: policy, state: .idle)))
                }
            }
        }
        providers = servedBy
        requested.formIntersection(servedBy.keys)
        items = built
        isReady = true
    }

    private func isLatest(_ section: HomeSection) -> Bool {
        if case .latest = section.binding { return true }
        return false
    }

    static func rowID(section: UUID, source: SourceInstanceKey) -> String {
        "\(section.uuidString)|\(source.type.rawValue):\(source.id)"
    }

    func row(_ id: String) -> Row? {
        for item in items { if case .row(let row) = item, row.id == id { return row } }
        return nil
    }

    // MARK: - Loading

    /// The row came into view. An on-demand row only offers 載入.
    func load(_ rowID: String) {
        guard !requested.contains(rowID), let row = row(rowID) else { return }
        requested.insert(rowID)
        if row.policy == .onDemandOnly {
            setState(.awaitingRequest, of: rowID)
        } else {
            start(row)
        }
    }

    /// The reader tapped 載入, or 重試 on a failed row.
    func request(_ rowID: String) {
        guard let row = row(rowID) else { return }
        requested.insert(rowID)
        start(row)
    }

    /// Pull to refresh: rows already loaded load again. An on-demand row goes back to 載入.
    func reload() {
        for item in items {
            guard case .row(let row) = item, requested.contains(row.id), !active.contains(row.id) else { continue }
            if row.policy == .onDemandOnly {
                setState(.awaitingRequest, of: row.id)
            } else {
                start(row)
            }
        }
    }

    /// The rows read from this device load again, when the home comes back into view: a book
    /// read meanwhile moves in 繼續閱讀. Not on every shelf change, which a page turn makes.
    func reloadLocal() {
        for item in items {
            guard case .row(let row) = item, row.policy == .local, requested.contains(row.id),
                  !active.contains(row.id) else { continue }
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
        case .local, .parallel, .onDemandOnly:
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
            guard self.row(rowID)?.section == row.section else { return }
            setState(.loaded(entries), of: rowID)
        } catch is CancellationError {
            setState(.idle, of: rowID)
        } catch {
            AppLogger.network("⟐ home row failed", error: error, context: [
                "source": "\(row.source.type.rawValue):\(row.source.id)", "section": row.section.id.uuidString,
            ])
            guard self.row(rowID)?.section == row.section else { return }
            setState(.failed(error.localizedDescription), of: rowID)
        }
    }

    private func setState(_ state: RowState, of rowID: String) {
        guard let index = items.firstIndex(where: { $0.id == rowID }), case .row(var row) = items[index] else { return }
        row.state = state
        items[index] = .row(row)
    }
}
