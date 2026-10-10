#if DEBUG
import SwiftUI

/// Opt-in design fixture for Explore's home cards and rows (`-explore-home-fixture`), until
/// 5c-3 draws them in the app (unified library 5c-2). Every row state on one page, from
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                HomeLibraryTiles(tiles: HomeDesignFixtureData.tiles, open: { _ in })
                ForEach(HomeDesignFixtureData.rows, id: \.id) { row in
                    HomeRowView(row: row, content: HomeDesignFixtureData.content(for: row, store: store),
                                load: {}, request: {}, showAll: row.state.isSettled ? {} : nil,
                                open: { _, _ in }, openLocation: { _ in })
                }
            }
            .padding(.vertical, DSSpacing.lg)
        }
        .themedAppSurface(for: .explore)
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
    static let tiles: [HomeModel.Tile] = [
        .init(source: .localLibrary, name: localized("書架")),
        .init(source: SourceInstanceKey(type: .webDAV, id: "fixture-nas"), name: "NAS"),
        .init(source: SourceInstanceKey(type: .calibre, id: "fixture-calibre"), name: "Calibre"),
        .init(source: SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue), name: localized("Project Gutenberg")),
        .init(source: SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue), name: localized("青空文庫")),
        .init(source: SourceInstanceKey(type: .bookSource, id: "https://fixture.example"), name: "📚书山聚合"),
    ]

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

    private static func row(_ binding: HomeSectionBinding, source: SourceInstanceKey, name: String,
                            policy: SectionLoadPolicy, state: HomeModel.RowState) -> HomeModel.Row {
        let section = HomeSection(layout: .row, binding: binding)
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                             sourceName: name, policy: policy, state: state)
    }

    private static let chinese = PublicLibraryCollection.all.first!

    static let rows: [HomeModel.Row] = {
        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)
        let collection = chinese.books.map { book in
            CollectionEntry.item(SourceRecord.derived(from: book),
                                 WorkSummary(title: book.title, authors: book.author.isEmpty ? [] : [book.author],
                                             cover: .generated(seed: book.title), blurb: nil, language: nil, contentKind: .text),
                                 .gutenberg(book))
        }
        let authors = ["芥川 竜之介", "太宰 治", "夏目 漱石", "宮沢 賢治", "森 鷗外"].map {
            CollectionEntry.location(CollectionLocation(id: $0, title: $0))
        }
        return [
            row(.continueReading, source: .localLibrary, name: localized("書架"), policy: .local, state: .loaded([])),
            row(.gutenbergCollection(id: chinese.id), source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(collection)),
            row(.aozoraIndex(kind: AozoraBrowseMode.authors.rawValue), source: aozora, name: localized("青空文庫"),
                policy: .local, state: .loaded(authors)),
            row(.latest(excluded: []), source: aozora, name: localized("青空文庫"), policy: .local, state: .loading),
            row(.latest(excluded: []), source: gutenberg, name: localized("Project Gutenberg"), policy: .onDemandOnly,
                state: .awaitingRequest),
            row(.latest(excluded: []), source: SourceInstanceKey(type: .calibre, id: "fixture-calibre"), name: "Calibre",
                policy: .parallel, state: .failed(URLError(.timedOut).localizedDescription)),
        ]
    }()

    /// 繼續閱讀 shows the made-up copies; the bundled list marks two books as already here.
    @MainActor
    static func content(for row: HomeModel.Row, store: BookStore) -> HomeRowContent? {
        guard case .loaded(let entries) = row.state else { return nil }
        if case .continueReading = row.section.binding {
            let books = shelfBooks
            return HomeRowContent(entries: ShelfProvider(store: store).items(books), sourceName: row.sourceName,
                                  status: { _ in nil }, shelfBooks: Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) }))
        }
        let keys = entries.compactMap { entry -> SourceItemKey? in
            if case .item(let record, _, _) = entry { return record.key }
            return nil
        }
        let onShelf = keys.first, downloaded = keys.dropFirst(2).first
        return HomeRowContent(entries: entries, sourceName: row.sourceName, status: { key in
            key == onShelf ? .onShelf : key == downloaded ? .downloaded : nil
        }, shelfBooks: [:])
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
