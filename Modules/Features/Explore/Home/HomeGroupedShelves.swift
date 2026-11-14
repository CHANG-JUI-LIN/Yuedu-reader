import SwiftUI

// 分組書架 (maintainer, 2026-11-14: the default home follows Apple Books' store; 「欄目不存在就先設計
// 欄目」, 1:1 from a recording of its Recent Bestsellers by Genre and a genre page's More in
// Nonfiction). A section of lists down the page, each list a shelf of its own under the section's
// one name: a rule, the list's name with a chevron to all of it, and a row of small covers swiped
// sideways. Covers alone, as the store draws them; VoiceOver reads each book all the same.

/// A section's lists, a shelf each. 編輯首頁 swipes the shelves themselves sideways, a shelf a
/// page (`homeDrawsSideways`), its covers cut by the page.
struct HomeGroupedShelves: View {
    /// The lists, a shelf each: what a shelf's header opens.
    let collections: [CollectionSummary]
    /// Each list's books in order, by its id (`HomeRowContent.lists`). A list with none while the
    /// row loads draws blank covers.
    let contents: [String: HomeRowContent]
    let openList: (CollectionSummary) -> Void
    let open: (HomeCardContent, [HomeCardContent]) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.homeDrawsSideways) private var drawsSideways
    @Environment(\.redactionReasons) private var redactionReasons

    private var cover: CGSize {
        CGSize(width: DSLayout.homeGroupedCoverWidth, height: DSLayout.homeGroupedCoverWidth / DSLayout.discoverCoverAspectRatio)
    }

    var body: some View {
        if drawsSideways {
            let perScreen = horizontalSizeClass == .regular ? 2 : 1
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                    ForEach(collections) { collection in
                        VStack(alignment: .leading, spacing: 0) {
                            header(collection)
                            // No scroll inside the page 編輯首頁 swipes: the covers the page has room for.
                            HStack(spacing: DSSpacing.lg) { covers(of: collection) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .clipped()
                        }
                        .homePageCardWidth(perScreen: perScreen, count: collections.count)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(HomeSidewaysScroll())
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(collections) { collection in
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Divider()
                            header(collection)
                        }
                        .padding(.horizontal, DSSpacing.lg)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: DSSpacing.lg) { covers(of: collection) }
                        }
                        .modifier(HomeSidewaysScroll())
                    }
                    // Under each shelf but the last, whose room is the section's own.
                    .padding(.bottom, collection.id == collections.last?.id ? 0 : DSSpacing.xxl)
                }
            }
        }
    }

    /// The list's name and a chevron: all of the list.
    private func header(_ collection: CollectionSummary) -> some View {
        Button { openList(collection) } label: {
            HStack(spacing: DSSpacing.xs) {
                Text(collection.title)
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.forward")
                    .font(DSFont.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.top, DSSpacing.sm)
            .padding(.bottom, DSSpacing.md)
            .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .homeRowControl()
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(localized("查看全部"))
        .accessibilityIdentifier("home.shelf.header.\(collection.id)")
    }

    /// The list's books as covers. A loading shelf has none yet: blank covers, drawn as the skeleton.
    @ViewBuilder
    private func covers(of collection: CollectionSummary) -> some View {
        let cards = contents[collection.id]?.cards ?? []
        let shown = cards.isEmpty && redactionReasons.contains(.placeholder)
            ? (0..<6).map(HomeCardContent.placeholder)
            : cards
        ForEach(shown.indices, id: \.self) { index in
            let card = shown[index]
            Button { open(card, cards) } label: {
                HomeCoverCard(content: card, size: cover)
            }
            .buttonStyle(ExploreTileButtonStyle())
            .homeRowControl()
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(card.accessibilityLabel)
            .accessibilityValue(card.accessibilityValue)
            .accessibilityIdentifier("home.card.\(card.id.instance.type.rawValue).\(card.id.item)")
        }
    }
}

#if DEBUG
#Preview("分組書架") {
    let sample = HomeLayoutSample.standard
    ScrollView {
        HomeSectionLists(layout: .groupedShelves, collections: sample.collections(for: .groupedShelves),
                         contents: sample.listContents, open: { _ in })
            .padding(.vertical, DSSpacing.lg)
    }
}

#Preview("分組書架，載入中") {
    let lists = ["小說與文學", "非小說"].map { title in
        CollectionSummary(id: title, title: title, books: [], languages: [], opening: .gutenbergCollection(id: title))
    }
    ScrollView {
        HomeSectionLists(layout: .groupedShelves, collections: lists, open: { _ in })
            .redacted(reason: .placeholder)
            .padding(.vertical, DSSpacing.lg)
    }
}
#endif
