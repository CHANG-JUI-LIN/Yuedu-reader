import Combine
import Foundation

/// Everything 書源管理 derives from the library — row order, groups, the header counts,
/// the current page and its selection — computed once per change instead of once per
/// SwiftUI body evaluation.
///
/// With 50,000 sources the screen used to redo all of this in `body`: four header scans
/// (one trimming every `exploreUrl`), a second full copy of every `BookSource` for the
/// grouped layout, and an id map for `onChange` — on every checkbox tap, keystroke and
/// validation publication. Here each input has its own entry point, and only the input
/// that changed pays its O(n) pass.
@MainActor
final class BookSourceManagementModel: ObservableObject {
    enum Item: Hashable {
        /// The stats card and page buttons at the top of the list.
        case header
        case group(String)
        case source(UUID)
    }

    struct Counts: Equatable {
        var total = 0
        var enabled = 0
        var discover = 0
        var fetchError = 0
        var contentError = 0
    }

    let store: BookSourceStore
    let healthChecker: BookSourceHealthChecker
    let expansion: BookSourceGroupExpansionStore
    private let settings: GlobalSettings

    /// Rows in display order.
    @Published private(set) var items: [Item] = [.header]
    /// Whether the latest `items` change is a group expanding or collapsing.
    private(set) var animatesItemChange = false
    /// Bumped whenever something a visible row shows changed without the row order
    /// changing: a toggle, a selection, a validation badge, a header count.
    @Published private(set) var contentVersion = 0
    @Published private(set) var counts = Counts()
    /// A row to bring into view once the rebuild that moved it has landed.
    @Published private(set) var scrollRequest: HostedCollectionListScrollRequest<Item>?

