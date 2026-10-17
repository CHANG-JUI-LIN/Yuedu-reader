import SwiftUI

// Unified library 5d-5: 選擇內容來源 (design §13.3; Phase 5 plan, decision 23), grouped as
// `HomeContentSource.swift` lists: App 資料, 書庫, 來源配置. A source pushes its items: a
// connection's feeds, Gutenberg's lists and feeds, 青空文庫's indexes, a book source's discover
// categories. 「目前」 marks the group and source in use; a check mark, the item.
//
// A sheet over the form, or pushed in the form's stack when the form is a sheet already on
// iOS 17 (`isPushed`), as the design says.

/// What 選擇內容來源 gives the form.
struct HomeContentChoice: Equatable {
    let binding: HomeSectionBinding
    var parameters: [String: String] = [:]
    /// The item's name, for a binding that cannot name itself (`HomeSectionEditor.choose`).
    var itemTitle: String = ""
    /// A book source's category: the discover filter values it was listed under
    /// (`HomeSection.filtersKey`), also in `parameters`.
    var filterValues: [String: String] = [:]
}

extension HomeContentChoice {
    /// A module's lists (Phase 6f), each titled after itself. Its search entry is no list.
    static func lists(of module: RuleModule) -> [HomeContentChoice] {
        module.modules.compactMap { entry in
            entry.id.map { HomeContentChoice(binding: .module(moduleID: module.id, entryID: $0), itemTitle: entry.title ?? $0) }
        }
    }
}

struct HomeContentSourcePicker: View {
    let current: HomeSectionBinding?
    /// The section's parameters: a book source's categories list under its filter values.
    let parameters: [String: String]
    let isPushed: Bool
    let choose: (HomeContentChoice) -> Void
    let cancel: () -> Void

    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var sources = BookSourceStore.shared
    @ObservedObject private var modules = RuleModuleLibrary.shared

    init(current: HomeSectionBinding?, parameters: [String: String] = [:], isPushed: Bool,
         choose: @escaping (HomeContentChoice) -> Void, cancel: @escaping () -> Void) {
        self.current = current
        self.parameters = parameters
        self.isPushed = isPushed
        self.choose = choose
        self.cancel = cancel
    }

    private var owner: HomeContentOwner? { current?.contentOwner }

    /// The connections with feeds of their own: OPDS and Calibre. WebDAV serves 最新 only.
    private var feedConnections: [RemoteLibraryConnection] {
        connections.catalogs.filter { $0.kind != .webDAV }
    }

