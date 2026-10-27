#if DEBUG
import SwiftUI

/// Opt-in design fixture for Explore's home cards and rows (`-explore-home-fixture`), from
/// unified library 5c-2; 5d-3 adds a list in each layout. Every row state on one page, from
/// bundled and made-up data: nothing is read from or written to this device's stores, and
/// nothing is sent. Never selected in a normal launch.
struct HomeDesignFixture: View {
    static let launchArgument = "-explore-home-fixture"

    @EnvironmentObject private var store: BookStore
    @Environment(\.colorScheme) private var colorScheme

    /// The theme as `ContentView` wears it, which this fixture stands in for; Pro is assumed
    /// (launch with `-debug-force-pro`).
    private var themes: ActiveAppThemes {
        let settings = GlobalSettings.shared
        return ActiveAppThemes(
            light: settings.appThemeOnScreen(for: .light, isProActive: true, hasResolvedEntitlements: true),
            dark: settings.appThemeOnScreen(for: .dark, isProActive: true, hasResolvedEntitlements: true))
    }

    var body: some View {
        AppearanceThemePreset.activeAppThemes = themes
        let accent = (colorScheme == .dark ? themes.dark : themes.light)?.accentColor
        return NavigationStack {
            HomeDesignFixturePage(store: store)
                .navigationTitle(localized("探索"))
                .toolbarTitleDisplayMode(.inline)
        }
        .tint(accent)
        .accentColor(accent)
        .environment(\.appThemes, themes)
    }
}

private struct HomeDesignFixturePage: View {
    let store: BookStore

    private let groups = HomeScopeFilter.groups(HomeDesignFixtureData.rows, in: nil)

    /// The first band, drawn at the top as the home draws its 頂部輪播圖; the other draws as
    /// 大型封面書架.
    private var carousel: HomeSectionGroup? { groups.first { $0.section.layout == .band } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let carousel {
                    row(carousel)
                        .environment(\.homeRowIsCarousel, true)
                }
                LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                    ForEach(groups.filter { $0.id != carousel?.id }) { group in
                        row(group)
                    }
                }
                .padding(.vertical, DSSpacing.lg)
            }
        }
        .themedAppSurface(for: .explore)
    }

    private func row(_ group: HomeSectionGroup) -> some View {
        HomeRowView(group: group, content: HomeDesignFixtureData.content(for: group, store: store),
                    load: {}, request: {}, showAll: group.state.isSettled ? {} : nil,
                    open: { _, _ in }, openLocation: { _ in },
                    // The ••• shows; its items do nothing to the made-up copies.
                    bookActions: HomeBookActions(removeFromContinueReading: { _ in }, markFinished: { _ in }))
    }
}

private extension HomeModel.RowState {
    var isSettled: Bool {
        if case .loaded = self { return true }
        return false
    }
}

@MainActor
enum HomeDesignFixtureData {
    /// Made-up copies read to different points, for 繼續閱讀.
    static let shelfBooks: [ReadingBook] = [
        ("宿命之環", "愛潛水的烏賊", 0.32),
        ("劍燭大荒", "青山鶴", 0.75),
        ("三體", "劉慈欣", 1.0),
        ("我的第一本書", "", 0.0),
    ].enumerated().map { index, item in
        var book = ReadingBook(title: item.0, author: item.1, contentFilename: "fixture-\(index).txt")
        book.currentPosition = item.2
        return book
    }

