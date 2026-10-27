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
        /// `HomeSectionProviding.inputsKey`: what the row read besides its section.
        var inputsKey: String? = nil
        /// A card of a section of lists (`HomeSection.listCards`) and its place among them; nil
        /// for a section of books, whose row is the section's.
        var card: HomeListCard? = nil
        var cardIndex: Int? = nil
        /// The source's own name (`SourceProvider.displayName`): a card's source, over it in 大圖卡片.
        var providerName = ""

        /// What the row loads: its card's list, or its section.
        var loadingSection: HomeSection {
            card.map(section.cardSection) ?? section
        }
    }

    @Published private(set) var rows: [Row] = []
    /// False until the first `sync` has read the book-source library.
    @Published private(set) var isReady = false

    private let makeProviders: () -> [any HomeSectionProviding]
    private let waitForSources: () async -> Void
    private let firstPages: DiscoverFirstPages?
    private var providers: [String: any HomeSectionProviding] = [:]
    private var requested: Set<String> = []
    private var queueTails: [SourceInstanceKey: Task<Void, Never>] = [:]
    /// Rows queued or loading, so a 重試 or pull to refresh never starts a second load.
    private var active: Set<String> = []
    /// Rows a sync changed while they loaded: they start again once that load ends, which
    /// shows nothing (`isCurrent`).
    private var rerun: Set<String> = []

    /// - Parameters:
    ///   - providers: the sources now, asked again at each `sync`
    ///     (`SourceProviderRegistry.homeProviders(shelf:firstPages:)`).
    ///   - waitForSources: returns once the book-source library is read
    ///     (`BookSourceStore.waitUntilLoaded`).
    ///   - firstPages: the home's first-page fetcher; a pull to refresh asks every category again.
    init(providers: @escaping () -> [any HomeSectionProviding], waitForSources: @escaping () async -> Void,
         firstPages: DiscoverFirstPages? = nil) {
        makeProviders = providers
        self.waitForSources = waitForSources
        self.firstPages = firstPages
    }

    /// A home served by the sources now, with one first-page fetcher of its own for as long as
    /// it lives (Discovery Phase 7a-1).
    static func live(shelf: BookStore) -> HomeModel {
        let firstPages = DiscoverFirstPages()
        return HomeModel(providers: {
            SourceProviderRegistry.shared.homeProviders(shelf: shelf, firstPages: firstPages)
        }, waitForSources: {
            await BookSourceStore.shared.waitUntilLoaded()
            await RuleModuleLibrary.shared.loadIfNeeded()
        }, firstPages: firstPages)
    }

    // MARK: - Building

    /// Builds the rows for `page` as it now stands.
    /// - A row whose source and content are unchanged keeps what it loaded, and takes the
    ///   section's new title and layout (呈現方式, 5d-3).
    /// - A row whose content changed under the same id starts again at once if it had been
    ///   asked for: its view is the same view, so nothing else would ask again. A module list's
    ///   content includes its version and the language it follows (`inputsKey`).
    /// - `hiddenFromLatest`: the libraries 聚合設定's 顯示在最新 turns off (5d-3f). They get
    ///   no 最新 row, so they are not asked for one.
    /// - A section of lists has a row per card (`HomeSection.listCards`), each served as a section
    ///   of its list would be: a card of 最新 a row per library.
    func sync(with page: HomePage, hiddenFromLatest: Set<SourceInstanceKey> = []) async {
        await waitForSources()
        let available = makeProviders()
        let existing = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var built: [Row] = []
        var restarted: [String] = []
        var servedBy: [String: any HomeSectionProviding] = [:]
        var planned: [(section: HomeSection, load: HomeSection, card: (index: Int, card: HomeListCard)?,
                       providers: [any HomeSectionProviding])] = []
        for section in page.sections where section.isEnabled {
            if case .myLibrary = section.binding { continue }
            let loads: [(load: HomeSection, card: (index: Int, card: HomeListCard)?)] = section.drawsLists
                ? section.listCards.enumerated().map { (section.cardSection($0.element), ($0.offset, $0.element)) }
                : [(section, nil)]
            for (load, card) in loads {
                let serving: [any HomeSectionProviding]
                if case .latest = load.binding {
                    serving = available.filter { $0.loadPolicy(for: load) != nil && !hiddenFromLatest.contains($0.instance) }
                } else {
                    serving = available.first { $0.loadPolicy(for: load) != nil }.map { [$0] } ?? []
                }
                if serving.isEmpty, load.binding.isKnown, !isLatest(load) {
                    AppLogger.cache("⟐ home section has no source to serve it",
                                    context: ["section": section.id.uuidString, "card": card.map { String($0.index) } ?? ""])
                }
                planned.append((section, load, card, serving))
            }
        }
        for (section, load, card, serving) in planned {
            for provider in serving {
                guard let policy = provider.loadPolicy(for: load) else { continue }
                let id = Self.rowID(section: section.id, card: card?.index, source: provider.instance)
                servedBy[id] = provider
                let inputsKey = provider.inputsKey(for: load)
                if var kept = existing[id], kept.loadingSection.loadsSameContent(as: load), kept.policy == policy,
                   kept.inputsKey == inputsKey {
                    kept.section = section
                    kept.card = card?.card
                    built.append(kept)
                } else {
                    if existing[id] != nil, requested.contains(id) { restarted.append(id) }
                    requested.remove(id)
                    built.append(Row(id: id, section: section, source: provider.instance, sourceName: provider.rowName(for: load),
                                     policy: policy, state: .idle, inputsKey: inputsKey, card: card?.card,
                                     cardIndex: card?.index, providerName: provider.displayName))
                }
            }
        }
        providers = servedBy
        requested.formIntersection(servedBy.keys)
        rows = built
        isReady = true
        for id in restarted {
            if active.contains(id) {
                requested.insert(id)
                rerun.insert(id)
            } else {
                load(id)
            }
        }
    }

    private func isLatest(_ section: HomeSection) -> Bool {
        if case .latest = section.binding { return true }
        return false
    }

    /// A card's row is told from its section's other cards by its place: two cards of one source
    /// (趨勢's 今日 and 本月) are two rows.
    static func rowID(section: UUID, card: Int? = nil, source: SourceInstanceKey) -> String {
        let place = card.map { "card\($0)|" } ?? ""
        return "\(section.uuidString)|\(place)\(source.type.rawValue):\(source.id)"
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
        firstPages?.refresh()
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
        defer {
            active.remove(rowID)
            if rerun.remove(rowID) != nil, let current = row(rowID) { start(current) }
        }
        guard let row = row(rowID), let provider = providers[rowID] else { return }
        setState(.loading, of: rowID)
        let started = SourcePerfTrace.now
        do {
            let entries = try await provider.load(row.loadingSection)
            SourcePerfTrace.record("home.row", "source=\(row.source.type.rawValue) entries=\(entries.count)",
                                   since: started, thresholdMs: 0)
            // The row may have been removed or changed while this loaded.
            guard isCurrent(row) else { return }
            if entries.isEmpty, let index = row.cardIndex {
                // A card with nothing in it is left out of its section (`HomeSectionGroup.state`).
                AppLogger.network("⟐ home card's list has no book", context: [
                    "source": "\(row.source.type.rawValue):\(row.source.id)", "section": row.section.id.uuidString,
                    "card": String(index),
                ])
            }
            setState(.loaded(entries), of: rowID)
        } catch is CancellationError {
            setState(.idle, of: rowID)
        } catch {
            AppLogger.network("⟐ home row failed", error: error, context: [
                "source": "\(row.source.type.rawValue):\(row.source.id)", "section": row.section.id.uuidString,
            ])
            guard isCurrent(row) else { return }
            setState(.failed(error.localizedDescription), of: rowID)
        }
    }

    /// Whether `row`, as a load began, is still the row: same content, same inputs.
    private func isCurrent(_ row: Row) -> Bool {
        guard let current = self.row(row.id) else { return false }
        return current.loadingSection.loadsSameContent(as: row.loadingSection) && current.inputsKey == row.inputsKey
    }

    private func setState(_ state: RowState, of rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].state = state
    }
}
