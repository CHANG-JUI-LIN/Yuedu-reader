import SwiftUI

/// Gutenberg's front page, shown in place by the home's 範圍 (5c-3, 5d-1): the storefront
/// without Aozora, which has a page of its own there.
struct GutenbergHomePage: View {
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    var body: some View {
        PublicLibraryStorefront(includesAozora: false)
            .navigationTitle(localized("Project Gutenberg"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .explore)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: PublicLibraryRoute.categories(aozora.catalog)) {
                        Text(localized("分類"))
                    }.accessibilityIdentifier("publicLibrary.categories")
                }
            }
    }
}

/// The store's front page: Gutenberg's featured lists and shelves, and Aozora's 新着 where it
/// is included. Inside a stack wearing `publicLibraryDestinations` and putting what a book opens
/// in `openPublicLibraryBooks` (作品詳情 on 探索 and 搜索).
struct PublicLibraryStorefront: View {
    let includesAozora: Bool
    @Environment(\.openPublicLibraryBooks) private var openBooks
    @Environment(\.publicLibraryCoverFrames) private var coverFrames
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    private static let curatedScope = "curated"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSLayout.publicLibrarySectionSpacing) {
                featuredCollections.rootTabTitleScrollAnchor()
                ForEach([PublicLibraryCollection.chinese, .fiction]) { collection in
                    PublicLibraryShelf(title: localized(collection.titleKey),
                        books: collection.books.map(PublicLibraryBook.gutenberg), select: select,
                        route: .collection(id: collection.id))
                }
                curatedReading
                ForEach([PublicLibraryCollection.children, .thought]) { collection in
                    PublicLibraryShelf(title: localized(collection.titleKey),
                        books: collection.books.map(PublicLibraryBook.gutenberg), select: select,
                        route: .collection(id: collection.id))
                }
                if includesAozora, let index = aozora.catalog {
                    Section {
                        PublicLibraryShelf(title: localized("青空文庫"),
                            books: Array(index.newWorks.prefix(12)).map { .aozora($0, index) }, select: select,
                            route: .aozoraWorks(title: localized("新着作品"), works: index.newWorks, index: index))
                        if aozora.isRefreshing { ProgressView(localized("正在更新目錄")) }
                        if case .failed = aozora.state {
                            Button(localized("重試")) { Task { await aozora.load(forceRefresh: true) } }
                                .disabled(aozora.isRefreshing).padding(.horizontal, DSLayout.publicLibraryMargin)
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(.init(localized("書誌資料：青空文庫（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）")))
                            if case .failed = aozora.state { Text(localized("目錄更新失敗，仍顯示已儲存的目錄。")) }
                        }.dsSectionFooter().padding(.horizontal, DSLayout.publicLibraryMargin)
                    }
                }
                Section {
                    NavigationLink(value: PublicLibraryRoute.categories(aozora.catalog)) {
                        Label(localized("瀏覽所有分類"), systemImage: "books.vertical")
                    }.padding(.horizontal, DSLayout.publicLibraryMargin)
                } footer: {
                    Text(localized("Project Gutenberg 的書在美國屬於公有領域；所在地區的著作權規定可能不同。"))
                        .dsSectionFooter().padding(.horizontal, DSLayout.publicLibraryMargin)
                }
            }
            .padding(.top, DSSpacing.xl)
            .padding(.bottom, DSSpacing.xxl)
        }
        .task { if includesAozora { await aozora.load() } }
        .refreshable { if includesAozora { await aozora.load(forceRefresh: true) } }
    }

    private func select(_ selection: PublicLibraryBookSelection) {
        openBooks?(selection)
    }

    private var featuredCollections: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                ForEach([PublicLibraryCollection.chinese, .fiction, .thought]) { collection in
                    NavigationLink(value: PublicLibraryRoute.collection(id: collection.id)) {
                        VStack(alignment: .leading, spacing: DSSpacing.lg) {
                            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                                Text(localized("Project Gutenberg")).font(DSFont.footnote.weight(.semibold))
                                Text(localized(collection.titleKey)).font(DSFont.title2.weight(.bold))
                            }.foregroundStyle(DSColor.textPrimary)
                            PublicLibraryCollectionArtwork(collection: collection)
                                .aspectRatio(DSLayout.publicLibraryFeaturedAspect, contentMode: .fit)
                        }.containerRelativeFrame(.horizontal)
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityIdentifier("publicLibrary.featured.\(collection.id)")
                }
            }.scrollTargetLayout()
        }
        .contentMargins(.horizontal, DSLayout.publicLibraryMargin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var curatedReading: some View {
        let books = (Array(PublicLibraryCollection.chinese.books.prefix(3)) + PublicLibraryCollection.fiction.books)
            .map(PublicLibraryBook.gutenberg)
        return VStack(alignment: .leading, spacing: DSSpacing.xl) {
            Text(localized("經典選讀")).font(DSFont.title2.weight(.bold))
                .foregroundStyle(DSColor.textPrimary).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, DSLayout.publicLibraryMargin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                    ForEach(Array(stride(from: 0, to: books.count, by: 3)), id: \.self) { start in
                        VStack(spacing: DSSpacing.lg) {
                            ForEach(Array(books[start..<min(start + 3, books.count)])) { book in
                                Button {
                                    coverFrames?.activeScope = Self.curatedScope
                                    PublicLibraryBookSelection(books: books, selectedID: book.id).map(select)
                                } label: {
                                    HStack(spacing: DSSpacing.lg) {
                                        PublicLibraryCover(title: book.title, author: book.author, coverURL: book.coverURL)
                                            .frame(width: DSLayout.discoverRowCoverWidth, height: DSLayout.discoverRowCoverHeight)
                                            .publicLibraryCoverFrame(id: book.id)
                                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                            Text(book.title).font(DSFont.headline).foregroundStyle(DSColor.textPrimary).lineLimit(2)
                                            Text(book.author).font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary).lineLimit(1)
                                            Text(localized("免費")).font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(ExploreTileButtonStyle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(book.title).accessibilityValue(book.author)
                            }
                        }.containerRelativeFrame(.horizontal)
                    }
                }.scrollTargetLayout()
            }
            .contentMargins(.horizontal, DSLayout.publicLibraryMargin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
            .environment(\.publicLibraryCoverScope, Self.curatedScope)
        }
    }
}

/// Aozora's front page, shown in place by the home's 範圍 (5c-3, 5d-1): 新着 and the three
/// indexes, as 分類 lists them.
struct AozoraHomePage: View {
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    var body: some View {
        List {
            if let index = aozora.catalog {
                Section {
                    ForEach(AozoraBrowseMode.allCases) { mode in
                        NavigationLink(value: PublicLibraryRoute.aozoraCatalog(mode, index)) {
                            Label(localized(mode.titleKey), systemImage: mode.symbol)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(.init(localized("書誌資料：青空文庫（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）")))
                        if case .failed = aozora.state { Text(localized("目錄更新失敗，仍顯示已儲存的目錄。")) }
                    }.dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
        }
        .overlay {
            if aozora.catalog == nil {
                if case .failed(let error, _) = aozora.state {
                    ContentUnavailableView {
                        UnavailableLabel(localized("青空文庫"), systemImage: "books.vertical")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button(localized("重試")) { Task { await aozora.load(forceRefresh: true) } }
                            .disabled(aozora.isRefreshing)
                    }
                } else {
                    ProgressView(localized("正在更新目錄"))
                }
            }
        }
        .task { await aozora.load() }
        .refreshable { await aozora.load(forceRefresh: true) }
        .navigationTitle(localized("青空文庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

private struct PublicLibraryCollectionArtwork: View {
    let collection: PublicLibraryCollection

    var body: some View {
        let books = Array(collection.books.prefix(CollectionSummary.artworkLimit))
        CollectionCoverArtwork(count: books.count) { index, _ in
            PublicLibraryCover(title: books[index].title, author: books[index].author, coverURL: books[index].coverURL)
        }
    }
}

/// A list's artwork: its first covers side by side, tilted, on a plain ground. The storefront's
/// 精選書單 drew it first; the home's 專題集合 (decision 37) draws it with the home's covers.
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

struct PublicLibraryShelf: View {
    let title: String
    let books: [PublicLibraryBook]
    let select: (PublicLibraryBookSelection) -> Void
    /// The page behind the shelf's title.
    let route: PublicLibraryRoute
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.publicLibraryCoverFrames) private var coverFrames

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            NavigationLink(value: route) {
                HStack(spacing: DSSpacing.sm) {
                    Text(title).font(DSFont.title2.weight(.bold))
                    Image(systemName: "chevron.right").font(DSFont.title3.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary).accessibilityHidden(true)
                }.foregroundStyle(DSColor.textPrimary)
            }.padding(.horizontal, DSLayout.publicLibraryMargin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                    ForEach(books) { book in
                        Button {
                            coverFrames?.activeScope = title
                            if let selection = PublicLibraryBookSelection(books: books, selectedID: book.id) { select(selection) }
                        } label: {
                            PublicLibraryBookCard(book: book, showsMetadata: false)
                                .containerRelativeFrame(.horizontal, count: textSize.isAccessibilitySize ? 1 : 2, spacing: DSSpacing.lg)
                        }
                        .buttonStyle(ExploreTileButtonStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(book.title).accessibilityValue(book.author)
                        .accessibilityIdentifier("publicLibrary.book.\(book.id)")
                    }
                }.scrollTargetLayout()
            }
            .contentMargins(.horizontal, DSLayout.publicLibraryMargin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
            .environment(\.publicLibraryCoverScope, title)
        }
    }
}

struct PublicLibraryCategoriesView: View {
    let index: AozoraCatalogIndex?
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    var body: some View {
        List {
            Section(localized("精選書單")) {
                ForEach(PublicLibraryCollection.all) { collection in
                    NavigationLink(localized(collection.titleKey), value: PublicLibraryRoute.collection(id: collection.id))
                }
            }.interfaceSectionSurface()
            Section(localized("Project Gutenberg")) {
                ForEach(GutenbergShelf.shelves(languages: aggregation.readingLanguages.languages)) { shelf in
                    NavigationLink(value: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                        url: shelf.url.absoluteString, title: shelf.title, presentation: .storefront)) {
                        Label(shelf.title, systemImage: shelf.symbol)
                    }
                }
            }.interfaceSectionSurface()
            if let index {
                Section(localized("青空文庫")) {
                    ForEach(AozoraBrowseMode.allCases) { mode in
                        NavigationLink(value: PublicLibraryRoute.aozoraCatalog(mode, index)) {
                            Label(localized(mode.titleKey), systemImage: mode.symbol)
                        }
                    }
                }.interfaceSectionSurface()
            }
        }
        .navigationTitle(localized("分類"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

#Preview("公有書庫分類選單") {
    NavigationStack {
        PublicLibraryCategoriesView(index: .preview).publicLibraryDestinations().remoteLibraryDestinations()
    }.environmentObject(BookStore())
}

#Preview("公有書庫") {
    NavigationStack {
        PublicLibraryStorefront(includesAozora: true).publicLibraryDestinations().remoteLibraryDestinations()
    }.environmentObject(BookStore())
}
