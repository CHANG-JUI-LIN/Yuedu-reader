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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                ForEach(HomeScopeFilter.groups(HomeDesignFixtureData.rows, in: nil)) { group in
                    HomeRowView(group: group, content: HomeDesignFixtureData.content(for: group, store: store),
                                load: {}, request: {}, showAll: group.state.isSettled ? {} : nil,
                                open: { _, _ in }, openLocation: { _ in },
                                // The ••• shows; its items do nothing to the made-up copies.
                                bookActions: HomeBookActions(removeFromContinueReading: { _ in }, markFinished: { _ in }))
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
            // One list in each of the other layouts (5d-3).
            row(.gutenbergCollection(id: chinese.id), source: gutenberg, name: localized("Project Gutenberg"),
                policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .multiRow, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .rankedList, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .coverGrid, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loaded(collection)),
            row(.gutenbergCollection(id: chinese.id), layout: .coverGrid, source: gutenberg,
                name: localized("Project Gutenberg"), policy: .local, state: .loading),
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
        return HomeRowContent(entries: entries, status: { key in
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
