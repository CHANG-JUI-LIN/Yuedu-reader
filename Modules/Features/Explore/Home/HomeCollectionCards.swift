import SwiftUI

// 專題集合 (Phase 5 plan, decisions 30 and 37): a section of lists, one card per list, as the
// public-library storefront's 精選書單: the list's name over its first covers, side by side and
// tilted on a plain ground. A tap opens the whole list. The home names no source (decision 19),
// so the storefront's "Project Gutenberg" line is not drawn.
// The maintainer, 2026-10-25, after Apple Books' home (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`):
// - 分類卡片: as More to Explore, a wide card per list down the page, its name beside its
//   covers fanned at the trailing edge and cut off by the card's.
// - 拼貼卡片: as Top Picks, a card per list swiped sideways, its first cover large and the next
//   two small beside it, over its name and how many books it holds.

/// A section's lists in its layout. A section of lists given a layout of books (a custom page's,
/// a later build's) draws 專題集合, the layout every section of lists can take.
struct HomeSectionLists: View {
    let layout: HomeSectionLayout
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    var body: some View {
        switch layout.style {
        case .categoryCards: HomeCategoryCards(collections: collections, open: open)
        case .collageCards: HomeCollageCards(collections: collections, open: open)
        default: HomeCollectionCards(collections: collections, open: open)
        }
    }
}

/// A section's lists, a card to a page, the next one showing past the edge; two to a page on a
/// wider screen, as 精選 pages its books.
struct HomeCollectionCards: View {
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(collections) { collection in
                    HomeCollectionButton(collection: collection, open: open) {
                        HomeCollectionCard(collection: collection)
                    }
                    .containerRelativeFrame(.horizontal) { length, _ in
                        let peek = collections.count > perScreen ? DSLayout.homeReadingCardPeek + DSSpacing.md : 0
                        let gaps = DSSpacing.md * CGFloat(perScreen - 1)
                        return max(0, (length - gaps - peek) / CGFloat(perScreen))
                    }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }
}

/// One list: its name, then its artwork, as the storefront's 精選書單 card. The name is a size
/// under the section's own, which sits right above it on the home.
struct HomeCollectionCard: View {
    let collection: CollectionSummary
    var connections: RemoteLibraryConnectionStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text(collection.title)
                .font(DSFont.title3.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            CollectionCoverArtwork(count: collection.books.count) { index, slot in
                let book = collection.books[index]
                // A 2:3 cover as wide as its third of the artwork, as the storefront's covers fit.
                HomeCardCover(cover: .reference(book.cover, session: collection.opening.coverSession(connections: connections)),
                              title: book.title, author: book.authors.joined(separator: "、"),
                              size: CGSize(width: slot.width, height: slot.width / DSLayout.discoverCoverAspectRatio))
            }
            .aspectRatio(DSLayout.publicLibraryFeaturedAspect, contentMode: .fit)
        }
    }
}

extension CollectionOpening {
    /// The middle of a card's accessibility identifier, `home.collection.<prefix>.<id>`.
    var identifierPrefix: String {
        switch self {
        case .gutenbergCollection: "gutenberg"
        }
    }

    /// The session a list's covers load through: Gutenberg's built-in connection's, as the store
    /// loads them.
    @MainActor
    func coverSession(connections: RemoteLibraryConnectionStore) -> URLSession? {
        switch self {
        case .gutenbergCollection: HomeCardContent.gutenbergSession(connections: connections)
        }
    }
}

/// One list's button in every layout of lists: its name is the whole label (the artwork is
/// hidden), and the UI tests find it by `home.collection.<prefix>.<id>`.
private struct HomeCollectionButton<Card: View>: View {
    let collection: CollectionSummary
    var value: String?
    let open: (CollectionSummary) -> Void
    @ViewBuilder let label: () -> Card

