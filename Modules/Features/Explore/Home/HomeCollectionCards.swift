import SwiftUI

// 專題集合 (Phase 5 plan, decisions 30 and 37): a section of lists, one card per list, as the
// public-library storefront's 精選書單: the list's name over its first covers, side by side and
// tilted on a plain ground. A tap opens the whole list. The home names no source (decision 19),
// so the storefront's "Project Gutenberg" line is not drawn.

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
                    Button { open(collection) } label: {
                        HomeCollectionCard(collection: collection)
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    // The name is the card's whole text; the artwork is hidden.
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(collection.title)
                    .accessibilityIdentifier("home.collection.\(collection.opening.identifierPrefix).\(collection.id)")
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
                HomeCardCover(cover: .reference(book.cover, session: session), title: book.title,
                              author: book.authors.joined(separator: "、"),
                              size: CGSize(width: slot.width, height: slot.width / DSLayout.discoverCoverAspectRatio))
            }
            .aspectRatio(DSLayout.publicLibraryFeaturedAspect, contentMode: .fit)
        }
    }

    private var session: URLSession? {
        switch collection.opening {
        case .gutenbergCollection: HomeCardContent.gutenbergSession(connections: connections)
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
