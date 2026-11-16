import SwiftUI

// 類型清單 (maintainer, 2026-11-14: the default home follows Apple Books' store, which ends on
// 類型; 「欄目不存在就先設計欄目」, 1:1 from a recording of it). A plain list down the page: a row per
// list, each a symbol for the kind of book its name says, the name, and a chevron, with a rule
// between rows. No covers, as 大圖卡片 has none: a list is named for a kind of book, and the
// symbol is the one its 分類卡 draws large (`HomeCategoryFace`). A tap opens the list.

/// A section's lists as rows; two columns of them on a wider screen. Last, as the store's 類型
/// ends, 所有類型 (maintainer, 2026-11-16: 「所有分類的入口留下一個在這」) while a module gives lists
/// with a store, on a page that can push it; in the section's form, 加入清單 in its place.
struct HomeGenreList: View {
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.explorePush) private var push
    @Environment(\.homeAddListCard) private var addList
    @ObservedObject private var modules = RuleModuleLibrary.shared

    /// A row of the list: one of the section's lists, or 所有類型.
    private enum Item: Identifiable {
        case list(CollectionSummary)
        case allGenres
        /// 加入清單, in the section's form.
        case add(HomeAddListCard)

        var id: String {
            switch self {
            case .list(let collection): collection.id
            case .allGenres: "\u{1F}allGenres"
            case .add: "\u{1F}add"
            }
        }
    }

    private var items: [Item] {
        let lists = collections.map(Item.list)
        if let addList { return lists + [.add(addList)] }
        guard push != nil, !ModuleStores.listings(in: modules).isEmpty else { return lists }
        return lists + [.allGenres]
    }

    var body: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        let columns = Array(repeating: GridItem(.flexible(), spacing: DSSpacing.xl, alignment: .top), count: perScreen)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    // Between rows, as the store rules them: none over a column's first.
                    if index >= perScreen { Divider() }
                    switch item {
                    case .list(let collection): row(collection)
                    case .allGenres: allGenresRow
                    case .add(let action): addRow(action)
                    }
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    private func row(_ collection: CollectionSummary) -> some View {
        HomeCollectionButton(collection: collection, open: open) {
            HomeGenreRow(title: collection.title)
        }
    }

    private func addRow(_ action: HomeAddListCard) -> some View {
        Button { action.perform() } label: {
            HomeGenreRow(title: localized("加入清單"), symbolName: "plus")
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(localized("加入清單"))
        .accessibilityIdentifier("homeSection.lists.add")
    }

    private var allGenresRow: some View {
        Button { push?(.explore(.genres)) } label: {
            HomeGenreRow(title: localized("所有類型"), symbolName: "line.3.horizontal")
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(localized("所有類型"))
        .accessibilityIdentifier("home.genreList.allGenres")
    }
}

/// One list's row: its symbol in a column of its own, so the names line up, the name, and the
/// chevron at the trailing edge. As tall as the store's rows; taller for a name that wraps at a
/// large text size. In a loading row, the skeleton's grey where the symbol will be.
struct HomeGenreRow: View {
    let title: String
    /// Its own symbol, where the name is not a kind of book (所有類型).
    var symbolName: String? = nil

    @Environment(\.redactionReasons) private var redactionReasons
    @ScaledMetric(relativeTo: .body) private var symbolWidth = DSLayout.homeGenreSymbolWidth

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            symbol
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: DSSpacing.sm)
            Image(systemName: "chevron.forward")
                .font(DSFont.footnote.weight(.semibold))
                .foregroundStyle(DSColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: DSLayout.homeGenreRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var symbol: some View {
        if redactionReasons.contains(.placeholder) {
            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                .fill(DSColor.neutralControlFill)
                .aspectRatio(1, contentMode: .fit)
        } else {
            Image(systemName: symbolName ?? HomeCategoryFace(name: title).symbol)
                .font(DSFont.title3)
                .foregroundStyle(DSColor.textPrimary)
        }
    }
}

#if DEBUG
#Preview("類型清單") {
    ScrollView {
        HomeSectionLists(layout: .genreList, collections: HomeLayoutSample.standard.collections(for: .genreList),
                         open: { _ in })
            .padding(.vertical, DSSpacing.lg)
    }
}

#Preview("類型清單，載入中與輔助使用字級") {
    ScrollView {
        HomeSectionLists(layout: .genreList, collections: HomeLayoutSample.standard.collections(for: .genreList),
                         open: { _ in })
            .redacted(reason: .placeholder)
        HomeSectionLists(layout: .genreList, collections: HomeLayoutSample.standard.collections(for: .genreList),
                         open: { _ in })
            .environment(\.dynamicTypeSize, .accessibility3)
    }
}
#endif
