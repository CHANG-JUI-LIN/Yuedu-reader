import SwiftUI

// 專題集合 (Phase 5 plan, decisions 30 and 37): a section of lists, one card per list, as the
// public-library storefront's 精選書單: the list's name over its first covers, side by side and
// tilted on a plain ground. A tap opens the whole list. The home names no source (decision 19),
// so the storefront's "Project Gutenberg" line is not drawn.
// The maintainer, 2026-10-25, after Apple Books' home (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`):
// - 分類卡片: as More to Explore, a wide card per list down the page, its name beside its
//   covers fanned at the trailing edge and cut off by the card's.
// - 拼貼卡片: as Top Picks and Apple Books Japan's ピックアップ (2026-10-27, 1:1), a card per list
//   swiped sideways, its first cover large and the next four small in two columns beside it,
//   the second cut off by the card's edge, over its name and how many books it holds.
// - 大圖卡片 (2026-10-27): a 分類卡 as More to Explore's Romance, a wide card a page, the list's
//   name on a face designed from it (`HomeCategoryArt`) or the reader's photo; no covers.
// - 排行榜 (2026-10-27): Top Charts' columns, a ranking each (`HomeChartColumns`).

/// A section's lists in its layout. A section of lists given a layout of books (a custom page's,
/// a later build's) draws 專題集合, the layout every section of lists can take.
struct HomeSectionLists: View {
    let layout: HomeSectionLayout
    let collections: [CollectionSummary]
    /// Each list's books by its id, which 排行榜 draws (`HomeRowContent.lists`).
    var contents: [String: HomeRowContent] = [:]
    let open: (CollectionSummary) -> Void
    /// A book of 排行榜 was tapped, with its column's books.
    var openBook: (HomeCardContent, [HomeCardContent]) -> Void = { _, _ in }
    /// An article of 排行榜 was tapped.
    var openArticle: (SubscriptionArticle) -> Void = { _ in }

    var body: some View {
        switch layout.style {
        case .categoryCards: HomeCategoryCards(collections: collections, open: open)
        case .collageCards: HomeCollageCards(collections: collections, open: open)
        case .bannerCards: HomeBannerCards(collections: collections, open: open)
        case .chart:
            HomeChartColumns(collections: collections, contents: contents, openColumn: open, open: openBook,
                             openArticle: openArticle)
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
                    .homePageCardWidth(perScreen: perScreen, count: collections.count)
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
            let books = collection.artworkBooks
            CollectionCoverArtwork(count: books.count) { index, slot in
                let book = books[index]
                // A 2:3 cover as wide as its third of the artwork, as the storefront's covers fit.
                HomeCardCover(cover: .reference(book.cover, session: collection.opening.coverSession(connections: connections)),
                              title: book.title, author: book.authors.joined(separator: "、"),
                              size: CGSize(width: slot.width, height: slot.width / DSLayout.discoverCoverAspectRatio))
            }
            .aspectRatio(DSLayout.publicLibraryFeaturedAspect, contentMode: .fit)
        }
    }
}

extension CollectionSummary {
    /// A card's accessibility identifier, `home.collection.<kind>.<key>`: a bundled list by its
    /// id, a category by its title among its source's (its id holds its URL), any other list by
    /// its name.
    var homeIdentifier: String {
        switch opening {
        case .gutenbergCollection: return "home.collection.gutenberg.\(id)"
        case .list(let list):
            switch list.section.binding {
            case .sourceCategories(let references): return "home.collection.sourceCategory.\(references.first?.title ?? title)"
            case .gutenbergCollection(let id): return "home.collection.gutenberg.\(id)"
            default: return "home.collection.list.\(title)"
            }
        }
    }
}

extension CollectionOpening {
    /// The list's source, as 大圖卡片 names it over the list when the list does not
    /// (`CollectionSummary.sourceName`).
    @MainActor
    var sourceName: String {
        switch self {
        case .gutenbergCollection: localized("Project Gutenberg")
        case .list(let list): list.sourceName
        }
    }

    /// The session a list's covers load through: a library's connection's, as its rows' covers
    /// load (Gutenberg's built-in one among them). A book source's and a module's covers carry
    /// their headers in their reference.
    @MainActor
    func coverSession(connections: RemoteLibraryConnectionStore) -> URLSession? {
        switch self {
        case .gutenbergCollection:
            return HomeCardContent.gutenbergSession(connections: connections)
        case .list(let list):
            switch list.source.type {
            case .gutenberg: return HomeCardContent.gutenbergSession(connections: connections)
            case .opds, .calibre, .webDAV:
                return connections.connection(id: list.source.id).map { connections.httpClient(for: $0).session }
            case .library, .aozora, .bookSource, .bibliographic, .module: return nil
            }
        }
    }
}

