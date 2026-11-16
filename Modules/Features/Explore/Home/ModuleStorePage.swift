import SwiftUI

// A list's own store (`RuleModule.Entry.store`; maintainer, 2026-11-15, from a recording of Apple
// Books' 愛情): the list's sections down the page, drawn as the home draws its own, then every
// list with a store, as the store's 類型 at its foot. Its sections are made, not saved: nothing
// on the page is edited. Pushed, so its title is inline (docs/design.md), where Apple Books
// writes the genre large.

/// The store of `route`'s list.
struct ModuleStorePage: View {
    let route: ModuleStoreRoute
    @EnvironmentObject private var store: BookStore

    var body: some View {
        ModuleStoreContent(route: route, store: store)
    }
}

private struct ModuleStoreContent: View {
    let route: ModuleStoreRoute
    let store: BookStore

    @StateObject private var model: HomeModel
    @ObservedObject private var modules = RuleModuleLibrary.shared
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @Environment(\.explorePush) private var explorePush
    @State private var pageWidth: CGFloat = 0

    init(route: ModuleStoreRoute, store: BookStore) {
        self.route = route
        self.store = store
        _model = StateObject(wrappedValue: HomeModel.live(shelf: store))
    }

    private var entry: RuleModule.Entry? {
        modules.module(id: route.moduleID)?.module.modules.first { $0.id == route.entryID }
    }

    private var page: HomePage? {
        guard let module = modules.module(id: route.moduleID)?.module, let entry else { return nil }
        return ModuleStores.page(of: entry, in: module, language: aggregation.readingLanguages.language)
    }

    private var groups: [HomeSectionGroup] {
        let lookup = store.copyLookup()
        return model.groups(in: nil, languages: aggregation.readingLanguages,
                            readFilter: HomeReadFilter(hides: aggregation.hidesRead, isRead: lookup.isRead))
    }

    /// The other lists with a store: the page's 類型.
    private var otherListings: [ModuleStoreListing] {
        ModuleStores.listings(in: modules).filter { $0.moduleID != route.moduleID || $0.entryID != route.entryID }
    }

    private var syncKey: [AnyHashable] {
        [page, aggregation.readingLanguages.language, modules.module(id: route.moduleID)?.module.version]
    }

    var body: some View {
        content
            .navigationTitle(entry?.title ?? route.title)
            .toolbarTitleDisplayMode(.inline)
            .background(PageBackgroundView(scope: .explore, base: DSColor.background).ignoresSafeArea())
            .task(id: syncKey) {
                guard let page else { return }
                await model.sync(with: page)
            }
            .task(id: model.rows.map(\.id)) { model.homeAppeared(in: nil) }
            .onAppear { model.reloadLocal() }
    }

    @ViewBuilder
    private var content: some View {
        if page == nil {
            ContentUnavailableView {
                UnavailableLabel(localized("找不到這個類型"), systemImage: "square.stack")
            } description: {
                Text(localized("提供它的模組已移除或更新。"))
            }
        } else {
            let drawn = groups
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(drawn) { group in
                            HomeSectionSlot(entry: HomeSectionEntry(section: group.section, homeGroup: group, editableIndex: nil),
                                            isEditing: false, pageWidth: pageWidth, count: 0, openSettings: { _ in }) { group in
                                HomeRowHost(group: group, store: store, aozoraIndex: aozora.catalog, model: model,
                                            isEditable: false, push: push, openSettings: {})
                            }
                        }
                    }
                    if model.isReady, drawn.allSatisfy(\.isSettledEmpty) {
                        ContentUnavailableView {
                            UnavailableLabel(localized("這個類型還沒有作品"), systemImage: "books.vertical")
                        }
                        .padding(.vertical, DSSpacing.xxl)
                    }
                    if !otherListings.isEmpty {
                        ModuleGenreRows(title: localized("欄目：類型"), listings: otherListings) {
                            push(.explore(.moduleStore($0.route)))
                        }
                        .padding(.top, DSSpacing.xl)
                    }
                }
                .padding(.vertical, DSSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            }
            .overlay {
                if !model.isReady { ProgressView() }
            }
            .refreshable { model.reload() }
        }
    }

    private func push(_ target: ExplorePush) {
        explorePush?(target)
    }
}

/// Lists with a store as the store's 類型 rows, under a header: its symbol, its name and a
/// chevron a row, ruled between, as 類型清單 draws them. A tap opens the list's store.
struct ModuleGenreRows: View {
    let title: String
    let listings: [ModuleStoreListing]
    let open: (ModuleStoreListing) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HomeRowTitle(title: title)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(listings.enumerated()), id: \.element.id) { index, listing in
                    if index > 0 { Divider() }
                    Button { open(listing) } label: { HomeGenreRow(title: listing.title) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(listing.title)
                        .accessibilityIdentifier("moduleStore.genre.\(listing.entryID)")
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

/// 所有類型 (maintainer, 2026-11-15, after the 分類 at the top of Apple Books' store): every list
/// with a store, a row each, opening its store.
struct ModuleGenresPage: View {
    @ObservedObject private var modules = RuleModuleLibrary.shared

    private var listings: [ModuleStoreListing] { ModuleStores.listings(in: modules) }

    var body: some View {
        List {
            ForEach(listings) { listing in
                NavigationLink(value: ExploreNavigationRoute.moduleStore(listing.route)) {
                    Label {
                        Text(listing.title)
                    } icon: {
                        Image(systemName: HomeCategoryFace(name: listing.title).symbol)
                            .foregroundStyle(DSColor.accent)
                    }
                }
                .accessibilityIdentifier("genres.\(listing.entryID)")
            }
        }
        .overlay {
            if listings.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("還沒有類型"), systemImage: "square.stack")
                } description: {
                    Text(localized("安裝提供類型的模組後會列在這裡。"))
                }
            }
        }
        .navigationTitle(localized("所有類型"))
        .toolbarTitleDisplayMode(.inline)
        .task { await modules.loadIfNeeded() }
    }
}

#Preview("所有類型") {
    NavigationStack { ModuleGenresPage() }
}

#Preview("類型書店") {
    NavigationStack {
        ModuleStorePage(route: ModuleStoreRoute(moduleID: "trends", entryID: "genre-romance", title: "愛情"))
    }
    .environmentObject(BookStore())
}