    var body: some View {
        List {
            Section {
                ForEach(HomeSectionBinding.appData, id: \.self) { binding in
                    HomeChoiceRow(title: HomeSection(layout: .row, binding: binding).displayTitle(sourceName: ""),
                                  isCurrent: current == binding) {
                        choose(HomeContentChoice(binding: binding))
                    }
                }
            } header: {
                Text(localized("App 資料"))
            }
            .interfaceSectionSurface()

            if !feedConnections.isEmpty || availability.isAvailable {
                Section {
                    ForEach(feedConnections) { connection in
                        NavigationLink {
                            HomeFeedChoices(source: .connection(connection), current: current, choose: choose)
                        } label: {
                            ownerLabel(connection.name, systemImage: SourceKindSymbol.symbol(for: ProviderType(connection.kind)),
                                       isCurrent: owner == .connection(id: connection.id))
                        }
                    }
                    if availability.isAvailable {
                        NavigationLink {
                            HomeFeedChoices(source: .gutenberg, current: current, choose: choose)
                        } label: {
                            ownerLabel(localized("Project Gutenberg"), systemImage: SourceKindSymbol.symbol(for: .gutenberg),
                                       isCurrent: owner == .gutenberg)
                        }
                        NavigationLink {
                            HomeAozoraChoices(current: current, choose: choose)
                        } label: {
                            ownerLabel(localized("青空文庫"), systemImage: SourceKindSymbol.symbol(for: .aozora),
                                       isCurrent: owner == .aozora)
                        }
                    }
                } header: {
                    Text(localized("書庫"))
                }
                .interfaceSectionSurface()
            }

            Section {
                NavigationLink {
                    HomeSourceChoices(current: current, parameters: parameters, choose: choose)
                } label: {
                    ownerLabel(localized("來源配置"), systemImage: "square.grid.2x2.fill",
                               isCurrent: { if case .bookSource = owner { true } else { false } }())
                }
                .accessibilityIdentifier("homePicker.bookSources")
            }
            .interfaceSectionSurface()

            Section {
                ForEach(HomeSectionBinding.official, id: \.self) { binding in
                    HomeChoiceRow(title: HomeSection(layout: .row, binding: binding).displayTitle(sourceName: ""),
                                  isCurrent: current == binding) {
                        choose(HomeContentChoice(binding: binding))
                    }
                }
            } header: {
                Text(localized("官方模組"))
            }
            .interfaceSectionSurface()

            if !modules.modules.isEmpty {
                Section {
                    ForEach(modules.modules, id: \.module.id) { installed in
                        NavigationLink {
                            HomeModuleChoices(module: installed.module, current: current, choose: choose)
                        } label: {
                            ownerLabel(installed.module.title, systemImage: "puzzlepiece.extension",
                                       isCurrent: owner == .module(id: installed.module.id))
                        }
                        .accessibilityIdentifier("homePicker.module.\(installed.module.id)")
                    }
                } header: {
                    Text(localized("模組"))
                }
                .interfaceSectionSurface()
            }
        }
        .navigationTitle(localized("選擇內容來源"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .task { await modules.loadIfNeeded() }
        .toolbar {
            if !isPushed {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Label(localized("取消"), systemImage: "xmark")
                    }
                }
            }
        }
    }