/// One list's button in every layout of lists: its name is the whole label (the artwork is
/// hidden), and the UI tests find it by `CollectionSummary.homeIdentifier`.
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
            .accessibilityIdentifier(collection.homeIdentifier)
    }
}

// MARK: - 分類卡片

/// The lists down the page, a card each; two side by side on a wider screen. 編輯首頁 swipes
/// them sideways, a card a page (`homeDrawsSideways`).
struct HomeCategoryCards: View {
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
                        card(collection)
                            .homePageCardWidth(perScreen: perScreen, count: collections.count)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(HomeSidewaysScroll())
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md, alignment: .top), count: perScreen)
            LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpacing.md) {
                ForEach(collections) { collection in
                    card(collection)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    private func card(_ collection: CollectionSummary) -> some View {
        HomeCollectionButton(collection: collection, open: open) {
            HomeCategoryCard(collection: collection)
        }
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
        return coverSize.width + DSLayout.homeCategoryCoverStep * CGFloat(max(0, collection.artworkBooks.count - 1)) - overhang
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
        let books = collection.artworkBooks
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
            // Top Picks' cards stand this far apart.
            LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
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

/// One list as Apple Books' Top Picks draws it (maintainer, 2026-10-27: 1:1; Apple Books Japan's
/// ピックアップ is the same card): a white card at least 3:4, the first cover large and the next
/// four small in two rows beside it, all standing on one line, the second column cut by the
/// card's trailing edge; the list's name and how many books it holds at its foot.
struct HomeCollageCard: View {
    let collection: CollectionSummary
    let width: CGFloat
    var connections: RemoteLibraryConnectionStore = .shared

    static func countText(_ collection: CollectionSummary) -> String {
        String(format: localized("%d 本"), collection.bookCount)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            collage
            Spacer(minLength: DSSpacing.xl)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(collection.title)
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                Text(Self.countText(collection))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .lineLimit(1)
            .multilineTextAlignment(.leading)
            .padding(.trailing, DSSpacing.lg)
        }
        .padding(.leading, DSSpacing.lg)
        .padding(.top, DSSpacing.xxl)
        .padding(.bottom, DSSpacing.xl)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: width / DSLayout.homeCollageCardAspect, alignment: .top)
        .clipShape(shape)
        .interfaceCardSurface(in: shape)
        .shadow(color: DSColor.shadow, radius: DSLayout.exploreCardShadowRadius, y: DSLayout.exploreCardShadowY)
        .contentShape(shape)
    }

    /// Book 1 large; 2 and 3 the first column of small ones, 4 and 5 the one the edge cuts. Drawn
    /// from the leading padding to the card's edge.
    private var collage: some View {
        let aspect = DSLayout.discoverCoverAspectRatio
        let largeWidth = width * DSLayout.homeCollageLargeShare
        let large = CGSize(width: largeWidth, height: largeWidth / aspect)
        let smallWidth = largeWidth * DSLayout.homeCollageSmallToLarge
        let small = CGSize(width: smallWidth, height: smallWidth / aspect)
        let books = collection.books
        let session = collection.opening.coverSession(connections: connections)
        let columns = [Array(books.indices.dropFirst().prefix(2)), Array(books.indices.dropFirst(3).prefix(2))]
        return HStack(alignment: .bottom, spacing: DSSpacing.md) {
            ForEach(books.indices.prefix(1), id: \.self) { cover(books[$0], size: large, session: session) }
            ForEach(columns.indices, id: \.self) { column in
                VStack(spacing: DSSpacing.sm) {
                    ForEach(columns[column], id: \.self) { cover(books[$0], size: small, session: session) }
                }
            }
        }
        .frame(width: width - DSSpacing.lg, height: large.height, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    private func cover(_ book: WorkSummary, size: CGSize, session: URLSession?) -> some View {
        HomeCardCover(cover: .reference(book.cover, session: session), title: book.title,
                      author: book.authors.joined(separator: "、"), size: size)
    }
}

// MARK: - 大圖卡片

/// The lists as 分類卡, a card to a page and the next one peeking (`DSLayout.homePagePeek`), as
/// Apple Books' More to Explore pages them; two to a page on a wider screen.
struct HomeBannerCards: View {
    let collections: [CollectionSummary]
    let open: (CollectionSummary) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                ForEach(collections) { collection in
                    HomeCollectionButton(collection: collection, value: collection.sourceName ?? collection.opening.sourceName,
                                         open: open) {
                        HomeBannerCard(collection: collection)
                    }
                    .containerRelativeFrame(.horizontal) { length, _ in
                        let peek = collections.count > perScreen ? DSSpacing.lg + DSLayout.homePagePeek : 0
                        let gaps = DSSpacing.lg * CGFloat(perScreen - 1)
                        return max(0, (length - gaps - peek) / CGFloat(perScreen))
                    }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }
}

/// One list as a 分類卡 (maintainer, 2026-10-27: 「大圖卡片…可以拿來當分類卡」「不需要真實封面」), as
/// Apple Books' More to Explore draws Romance: the list's name in white at the foot of a wide
/// card, the card the reader's photo for it (「分類卡的圖片可以自定義」), darkened under the name,
/// or else its designed face (`HomeCategoryArt`). A name too long for the card at a large text
/// size makes the card taller. A thumbnail, as its section's form shows each card, is the same
/// face in small.
struct HomeBannerCard: View {
    let title: String
    let photoID: HomeListCardPhotoID?
    var isThumbnail = false
    @ObservedObject var photos: HomeListCardPhotos = HomePageStore.shared.cardPhotos

    @Environment(\.redactionReasons) private var redactionReasons

    init(collection: CollectionSummary) {
        title = collection.title
        photoID = collection.photoID
    }

    init(title: String, photoID: HomeListCardPhotoID?, photos: HomeListCardPhotos, isThumbnail: Bool) {
        self.title = title
        self.photoID = photoID
        self.photos = photos
        self.isThumbnail = isThumbnail
    }

    private var photo: UIImage? {
        guard !redactionReasons.contains(.placeholder), let photoID else { return nil }
        return photos.images[photoID]
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isThumbnail ? DSRadius.lg : DSRadius.xxl, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            Color.clear.aspectRatio(DSLayout.homeBannerAspect, contentMode: .fit)
            Text(title)
                .font(isThumbnail ? DSFont.headline : DSFont.largeTitle.weight(.semibold))
                .foregroundStyle(DSColor.textOnFixedFill)
                .lineLimit(isThumbnail ? 2 : 3)
                .multilineTextAlignment(.leading)
                .padding(.leading, isThumbnail ? DSSpacing.md : DSSpacing.xxl)
                .padding(.trailing, isThumbnail ? DSSpacing.sm : DSSpacing.lg)
                .padding(.vertical, isThumbnail ? DSSpacing.sm : DSSpacing.xl)
        }
        .background {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .overlay {
                        LinearGradient(colors: [.clear, DSColor.photoNameScrim], startPoint: .center, endPoint: .bottom)
                    }
                    .accessibilityHidden(true)
            } else {
                HomeCategoryArt(name: title)
            }
        }
        .clipShape(shape)
        .shadow(color: isThumbnail ? .clear : DSColor.shadow, radius: DSLayout.exploreCardShadowRadius,
                y: DSLayout.exploreCardShadowY)
        .contentShape(shape)
        .onAppear { photos.loadIfNeeded() }
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

#Preview("分類卡片，來源配置的分類") {
    // A 來源配置's categories, drawn with the bundled lists' covers so the preview needs no network.
    let lists = PublicLibraryCollection.all.map(CollectionSummary.bundledGutenberg)
    let categories = zip(["玄幻", "都市", "歷史軍事"], lists).map { title, list in
        let category = ExploreCategoryReference(sourceURL: "https://preview.example", title: title, url: "https://preview.example/\(title)")
        let opening = HomeListOpening(section: HomeSection(layout: .row, binding: .sourceCategories([category])),
                                      source: SourceInstanceKey(type: .bookSource, id: category.sourceURL), sourceName: "預覽來源",
                                      title: title, entries: [])
        return CollectionSummary(id: title, title: title, books: list.books, languages: [], opening: .list(opening))
    }
    ScrollView {
        HomeCategoryCards(collections: categories, open: { _ in })
            .padding(.vertical, DSSpacing.lg)
    }
}

#Preview("大圖卡片，古騰堡精選書單") {
    let lists = PublicLibraryCollection.all.map(CollectionSummary.bundledGutenberg)
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            HomeBannerCards(collections: lists, open: { _ in })
            // 兒童與青少年 holds two books: a fan of two.
            HomeBannerCards(collections: [lists[2]], open: { _ in })
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