    var body: some View {
        Button { open(collection) } label: { label() }
            .buttonStyle(ExploreTileButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(collection.title)
            .accessibilityValue(value ?? "")
            .accessibilityIdentifier("home.collection.\(collection.opening.identifierPrefix).\(collection.id)")
    }
}

// MARK: - 分類卡片

/// The lists down the page, a card each; two side by side on a wider screen.
struct HomeCategoryCards: View {
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md, alignment: .top),
                            count: horizontalSizeClass == .regular ? 2 : 1)
        LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpacing.md) {
            ForEach(collections) { collection in
                HomeCollectionButton(collection: collection, open: open) {
                    HomeCategoryCard(collection: collection)
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

/// One list as More to Explore draws a category: its name at the top leading corner, in the
/// serif, and its first covers fanned at the trailing edge, run off the card's bottom and side.
/// The card grows with its name; the name keeps clear of the covers.
struct HomeCategoryCard: View {
    let collection: CollectionSummary
    var connections: RemoteLibraryConnectionStore = .shared

    private var coverSize: CGSize {
        CGSize(width: DSLayout.homeCategoryCoverWidth,
               height: DSLayout.homeCategoryCoverWidth / DSLayout.discoverCoverAspectRatio)
    }

    /// The width the fanned covers take inside the card.
    private var coversWidth: CGFloat {
        let overhang = coverSize.width * DSLayout.homeCategoryCoverOverhang
        return coverSize.width + DSLayout.homeCategoryCoverStep * CGFloat(max(0, collection.books.count - 1)) - overhang
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
        Text(collection.title)
            .font(DSFont.serifCardTitle)
            .foregroundStyle(DSColor.textPrimary)
            .multilineTextAlignment(.leading)
            .padding(DSSpacing.lg)
            .padding(.trailing, coversWidth)
            .frame(maxWidth: .infinity, minHeight: DSLayout.homeCategoryCardHeight, alignment: .topLeading)
            .background(alignment: .bottomTrailing) { covers }
            .clipShape(shape)
            .interfaceCardSurface(in: shape)
            .shadow(color: DSColor.shadow, radius: DSLayout.exploreCardShadowRadius, y: DSLayout.exploreCardShadowY)
            .contentShape(shape)
    }

    /// The first cover in front at the leading end, each next one behind it and further along,
    /// turned a little more, the whole fan run off the card's bottom and trailing edges.
    private var covers: some View {
        let books = collection.books
        let session = collection.opening.coverSession(connections: connections)
        return ZStack(alignment: .bottomLeading) {
            ForEach(books.indices, id: \.self) { index in
                let book = books[index]
                HomeCardCover(cover: .reference(book.cover, session: session), title: book.title,
                              author: book.authors.joined(separator: "、"), size: coverSize)
                    .rotationEffect(.degrees(DSLayout.homeCategoryCoverRotation * (Double(index) - 1)))
                    .offset(x: DSLayout.homeCategoryCoverStep * CGFloat(index))
                    .zIndex(Double(books.count - index))
            }
        }
        .frame(width: coverSize.width + DSLayout.homeCategoryCoverStep * CGFloat(max(0, books.count - 1)),
               height: coverSize.height, alignment: .bottomLeading)
        .offset(x: coverSize.width * DSLayout.homeCategoryCoverOverhang,
                y: coverSize.height * DSLayout.homeCategoryCoverOverhang)
        .accessibilityHidden(true)
    }
}

// MARK: - 拼貼卡片

/// The lists side by side, a card each, swiped sideways.
struct HomeCollageCards: View {
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    @ScaledMetric(relativeTo: .headline) private var scaledWidth = DSLayout.homeCollageCardWidth

    var body: some View {
        let width = min(scaledWidth, DSLayout.homeCollageCardMaxWidth)
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(collections) { collection in
                    HomeCollectionButton(collection: collection, value: HomeCollageCard.countText(collection), open: open) {
                        HomeCollageCard(collection: collection, width: width)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }
}

/// One list as Top Picks draws it: the first cover large and the next two small, in a column as
/// tall as it, then the list's name (two lines kept, so cards side by side line up) and how many
/// books it holds.
struct HomeCollageCard: View {
    let collection: CollectionSummary
    let width: CGFloat
    var connections: RemoteLibraryConnectionStore = .shared

    static func countText(_ collection: CollectionSummary) -> String {
        String(format: localized("%d 本"), collection.bookCount)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            collage(width: width - DSSpacing.md * 2)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(collection.title)
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                Text(Self.countText(collection))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.leading)
        }
        .padding(DSSpacing.md)
        .frame(width: width, alignment: .topLeading)
        .interfaceCardSurface(in: shape)
        .shadow(color: DSColor.shadow, radius: DSLayout.exploreCardShadowRadius, y: DSLayout.exploreCardShadowY)
        .contentShape(shape)
    }

    /// `width` holds the large cover, a gap and the small ones' column: with every cover 2:3 and
    /// the two small ones and the gap between them as tall as the large one, the large one is
    /// (width − ⅔ gap) / 1.5 wide.
    private func collage(width: CGFloat) -> some View {
        let gap = DSSpacing.xs
        let aspect = DSLayout.discoverCoverAspectRatio
        let largeWidth = (width - gap * 2 / 3) / 1.5
        let large = CGSize(width: largeWidth, height: largeWidth / aspect)
        let smallHeight = (large.height - gap) / 2
        let small = CGSize(width: smallHeight * aspect, height: smallHeight)
        let books = collection.books
        let session = collection.opening.coverSession(connections: connections)
        return HStack(alignment: .top, spacing: gap) {
            ForEach(books.indices.prefix(1), id: \.self) { index in
                HomeCardCover(cover: .reference(books[index].cover, session: session), title: books[index].title,
                              author: books[index].authors.joined(separator: "、"), size: large)
            }
            VStack(spacing: gap) {
                ForEach(books.indices.dropFirst().prefix(2), id: \.self) { index in
                    HomeCardCover(cover: .reference(books[index].cover, session: session), title: books[index].title,
                                  author: books[index].authors.joined(separator: "、"), size: small)
                }
            }
        }
        .frame(width: width, height: large.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// A list's artwork: its first covers side by side, tilted, on a plain ground. The public-library
/// storefront's 精選書單 drew it first; the home's 專題集合 (decision 37) draws it with the home's covers.
/// `cover` draws one cover in the size given, a third of the artwork's width by its height.
struct CollectionCoverArtwork<Cover: View>: View {
    let count: Int
    @ViewBuilder let cover: (Int, CGSize) -> Cover

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: DSSpacing.lg) {
                ForEach(0..<count, id: \.self) { index in
                    cover(index, CGSize(width: proxy.size.width / 3, height: proxy.size.height))
                        .frame(width: proxy.size.width / 3, height: proxy.size.height)
                }
            }
            .rotationEffect(.degrees(DSLayout.publicLibraryFeaturedRotation))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(DSColor.surfaceTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("分類卡片與拼貼卡片，古騰堡精選書單") {
    let lists = PublicLibraryCollection.all.map(CollectionSummary.bundledGutenberg)
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            HomeCategoryCards(collections: lists, open: { _ in })
            HomeCollageCards(collections: lists, open: { _ in })
            // 兒童與青少年 holds two books: a fan of two, a collage with one small cover.
            HomeCategoryCards(collections: [lists[2]], open: { _ in })
                .environment(\.dynamicTypeSize, .accessibility3)
        }
        .padding(.vertical, DSSpacing.lg)
    }
}

#Preview("專題集合，古騰堡精選書單") {
    let lists = PublicLibraryCollection.all.map(CollectionSummary.bundledGutenberg)
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            HomeCollectionCards(collections: lists, open: { _ in })
            // 兒童與青少年 holds two books: the artwork with two covers.
            HomeCollectionCard(collection: lists[2])
                .padding(.horizontal, DSSpacing.lg)
        }
        .padding(.vertical, DSSpacing.lg)
    }
}
#endif
