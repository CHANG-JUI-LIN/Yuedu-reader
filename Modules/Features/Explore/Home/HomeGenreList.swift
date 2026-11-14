import SwiftUI

// 類型清單 (maintainer, 2026-11-14: the default home follows Apple Books' store, which ends on
// 類型; 「欄目不存在就先設計欄目」, 1:1 from a recording of it). A plain list down the page: a row per
// list, each a symbol for the kind of book its name says, the name, and a chevron, with a rule
// between rows. No covers, as 大圖卡片 has none: a list is named for a kind of book, and the
// symbol is the one its 分類卡 draws large (`HomeCategoryFace`). A tap opens the list.

/// A section's lists as rows; two columns of them on a wider screen. 編輯首頁 swipes them sideways,
/// a row a page (`homeDrawsSideways`).
struct HomeGenreList: View {
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.homeDrawsSideways) private var drawsSideways

    var body: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        if drawsSideways {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                    ForEach(collections) { collection in
                        row(collection)
                            .homePageCardWidth(perScreen: perScreen, count: collections.count)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(HomeSidewaysScroll())
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: DSSpacing.xl, alignment: .top), count: perScreen)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    VStack(spacing: 0) {
                        // Between rows, as the store rules them: none over a column's first.
                        if index >= perScreen { Divider() }
                        row(collection)
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    private func row(_ collection: CollectionSummary) -> some View {
        HomeCollectionButton(collection: collection, open: open) {
            HomeGenreRow(title: collection.title)
        }
    }
}

/// One list's row: its symbol in a column of its own, so the names line up, the name, and the
/// chevron at the trailing edge. As tall as the store's rows; taller for a name that wraps at a
/// large text size. In a loading row, the skeleton's grey where the symbol will be.
struct HomeGenreRow: View {
    let title: String

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
            Image(systemName: HomeCategoryFace(name: title).symbol)
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