    /// Always a subset of the current page's filter: switching pages clears it, and a
    /// validation result that moves a source off the page drops it. Searching does not.
    @Published private(set) var selectedIDs: Set<UUID> = []
    /// The current page: the validation filter plus the search text.
    @Published private(set) var pageCount = 0
    @Published private(set) var pageSelectedCount = 0

    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            rebuildPage()
        }
    }

    /// 全部／抓取異常／正文異常. A different page starts with nothing selected, so a
    /// selection made on one page can never be deleted from another.
    @Published var filter: ValidationListFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            selectedIDs = []
            rebuildFilterPage()
        }
    }

    // MARK: Library snapshot

    private var sources: [BookSource] = []
    /// `sources[i].id`, read once per library change. Rows, pages and selection index this
    /// instead of `sources`, which would copy a whole source (dozens of rule strings) to
    /// read one field.
    private var ids: [UUID] = []
    private var indexByID: [UUID: Int] = [:]
    /// `bookSourceGroup` trimmed once per library change, not once per render.
    private var groupKeys: [String] = []
    private var pins: [UUID: SourcePinPosition] = [:]
    /// Lowercased name + URL + group, built on the first search after a library change.
    private var searchKeys: [String]?
    /// Library indices on the current filter, then narrowed by the search text.
    private var filterPage: [Int] = []
    private var page: [Int] = []
    /// Membership test for `page` while a search narrows it.
    private var searchPageIndices: Set<Int>?
    private var groups: [String: BookSourceRowGroup] = [:]

    private var storeRebuildPending = false
    private var animatesNextLibraryRebuild = false
    private var pendingRevealID: UUID?
    private var scrollSerial = 0
    private var cancellables: Set<AnyCancellable> = []

    /// Legado keeps sources with an empty `bookSourceGroup` in a built-in default group.
    let defaultGroupName = localized("默認分組")

    init(
        store: BookSourceStore = .shared,
        healthChecker: BookSourceHealthChecker? = nil,
        expansion: BookSourceGroupExpansionStore? = nil,
        settings: GlobalSettings = .shared
    ) {
        self.store = store
        self.healthChecker = healthChecker ?? .shared
        self.expansion = expansion ?? BookSourceGroupExpansionStore()
        self.settings = settings
        rebuildLibrary()

        // `objectWillChange` fires before the store's mutation lands, and one edit can fire
        // it several times (置頂 moves the source, then records the pin). Rebuilding once,
        // after the current event has finished mutating, reads the settled library. The
        // main queue is drained before the run loop's next render pass, so the list never
        // draws the half-applied state.
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleLibraryRebuild() }
            .store(in: &cancellables)
        // Sent after each coalesced publication, with the new verdicts already in place.
        self.healthChecker.didPublish
            .sink { [weak self] in self?.healthDidChange() }
            .store(in: &cancellables)
        observeGrouping(current: settings.bookSourceListGrouped)
    }

    /// Rebuilds the rows when 分組 is switched. `withObservationTracking` reports the change
    /// before it lands and only once: the handler reads the new value after hopping to the
    /// main actor, skips an unchanged one, and re-arms.
    private func observeGrouping(current: Bool) {
        withObservationTracking {
            _ = settings.bookSourceListGrouped
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let grouped = self.settings.bookSourceListGrouped
                if grouped != current { self.rebuildRows(grouped: grouped) }
                self.observeGrouping(current: grouped)
            }
        }
    }

    // MARK: Reads for rows and actions

    func source(for id: UUID) -> BookSource? {
        indexByID[id].map { sources[$0] }
    }

    func pin(for id: UUID) -> SourcePinPosition? {
        pins[id]
    }

    func group(_ id: String) -> BookSourceRowGroup? {
        groups[id]
    }

    func isSelected(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }

    var isPageFullySelected: Bool {
        pageCount > 0 && pageSelectedCount == pageCount
    }

    /// The sources a group's export / copy acts on, resolved when the action runs.
    func sources(for ids: [UUID]) -> [BookSource] {
        ids.compactMap(source(for:))
    }

    // MARK: Selection

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        selectionDidChange()
    }

    /// 全選 for the current page: selects exactly what the page shows, or clears it when
    /// that is already the whole selection.
    func toggleSelectAll() {
        let pageIDs = Set(page.map { ids[$0] })
        selectedIDs = selectedIDs == pageIDs ? [] : pageIDs
        selectionDidChange()
    }

    /// 反選 within the current page.
    func invertSelection() {
        let pageIDs = Set(page.map { ids[$0] })
        selectedIDs = pageIDs.subtracting(selectedIDs)
        selectionDidChange()
    }

    /// 選擇該分組 — the group's members come from the current page.
    func select(_ ids: Set<UUID>) {
        selectedIDs.formUnion(ids)
        selectionDidChange()
    }

    func deselect(_ ids: Set<UUID>) {
        guard !selectedIDs.isDisjoint(with: ids) else { return }
        selectedIDs.subtract(ids)
        selectionDidChange()
    }

    func clearSelection() {
        guard !selectedIDs.isEmpty else { return }
        selectedIDs = []
        selectionDidChange()
    }

    // MARK: Groups and scrolling

    func isExpanded(_ groupID: String) -> Bool {
        expansion.isExpanded(groupID)
    }

    func toggleExpansion(_ groupID: String) {
        expansion.toggle(groupID)
        rebuildRows(animated: true)
    }

    /// Scrolls to the source once the library change that moved it has been rebuilt —
    /// 置頂／置底 send a source to the other end of a long list.
    func revealAfterNextRebuild(_ id: UUID) {
        pendingRevealID = id
    }

    /// Animates the row moves of the next library change — pinning, regrouping, deleting
    /// a group — the way `withAnimation` did around the store call when this was a `List`.
    func animateNextLibraryChange() {
        animatesNextLibraryRebuild = true
    }

    // MARK: Rebuilds

    private func scheduleLibraryRebuild() {
        guard !storeRebuildPending else { return }
        storeRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.storeRebuildPending = false
            self.rebuildLibrary()
        }
    }

    private func rebuildLibrary() {
        let animated = animatesNextLibraryRebuild
        animatesNextLibraryRebuild = false
        SourcePerfTrace.span("sourceList.rebuildLibrary", "\(store.sources.count) sources", thresholdMs: 4) {
            sources = store.sources
            pins = store.pinRecords.mapValues(\.position)
            var ids: [UUID] = []
            ids.reserveCapacity(sources.count)
            var indexByID: [UUID: Int] = .init(minimumCapacity: sources.count)
            var groupKeys: [String] = []
            groupKeys.reserveCapacity(sources.count)
            var enabled = 0
            var discover = 0
            // Fields are read through the buffer, not by iterating `sources`: a `for source
            // in` loop copies every source — dozens of rule strings retained and released —
            // to read four fields, and this runs on every library edit.
            sources.withUnsafeBufferPointer { buffer in
                for index in buffer.indices {
                    let id = buffer[index].id
                    ids.append(id)
                    indexByID[id] = index
                    groupKeys.append(Self.trimmedGroup(buffer[index].bookSourceGroup))
                    if buffer[index].enabled { enabled += 1 }
                    // Presence of any non-blank character, not a trim: `exploreUrl` is often
                    // kilobytes of JS, and trimming it copied every one on every render.
                    if buffer[index].enabledExplore,
                       buffer[index].exploreUrl.contains(where: { !$0.isWhitespace }) {
                        discover += 1
                    }
                }
            }
            self.ids = ids
            self.indexByID = indexByID
            self.groupKeys = groupKeys
            searchKeys = nil
            var counts = healthCounts()
            counts.total = sources.count
            counts.enabled = enabled
            counts.discover = discover
            if counts != self.counts { self.counts = counts }
            rebuildFilterPage(animated: animated)
        }
        if let id = pendingRevealID {
            pendingRevealID = nil
            scrollSerial += 1
            scrollRequest = HostedCollectionListScrollRequest(item: .source(id), serial: scrollSerial)
        }
        contentVersion += 1
    }

    private func healthDidChange() {
        var counts = self.counts
        let health = healthCounts()
        counts.fetchError = health.fetchError
        counts.contentError = health.contentError
        if counts != self.counts { self.counts = counts }
        // On a failure page a verdict can move sources on or off it.
        if filter != .all { rebuildFilterPage() }
        contentVersion += 1
    }

    private func healthCounts() -> Counts {
        var counts = Counts()
        for (id, summary) in healthChecker.healthById where indexByID[id] != nil {
            switch summary.health {
            case .fetchError: counts.fetchError += 1
            case .contentError: counts.contentError += 1
            case .passed: break
            }
        }
        return counts
    }

    /// `bookSourceGroup` without surrounding whitespace. Almost no group name has any, so
    /// only those that do pay for a Foundation trim.
    private static func trimmedGroup(_ group: String) -> String {
        guard let first = group.first, let last = group.last,
              first.isWhitespace || last.isWhitespace else { return group }
        return group.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildFilterPage(animated: Bool = false) {
        switch filter {
        case .all:
            filterPage = Array(sources.indices)
        case .fetchError, .contentError:
            let wanted: SourceHealth = filter == .fetchError ? .fetchError : .contentError
            let health = healthChecker.healthById
            filterPage = ids.indices.filter { health[ids[$0]]?.health == wanted }
        }
        // Keep the selection on the page: sources deleted from the library, or moved off
        // a failure page by a new verdict, leave it.
        if !selectedIDs.isEmpty {
            let onPage = filter == .all
                ? nil
                : Set(filterPage.lazy.map { self.ids[$0] })
            let kept = selectedIDs.filter { id in
                guard indexByID[id] != nil else { return false }
                return onPage?.contains(id) ?? true
            }
            if kept.count != selectedIDs.count { selectedIDs = kept }
        }
        rebuildPage(animated: animated)
    }

    private func rebuildPage(animated: Bool = false) {
        let query = searchText.lowercased()
        if query.isEmpty {
            page = filterPage
            searchPageIndices = nil
        } else {
            SourcePerfTrace.span("sourceList.search", "\(filterPage.count) candidates", thresholdMs: 4) {
                if searchKeys == nil {
                    searchKeys = sources.map {
                        ($0.bookSourceName + "\n" + $0.bookSourceUrl + "\n" + $0.bookSourceGroup)
                            .lowercased()
                    }
                }
                let keys = searchKeys ?? []
                page = filterPage.filter { keys[$0].contains(query) }
                searchPageIndices = Set(page)
            }
        }
        if page.count != pageCount { pageCount = page.count }
        recountPageSelection()
        rebuildRows(grouped: settings.bookSourceListGrouped, animated: animated)
    }

    private func rebuildRows(grouped: Bool? = nil, animated: Bool = false) {
        let grouped = grouped ?? settings.bookSourceListGrouped
        var newItems: [Item] = [.header]
        var newGroups: [String: BookSourceRowGroup] = [:]
        if searchText.isEmpty && grouped {
            newItems.reserveCapacity(page.count + 64)
            var topPinned: [UUID] = []
            var bottomPinned: [UUID] = []
            var names: [String] = []
            var members: [String: [UUID]] = [:]
            for index in page {
                let id = ids[index]
                switch pins[id] {
                case .top: topPinned.append(id)
                case .bottom: bottomPinned.append(id)
                case nil:
                    let key = groupKeys[index]
                    if members[key] == nil { names.append(key) }
                    members[key, default: []].append(id)
                }
            }
            func append(_ group: BookSourceRowGroup) {
                newGroups[group.id] = group
                newItems.append(.group(group.id))
                if expansion.isExpanded(group.id) {
                    newItems.append(contentsOf: group.sourceIDs.lazy.map(Item.source))
                }
            }
            if !topPinned.isEmpty {
                append(BookSourceRowGroup(
                    id: BookSourceRowGroup.topPinnedID, name: localized("置頂組"), sourceIDs: topPinned))
            }
            for name in names {
                append(BookSourceRowGroup(
                    id: name.isEmpty ? BookSourceRowGroup.defaultGroupID : name,
                    name: name.isEmpty ? defaultGroupName : name,
                    sourceIDs: members[name] ?? []))
            }
            if !bottomPinned.isEmpty {
                append(BookSourceRowGroup(
                    id: BookSourceRowGroup.bottomPinnedID, name: localized("置底組"),
                    sourceIDs: bottomPinned))
            }
        } else {
            newItems.reserveCapacity(page.count + 1)
            newItems.append(contentsOf: page.lazy.map { Item.source(self.ids[$0]) })
        }
        groups = newGroups
        animatesItemChange = animated
        if newItems != items { items = newItems }
        contentVersion += 1
    }

    private func selectionDidChange() {
        recountPageSelection()
        contentVersion += 1
    }

    private func recountPageSelection() {
        let count: Int
        if let searchPageIndices {
            count = selectedIDs.reduce(0) { total, id in
                guard let index = indexByID[id] else { return total }
                return searchPageIndices.contains(index) ? total + 1 : total
            }
        } else {
            // Without a search the page is the whole filter page, which already
            // contains every selected source.
            count = selectedIDs.count
        }
        if count != pageSelectedCount { pageSelectedCount = count }
    }
}
