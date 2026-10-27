import SwiftUI

/// 資源庫, a tab since Phase 5's 5h (decisions 30 and 31): where every source lives, grouped by
/// kind. 古騰堡 and 青空文庫 open what they offer, a remote library its catalog, and the
/// source configurations and the RSS feeds are managed here. Adding a 來源配置, a module or a
/// remote library is 設定's (maintainer, 2026-10-27: 「把添加資源的入口都放在設置頁」): this page
/// lists what is there. 探索 stays the cover wall across them all.
///
/// Laid out by the old 探索 root's 格狀 and 每列欄數, now in this page's •••, as cards the way
/// the maintainer's reference draws its media servers and modules (2026-10-13). The search
/// narrows the sources in place, as the old root and Legado's explore page do.
///
/// One stack, with 探索's destinations: every page here is one 探索 already pushes.
struct LibraryTabRoot: View {
    @ObservedObject var browser: BrowserState
    @EnvironmentObject private var store: BookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @ObservedObject private var rss = RSSStore.shared
    @ObservedObject private var modules = RuleModuleLibrary.shared
    @AppStorage(ExploreSettings.showsGridKey) private var showsGrid = true
    @AppStorage(ExploreSettings.gridColumnCountKey) private var gridColumnCount = ExploreGridDensity.default.rawValue
    /// The first-launch card saying what moved here (maintainer's choice, 2026-10-13).
    @AppStorage(Self.noticeDismissedKey) private var noticeDismissed = false

    @State private var path = NavigationPath()
    @State private var browserEntry: BrowserEntryPresentation?
    @State private var query = ""
    /// The sources with a discover page, and their groups: worked out when the sources change,
    /// not on every redraw, since a reader may have tens of thousands.
    @State private var exploreSources: [BookSource] = []
    @State private var sourceGroups: [LibrarySourceGroups.Group] = []
    @State private var sourceActionSheet: BookSourceActionSheet?
    @State private var sourcePendingDeletion: BookSource?
    @State private var showsMoreChooser = false
    @State private var moreSequence = DismissalSequencedPresentation<LibraryMoreAction>()
    /// 新手導覽's 連接書庫: 遠端書庫's page over the root.
    @Environment(OnboardingState.self) private var onboarding: OnboardingState?
    @State private var showsRemoteLibrarySettings = false

    static let noticeDismissedKey = "library.tabNoticeDismissed"

    private enum LibraryMoreAction: Hashable {
        case manageSources
        case showsGrid(Bool)
        case columns(Int)
    }

    private struct BrowserEntryPresentation: Identifiable {
        let id = UUID()
        let entry: BrowserEntry
    }