    private func ownerLabel(_ name: String, systemImage: String?, isCurrent: Bool) -> some View {
        LabeledContent {
            if isCurrent { Text(localized("目前")) }
        } label: {
            Label {
                Text(name)
            } icon: {
                Image(systemName: systemImage ?? "books.vertical")
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Rows

/// An item: its name, checked when it is the one in use.
private struct HomeChoiceRow: View {
    let title: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("homePicker.item.\(title)")
    }
}

// MARK: - 書庫

/// A library that speaks OPDS: Gutenberg's bundled lists first (no request), then the feeds its
/// catalog lists, fetched when this opens.
private struct HomeFeedChoices: View {
    enum Source {
        case connection(RemoteLibraryConnection)
        case gutenberg
    }

    enum LoadState {
        case loading
        case loaded([CollectionLocation])
        case failed(String)
    }

    let source: Source
    let current: HomeSectionBinding?
    let choose: (HomeContentChoice) -> Void
    @State private var state = LoadState.loading
    @ObservedObject private var aggregation = AggregationSettingsStore.shared

    private var name: String {
        switch source {
        case .connection(let connection): connection.name
        case .gutenberg: localized("Project Gutenberg")
        }
    }

    private var provider: (any OPDSFeedProviding)? {
        switch source {
        case .connection(let connection): SourceProviderRegistry.shared.opdsProvider(catalogID: connection.id)
        case .gutenberg: SourceProviderRegistry.shared.gutenberg
        }
    }

    private func binding(for url: String) -> HomeSectionBinding {
        switch source {
        case .connection(let connection): .opdsFeed(connectionID: connection.id, url: url)
        case .gutenberg: .gutenbergFeed(url: url)
        }
    }

    var body: some View {
        List {
            if case .gutenberg = source {
                // Gutenberg's shelves, as its storefront lists them: 熱門, 最新, the reader's
                // languages. Kept by id, so they follow the endpoint (5d-6a).
                Section {
                    ForEach(GutenbergShelf.shelves(languages: aggregation.readingLanguages.languages)) { shelf in
                        let binding = HomeSectionBinding.gutenbergShelf(id: shelf.id)
                        HomeChoiceRow(title: shelf.title, isCurrent: current == binding) {
                            choose(HomeContentChoice(binding: binding))
                        }
                    }
                }
                .interfaceSectionSurface()
                Section {
                    ForEach(HomeSectionBinding.gutenbergCollections, id: \.self) { binding in
                        HomeChoiceRow(title: HomeSection(layout: .row, binding: binding).displayTitle(sourceName: ""),
                                      isCurrent: current == binding) {
                            choose(HomeContentChoice(binding: binding))
                        }
                    }
                }
                .interfaceSectionSurface()
            }
            Section {
                if case .connection = source, let root = provider?.rootURL?.absoluteString {
                    HomeChoiceRow(title: name, isCurrent: current == binding(for: root)) {
                        choose(HomeContentChoice(binding: binding(for: root), itemTitle: name))
                    }
                }
                switch state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .loaded(let feeds):
                    ForEach(feeds, id: \.id) { feed in
                        HomeChoiceRow(title: feed.title, isCurrent: current == binding(for: feed.id)) {
                            choose(HomeContentChoice(binding: binding(for: feed.id), itemTitle: feed.title))
                        }
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        Text(message)
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.textSecondary)
                        Button(localized("重試")) { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(name)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .task { await load() }
    }

    /// The catalog's navigation feeds. An item-only catalog has none: its root is the one feed.
    private func load() async {
        guard let provider else {
            state = .failed(localized("此目錄沒有內容"))
            return
        }
        state = .loading
        do {
            let page = try await provider.browse(nil, after: nil)
            state = .loaded(page.entries.compactMap { entry in
                if case .location(let location) = entry { return location }
                return nil
            })
        } catch is CancellationError {
            return
        } catch {
            AppLogger.network("⟐ home picker could not list a library's feeds", error: error,
                              context: ["source": provider.instance.id])
            state = .failed(error.localizedDescription)
        }
    }
}

/// 青空文庫: 新着 and its three indexes, read from the catalog.
private struct HomeAozoraChoices: View {
    let current: HomeSectionBinding?
    let choose: (HomeContentChoice) -> Void

    var body: some View {
        List {
            Section {
                ForEach(HomeSectionBinding.aozora, id: \.self) { binding in
                    HomeChoiceRow(title: HomeSection(layout: .row, binding: binding).displayTitle(sourceName: ""),
                                  isCurrent: current == binding) {
                        choose(HomeContentChoice(binding: binding))
                    }
                }
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("青空文庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

// MARK: - 模組

/// A module's lists (Phase 6f): the one in use is checked.
struct HomeModuleChoices: View {
    let module: RuleModule
    let current: HomeSectionBinding?
    let choose: (HomeContentChoice) -> Void

    var body: some View {
        List {
            Section {
                ForEach(HomeContentChoice.lists(of: module), id: \.binding) { choice in
                    HomeChoiceRow(title: choice.itemTitle, isCurrent: current == choice.binding) {
                        choose(choice)
                    }
                }
            } footer: {
                if let description = module.description, !description.isEmpty {
                    Text(description).dsSectionFooter()
                }
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(module.title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

// MARK: - 來源配置

/// Every book source 探索 lists, searchable: a reader can have thousands, so only the rows on
/// screen are built (`HostedCollectionList`, as 書源管理).
struct HomeSourceChoices: View {
    let current: HomeSectionBinding?
    /// The section's parameters, for the filter values each source's categories list under.
    var parameters: [String: String] = [:]
    let choose: (HomeContentChoice) -> Void
    @ObservedObject private var store = BookSourceStore.shared
    @State private var query = ""
    @State private var opened: String?

    private var currentSourceURL: String? {
        if case .bookSource(let url) = current?.contentOwner { return url }
        return nil
    }

    private var listed: [BookSource] {
        DiscoverViewModel.exploreSources(DiscoverViewModel.exploreSources(in: store), inGroup: nil,
                                         matching: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        let sources = listed
        HostedCollectionList(items: sources.map(\.bookSourceUrl), contentVersion: currentSourceURL.hashValue,
                             showsSeparator: { _ in true }, usesSystemMargins: { _ in true }) { url in
            let source = sources.first { $0.bookSourceUrl == url }
            Button { opened = url } label: {
                HStack {
                    Text(source?.bookSourceName ?? url)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    if url == currentSourceURL {
                        Text(localized("目前")).foregroundStyle(DSColor.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(DSFont.footnote.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, DSSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("homePicker.source.\(source?.bookSourceName ?? url)")
        }
        .overlay {
            if sources.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        UnavailableLabel(localized("沒有可用的來源配置，請先啟用來源配置"), systemImage: "puzzlepiece.extension")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: localized("搜尋來源配置名稱或網址"))
        .navigationTitle(localized("來源配置"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .navigationDestination(item: $opened) { url in
            if let source = store.sources.first(where: { $0.bookSourceUrl == url }) {
                HomeCategoryChoices(source: source,
                                    filterValues: HomeSection.filterValues(in: parameters, sourceURL: url),
                                    current: current, choose: choose)
                    // Pushed from a section's form, which hides the tab bar (`homeEditDestinations`).
                    .hidesRootTabBar()
            }
        }
    }
}

/// A book source's discover categories, under the group labels it draws, searchable, with the
/// source's filters above them. A filter changed here lists the categories again under it for
/// this section only (`SourceCategoryListing`); the source's discover page keeps its own.
struct HomeCategoryChoices: View {
    let current: HomeSectionBinding?
    let choose: (HomeContentChoice) -> Void
    @StateObject private var listing: SourceCategoryListing
    @State private var query = ""

    /// - Parameter filterValues: the section's, from when it picked its category here.
    init(source: BookSource, filterValues: [String: String] = [:], current: HomeSectionBinding?,
         choose: @escaping (HomeContentChoice) -> Void) {
        self.current = current
        self.choose = choose
        _listing = StateObject(wrappedValue: SourceCategoryListing(source: source, filterValues: filterValues))
    }

    private var currentReference: ExploreCategoryReference? {
        if case .sourceCategories(let references) = current { return references.first }
        return nil
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [DiscoverCategoryGroup] {
        DiscoverCategoryGroup.filtered(listing.groups, matching: trimmedQuery)
    }

    var body: some View {
        List {
            if !listing.filters.isEmpty {
                Section {
                    ForEach(listing.filters, id: \.paramKey) { filter in
                        Picker(filter.title, selection: Binding(
                            get: { filter.selected },
                            set: { value in Task { await listing.select(filter, value: value) } })) {
                            ForEach(Array(filter.options.enumerated()), id: \.offset) { _, option in
                                Text(option).tag(option)
                            }
                        }
                        .accessibilityIdentifier("homePicker.filter.\(filter.paramKey)")
                    }
                } header: {
                    Text(localized("篩選"))
                } footer: {
                    // Under the filters, not over them: the reader changes one back from here.
                    if listing.state == .empty {
                        Text(localized("暫無發現內容")).dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items, id: \.stableKey) { item in
                        if let reference = listing.reference(for: item) {
                            HomeChoiceRow(title: item.title, isCurrent: reference == currentReference) {
                                let values = listing.filterValues
                                choose(HomeContentChoice(
                                    binding: .sourceCategories([reference]),
                                    parameters: HomeSection.filterParameters(values, sourceURL: reference.sourceURL),
                                    filterValues: values))
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
                .interfaceSectionSurface()
            }
        }
        .overlay {
            switch listing.state {
            case .loading:
                ProgressView()
            case .empty:
                if listing.filters.isEmpty {
                    ContentUnavailableView {
                        UnavailableLabel(localized("暫無發現內容"), systemImage: "sparkles")
                    }
                }
            case .loaded:
                if !trimmedQuery.isEmpty, groups.isEmpty { ContentUnavailableView.search(text: trimmedQuery) }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: localized("搜尋發現項目"))
        .navigationTitle(listing.source.bookSourceName)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .task { await listing.load() }
    }
}

#Preview("模組的清單") {
    NavigationStack {
        HomeModuleChoices(module: RuleModulePreviewData.module(), current: .module(moduleID: "preview.module", entryID: "new"),
                          choose: { _ in })
    }
}

#Preview("選擇內容來源") {
    NavigationStack {
        HomeContentSourcePicker(current: .continueReading, isPushed: false, choose: { _ in }, cancel: {})
    }
}