    private static func row(_ binding: HomeSectionBinding, layout: HomeSectionLayout = .row, source: SourceInstanceKey,
                            name: String, policy: SectionLoadPolicy, state: HomeModel.RowState) -> HomeModel.Row {
        let section = HomeSection(layout: layout, binding: binding)
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                             sourceName: name, policy: policy, state: state)
    }

    private static let chinese = PublicLibraryCollection.all.first!

    static let rows: [HomeModel.Row] = {
        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)
        let collection = chinese.books.map(CollectionEntry.bundledGutenberg)
        let authors = ["芥川 竜之介", "太宰 治", "夏目 漱石", "宮沢 賢治", "森 鷗外"].map {
            CollectionEntry.location(CollectionLocation(id: $0, title: $0))
        }
        return [
            row(.continueReading, layout: .compactReadingCard, source: .localLibrary, name: localized("書架"), policy: .local,
                state: .loaded([])),
            row(.continueReading, layout: .readingCard, source: .localLibrary, name: localized("書架"), policy: .local,
                state: .loaded([])),
            // 精選 (decision 37): shelf copies, and a bundled list with no blurb or category.
            row(.continueReading, layout: .featured, source: .localLibrary, name: localized("書架"), policy: .local,
                state: .loaded([])),
            row(.gutenbergCollection(id: chinese.id), layout: .featured, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            // 專題集合 (decision 37): the bundled lists, a card each.
            row(.gutenbergLists, layout: .collection, source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(PublicLibraryCollection.all.map { .collection(.bundledGutenberg($0)) })),
            // One list in each of the other layouts (5d-3).
            row(.gutenbergCollection(id: chinese.id), source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .multiRow, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .coverGrid, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .coverGrid, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loading),
            // After Apple Books' store and home (2026-10-25): the band loaded, drawn at the top
            // as the 頂部輪播圖 (2026-10-27), and loading, drawn as 大型封面書架 as any band after
            // the first is; the other new layouts of books, among them 色帶書架 (2026-10-27), and
            // the layouts of lists, 排行榜 among them, written as a ranked row is.
            row(.gutenbergCollection(id: chinese.id), layout: .band, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .band, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loading),
            row(.gutenbergCollection(id: chinese.id), layout: .largeRow, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .colorBand, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .heroGrid, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .rankedRow, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergLists, layout: .categoryCards, source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(PublicLibraryCollection.all.map { .collection(.bundledGutenberg($0)) })),
            row(.gutenbergLists, layout: .collageCards, source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(PublicLibraryCollection.all.map { .collection(.bundledGutenberg($0)) })),
            row(.gutenbergLists, layout: .bannerCards, source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(PublicLibraryCollection.all.map { .collection(.bundledGutenberg($0)) })),
            row(.aozoraIndex(kind: AozoraBrowseMode.authors.rawValue), source: aozora, name: localized("青空文庫"),
                policy: .local, state: .loaded(authors)),
            row(.latest, source: aozora, name: localized("青空文庫"), policy: .local, state: .loading),
            row(.latest, source: gutenberg, name: localized("Project Gutenberg"), policy: .withHome,
                state: .loading),
            row(.latest, source: SourceInstanceKey(type: .calibre, id: "fixture-calibre"), name: "Calibre",
                policy: .parallel, state: .failed(URLError(.timedOut).localizedDescription)),
        ]
    }()

    /// 繼續閱讀 shows the made-up copies; the bundled list marks two books as already here.
    @MainActor
    static func content(for group: HomeSectionGroup, store: BookStore) -> HomeRowContent? {
        if case .continueReading = group.section.binding {
            let books = shelfBooks
            return HomeRowContent(entries: ShelfProvider(store: store).items(books),
                                  status: { _ in nil }, shelfBooks: Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) }))
        }
        guard case .loaded(let entries) = group.state else { return nil }
        let keys = entries.compactMap { entry -> SourceItemKey? in
            if case .item(let record, _, _) = entry { return record.key }
            return nil
        }
        let onShelf = keys.first, downloaded = keys.dropFirst(2).first
        let status: (SourceItemKey) -> CopyLookup.Status? = { key in
            key == onShelf ? .onShelf : key == downloaded ? .downloaded : nil
        }
        var content = HomeRowContent(entries: entries, status: status, shelfBooks: [:])
        // 排行榜's columns, each its list's books (`HomeRowContent.lists`).
        if group.section.layout.style == .chart {
            content.lists = Dictionary(entries.compactMap { entry -> (String, HomeRowContent)? in
                guard case .collection(let list) = entry else { return nil }
                return (list.id, HomeRowContent(entries: list.bookEntries, status: status, shelfBooks: [:]))
            }, uniquingKeysWith: { first, _ in first })
        }
        return content
    }
}

#Preview("探索首頁卡片與列") {
    HomeDesignFixture().environmentObject(BookStore())
}

#Preview("探索首頁 — 輔助使用字級") {
    HomeDesignFixture().environmentObject(BookStore())
        .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
