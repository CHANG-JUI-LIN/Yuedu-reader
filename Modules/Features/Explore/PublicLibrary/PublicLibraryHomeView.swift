import SwiftUI

struct PublicLibraryHomeView: View {
    var modeMenu: ExploreModeMenu? = nil
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var selection: PublicLibraryBookSelection?
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trimmedQuery.isEmpty {
                    storefront
                } else {
                    List {
                        PublicLibrarySearchResults(query: trimmedQuery, index: aozora.catalog,
                            submitGutenberg: submitSearch, select: { selection = $0 })
                    }.listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: localized("搜尋公有書庫"))
            .onSubmit(of: .search, submitSearch)
            .task { await aozora.load() }
            .refreshable { await aozora.load(forceRefresh: true) }
            .navigationDestination(for: OPDSFeedRoute.self) { PublicLibraryFeedView(route: $0) }
            .rootTabSearchScrollEdges()
            .themedAppSurface(for: .explore)
            .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { PublicLibraryCategoriesView(index: aozora.catalog) } label: {
                        Text(localized("分類"))
                    }.accessibilityIdentifier("publicLibrary.categories")
                }
                if let modeMenu {
                    ToolbarItem(placement: .topBarTrailing) { modeMenu }
                }
            }
            .sheet(item: $selection) { PublicLibraryBookSheet(selection: $0) }
        }
    }

    private var storefront: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSLayout.publicLibrarySectionSpacing) {
                featuredCollections.rootTabTitleScrollAnchor()
                ForEach([PublicLibraryCollection.chinese, .fiction]) { collection in
                    PublicLibraryShelf(title: localized(collection.titleKey),
                        books: collection.books.map(PublicLibraryBook.gutenberg), select: { selection = $0 }) {
                        PublicLibraryCollectionView(collection: collection)
                    }
                }
                curatedReading
                ForEach([PublicLibraryCollection.children, .thought]) { collection in
                    PublicLibraryShelf(title: localized(collection.titleKey),
                        books: collection.books.map(PublicLibraryBook.gutenberg), select: { selection = $0 }) {
                        PublicLibraryCollectionView(collection: collection)
                    }
                }
                if let index = aozora.catalog {
                    Section {
                        PublicLibraryShelf(title: localized("青空文庫"),
                            books: Array(index.newWorks.prefix(12)).map { .aozora($0, index) }, select: { selection = $0 }) {
                            AozoraWorksView(index: index, works: index.newWorks, title: localized("新着作品"))
                        }
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
                    NavigationLink { PublicLibraryCategoriesView(index: aozora.catalog) } label: {
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
    }

    private var featuredCollections: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                ForEach([PublicLibraryCollection.chinese, .fiction, .thought]) { collection in
                    NavigationLink { PublicLibraryCollectionView(collection: collection) } label: {
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
                                    selection = PublicLibraryBookSelection(books: books, selectedID: book.id)
                                } label: {
                                    HStack(spacing: DSSpacing.lg) {
                                        PublicLibraryCover(title: book.title, author: book.author)
                                            .frame(width: DSLayout.discoverRowCoverWidth, height: DSLayout.discoverRowCoverHeight)
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
        }
    }

    private func submitSearch() {
        guard !trimmedQuery.isEmpty else { return }
        path.append(OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
            url: PublicLibrary.gutenbergSearchURL(query: trimmedQuery).absoluteString,
            title: String(trimmedQuery.prefix(500))))
    }
}

private struct PublicLibraryCollectionArtwork: View {
    let collection: PublicLibraryCollection

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: DSSpacing.lg) {
                ForEach(Array(collection.books.prefix(3))) { book in
                    PublicLibraryCover(title: book.title, author: book.author)
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

struct PublicLibraryShelf<Destination: View>: View {
    let title: String
    let books: [PublicLibraryBook]
    let select: (PublicLibraryBookSelection) -> Void
    @ViewBuilder let destination: () -> Destination
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            NavigationLink(destination: destination) {
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
        }
    }
}

struct PublicLibraryCategoriesView: View {
    let index: AozoraCatalogIndex?
    var body: some View {
        List {
            Section(localized("精選書單")) {
                ForEach(PublicLibraryCollection.all) { collection in
                    NavigationLink(localized(collection.titleKey)) { PublicLibraryCollectionView(collection: collection) }
                }
            }.interfaceSectionSurface()
            Section(localized("Project Gutenberg")) {
                ForEach(GutenbergShelf.shelves(language: Bundle.main.preferredLocalizations.first ?? "en")) { shelf in
                    NavigationLink {
                        PublicLibraryFeedView(route: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                            url: shelf.url.absoluteString, title: localized(shelf.titleKey)))
                    } label: { Label(localized(shelf.titleKey), systemImage: shelf.symbol) }
                }
            }.interfaceSectionSurface()
            if let index {
                Section(localized("青空文庫")) {
                    ForEach(AozoraBrowseMode.allCases) { mode in
                        NavigationLink { AozoraCatalogView(index: index, mode: mode) } label: {
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

#Preview { PublicLibraryHomeView().environmentObject(BookStore()) }
#Preview("公有書庫分類選單") { NavigationStack { PublicLibraryCategoriesView(index: .preview) } }