    private var libraries: [LibraryListing] {
        LibraryListing.available(connections: connections.connections, librariesAvailable: availability.isAvailable)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sources whose name or group holds the search, as Legado's explore search narrows them.
    private var matchingSources: [BookSource] {
        DiscoverViewModel.exploreSources(exploreSources, inGroup: nil, matching: trimmedQuery)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    if trimmedQuery.isEmpty {
                        if !noticeDismissed {
                            notice
                        }
                        RuleModuleSection(library: modules) { key, layout in
                            publicLibraryTile(key, layout: layout)
                        }
                        remoteLibrariesSection
                        sourcesSection
                        subscriptionsSection
                    } else if !matchingSources.isEmpty {
                        LibrarySection(localized("來源配置")) { layout in
                            ForEach(matchingSources) { source in
                                sourceEntry(source, layout: layout)
                            }
                        }
                    }
                }
                // The page's full width even when a search finds nothing: while the search is
                // active the scroll view takes its content's width (the old 探索 root, iOS 27).
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)
                .animation(reduceMotion ? nil : DSAnimation.standard, value: showsGrid)
                .rootTabTitleScrollAnchor()
            }
            .overlay {
                if !trimmedQuery.isEmpty && matchingSources.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .rootTabSearchScrollEdges()
            .scrollDismissesKeyboard(.immediately)
            .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
            .pageBackgroundToolbar(for: .explore)
            .rootTabTitle(localized("資源庫"), onScroll: .minimizesBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { moreControl }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: localized("搜索來源配置"))
            .onReceive(sourceStore.sourcesPublisher) { _ in
                exploreSources = DiscoverViewModel.exploreSources(in: sourceStore)
                sourceGroups = LibrarySourceGroups.groups(of: exploreSources)
            }
            .bookSourceActionSheets(sheet: $sourceActionSheet, pendingDeletion: $sourcePendingDeletion)
            .task { await modules.loadIfNeeded() }
            .exploreRouteDestinations(openBrowser: { browserEntry = BrowserEntryPresentation(entry: $0) })
            .remoteLibraryDestinations()
            .publicLibraryDestinations()
            .navigationDestination(isPresented: $showsRemoteLibrarySettings) {
                RemoteLibrarySettingsView()
            }
            .onChange(of: onboarding?.pendingStart, initial: true) { _, _ in
                guard let onboarding else { return }
                // Over the root, whatever a replayed tour left this stack on.
                if onboarding.take(.connectLibrary) {
                    path = NavigationPath()
                    showsRemoteLibrarySettings = true
                } else if onboarding.take(.addSources) {
                    showsRemoteLibrarySettings = false
                    path = NavigationPath()
                    // As 管理來源配置 in ••• pushes it.
                    path.append(ExploreNavigationRoute.sourceManager)
                }
            }
        }
        // On the stack, not its root, as 探索's covers (`ExploreHomeRoot`): on the root, the
        // browser's 書籤 sheet closed as it opened, on the iOS 26.5 simulator as on 26.4.1
        // (`BrowserCoverUITests`).
        .fullScreenCover(item: $browserEntry) { presentation in
            NavigationStack {
                BrowserPage(browser: browser, entry: presentation.entry)
            }
            .environmentObject(store)
        }
        .environment(\.openPublicLibraryBooks) { selection in
            if let book = selection.selectedBook { path.append(WorkDetailRoute(book)) }
        }
        .environment(\.explorePush) { $0.append(to: &path) }
    }

    // MARK: •••

    /// 資源庫's one ••• (decision 31): 管理來源配置 and the layout. 新增來源配置 and 新增模組 left it
    /// for 設定 (maintainer, 2026-10-27), as 模組 had (2026-10-17). A native menu from iOS 18; on
    /// iOS 17 a chooser, kept from when the menu opened 新增來源配置's sheets, which iOS 17 drops
    /// while a menu dismisses (`Technotes/iOS17MenuModalPresentation.md`). Nothing it holds now
    /// presents a modal, so the chooser can go once a native menu is checked on iOS 17.
    @ViewBuilder
    private var moreControl: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                moreSequence.cancel()
                showsMoreChooser = true
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(localized("更多"))
            .accessibilityIdentifier("library.more")
            .sheet(isPresented: $showsMoreChooser, onDismiss: {
                moreSequence.consumeAfterDismissal().map(perform)
            }) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(title: localized("更多"), actions: moreChoices,
                                                    onSelect: { moreSequence.select($0) })
                }
            }
        } else {
            Menu {
                Button {
                    perform(.manageSources)
                } label: {
                    Label(localized("管理來源配置"), systemImage: "slider.horizontal.3")
                }
                Divider()
                LibraryLayoutMenuItems()
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(localized("更多"))
            .accessibilityIdentifier("library.more")
        }
    }

    /// The chooser's rows: the menu's items, with each layout choice a row of its own and the
    /// menu's check mark said in words.
    private var moreChoices: [DismissalSequencedAction<LibraryMoreAction>] {
        var actions = [DismissalSequencedAction(route: LibraryMoreAction.manageSources, title: localized("管理來源配置"),
                                                systemImage: "slider.horizontal.3")]
        for grid in [true, false] {
            actions.append(DismissalSequencedAction(
                route: .showsGrid(grid), title: localized(grid ? "格狀" : "列表"),
                systemImage: grid == showsGrid ? "checkmark" : (grid ? "square.grid.2x2" : "list.bullet"),
                subtitle: grid == showsGrid ? localized("使用中") : nil))
        }
        if showsGrid {
            for density in ExploreGridDensity.allCases {
                let isCurrent = density.rawValue == gridColumnCount
                actions.append(DismissalSequencedAction(
                    route: .columns(density.rawValue), title: String(format: localized("%d 欄"), density.rawValue),
                    systemImage: isCurrent ? "checkmark" : "rectangle.split.3x1",
                    subtitle: isCurrent ? [localized("每列欄數"), localized("使用中")].joined(separator: " · ")
                        : localized("每列欄數")))
            }
        }
        return actions
    }

    private func perform(_ action: LibraryMoreAction) {
        switch action {
        case .manageSources:
            path.append(ExploreNavigationRoute.sourceManager)
        case .showsGrid(let grid):
            showsGrid = grid
        case .columns(let count):
            gridColumnCount = count
        }
    }

    // MARK: Sections

    /// 古騰堡 and 青空文庫, in 模組 with the official modules (M2b). Their identifiers stay `library.public.<id>`; each
    /// opens what it offers, as a module's card does, not shelves to browse (2026-10-22).
    /// 古騰堡's or 青空文庫's card among the app's own modules (`AppOfficialModule`).
    private func publicLibraryTile(_ key: SourceInstanceKey, layout: ExploreEntryLabel.Layout) -> some View {
        let module = AppOfficialModule.library(key)
        return NavigationLink(value: module.route) {
            ExploreEntryLabel(title: module.title, artwork: .symbol(SourceKindSymbol.symbol(for: key.type) ?? "books.vertical"),
                              layout: layout, subtitle: module.summary, detail: publicLibraryCount(key.type))
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityLabel(module.title)
        .accessibilityIdentifier("library.public.\(key.id)")
    }

    /// The remote libraries connected, and nothing while there are none: connecting one is 設定's
    /// 遠端書庫 (maintainer, 2026-10-27), so an empty section here would only be its title.
    @ViewBuilder
    private var remoteLibrariesSection: some View {
        let remoteLibraries = libraries.filter { $0.key.type != .gutenberg && $0.key.type != .aozora }
        if !remoteLibraries.isEmpty {
            LibrarySection(localized("遠端書庫")) {
                NavigationLink {
                    RemoteLibrarySettingsView()
                } label: {
                    LibrarySectionAccessoryLabel()
                }
                .accessibilityLabel(localized("管理遠端書庫"))
                .accessibilityIdentifier("library.manageRemote")
            } content: { layout in
                ForEach(remoteLibraries) { library in
                    remoteLibraryLink(library, layout: layout)
                        .accessibilityLabel(library.name)
                        .accessibilityIdentifier("library.remote.\(library.key.id)")
                }
            }
        }
    }

    /// 所有來源配置, then a card for each group (decision 31): never every source on the root.
    ///
    /// Eager, as 模組 and 訂閱 are: lazy, the grid's rows after the first stayed out of the
    /// accessibility tree on the iOS 27.0 simulator (iPhone 18 Pro Max), so VoiceOver never
    /// reached 男频 although it was drawn on screen, and a hit test there landed on a nameless
    /// node (2026-10-26, `testSourcesByGroup`). It did so before 模組 moved to the top: the
    /// order did not cause it. Measured on that simulator, eager lays 50 groups out in 63 ms
    /// against lazy's 24, and 200 in 231 against 26; a later change to the page re-lays 200 in
    /// 5 ms. Delete `isLazy: false` once `testSourcesByGroup` passes without it.
    private var sourcesSection: some View {
        LibrarySection(localized("來源配置"), isLazy: false) {
            NavigationLink(value: ExploreNavigationRoute.sourceManager) {
                LibrarySectionAccessoryLabel()
            }
            .accessibilityLabel(localized("管理來源配置"))
            .accessibilityIdentifier("library.sources")
        } content: { layout in
            if exploreSources.isEmpty {
                NavigationLink(value: ExploreNavigationRoute.sourceManager) {
                    ExploreEntryLabel(title: localized("管理來源配置"), artwork: .neutral("plus"), layout: layout,
                                      subtitle: localized("還沒有支援發現的來源配置"))
                }
                .buttonStyle(ExploreTileButtonStyle())
                .accessibilityLabel(localized("管理來源配置"))
                .accessibilityIdentifier("library.sources.add")
            } else {
                NavigationLink(value: ExploreNavigationRoute.sources(group: nil)) {
                    ExploreEntryLabel(title: localized("所有來源配置"), artwork: .source, layout: layout,
                                      corner: .count(exploreSources.count))
                }
                .buttonStyle(ExploreTileButtonStyle())
                .accessibilityLabel(localized("所有來源配置"))
                .accessibilityValue(String(format: localized("%d 個來源配置"), exploreSources.count))
                .accessibilityIdentifier("library.sources.all")
                ForEach(sourceGroups) { group in
                    NavigationLink(value: ExploreNavigationRoute.sources(group: group.name)) {
                        ExploreEntryLabel(title: group.name, artwork: .neutral("folder.fill"), layout: layout,
                                          corner: .count(group.count))
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityLabel(group.name)
                    .accessibilityValue(String(format: localized("%d 個來源配置"), group.count))
                    .accessibilityIdentifier("library.group.\(group.name)")
                }
            }
        }
    }

    private var subscriptionsSection: some View {
        // Eager, not lazy, as 匯入的模組 (`RuleModuleSection`): with 所有來源都在這裡 closed, this
        // section's lazy grid stayed in the accessibility tree as an empty, zero-sized node once
        // scrolled to, so VoiceOver never reached RSS 訂閱 (iOS 27.0 iPhone 18 Pro Max,
        // 2026-10-26; not seen on iOS 26.5 iPhone 17 Pro). One card: laziness bought nothing.
        // Delete `isLazy: false` once `testSubscriptionsWithTheNoticeClosed` passes without it.
        LibrarySection(localized("訂閱"), isLazy: false) { layout in
            let unread = rss.totalUnreadCount()
            NavigationLink(value: ExploreNavigationRoute.subscriptions) {
                // RSS's unread count, which its tab carried (maintainer's choice, 2026-10-13).
                ExploreEntryLabel(title: localized("RSS 訂閱"), artwork: .symbol("newspaper.fill"), layout: layout,
                                  subtitle: rss.sources.isEmpty ? nil : String(format: localized("%d 個訂閱源"), rss.sources.count),
                                  corner: unread > 0 ? .count(unread) : nil)
            }
            .buttonStyle(ExploreTileButtonStyle())
            .accessibilityLabel(localized("RSS 訂閱"))
            .accessibilityValue(unread > 0 ? String(format: localized("%d 未讀"), unread) : "")
            .accessibilityIdentifier("library.rss")
        }
    }

    private func sourceEntry(_ source: BookSource, layout: ExploreEntryLabel.Layout) -> some View {
        LibrarySourceEntry(source: source, layout: layout, sheet: $sourceActionSheet,
                           pendingDeletion: $sourcePendingDeletion) {
            path.append(ExploreNavigationRoute.searchInSource(sourceURL: source.bookSourceUrl))
        }
    }

    /// How many works 青空文庫's catalog lists, once it is read. Gutenberg's feeds give no total.
    private func publicLibraryCount(_ type: ProviderType) -> String? {
        guard type == .aozora, let catalog = aozora.catalog else { return nil }
        return String(format: localized("%d 本"), catalog.worksByID.count)
    }

    /// A remote library's catalog: its root feed or folder, as 探索 opens it.
    @ViewBuilder
    private func remoteLibraryLink(_ library: LibraryListing, layout: ExploreEntryLabel.Layout) -> some View {
        let connection = connections.connections.first { $0.id == library.key.id }
        let label = ExploreEntryLabel(title: library.name, artwork: .symbol(library.systemImage), layout: layout,
                                      subtitle: connection?.kind.libraryTitle,
                                      detail: connection.flatMap { URL(string: $0.url)?.host() })
        switch ExplorePlace.page(of: library.key, name: library.name) {
        case .feed(let route): NavigationLink(value: route) { label }.buttonStyle(ExploreTileButtonStyle())
        case .folder(let route): NavigationLink(value: route) { label }.buttonStyle(ExploreTileButtonStyle())
        default: label
        }
    }

    /// What moved here, until the reader closes it.
    private var notice: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized("所有來源都在這裡"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                Text(localized("來源配置、遠端書庫和 RSS 訂閱從設定和 RSS 分頁搬到了資源庫。"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                noticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(DSFont.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("關閉"))
            .accessibilityIdentifier("library.noticeClose")
        }
        .padding(.leading, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .shadow(color: DSColor.shadow, radius: DSLayout.exploreCardShadowRadius, y: DSLayout.exploreCardShadowY)
    }
}

#if DEBUG
#Preview("資源庫") {
    LibraryTabRoot(browser: BrowserState())
        .environmentObject(BookStore())
}
#endif
