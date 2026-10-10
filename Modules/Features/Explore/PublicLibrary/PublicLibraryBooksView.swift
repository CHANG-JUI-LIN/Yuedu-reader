import SwiftUI

/// Local artwork is the store's deliberate cover treatment. It never starts a
/// remote cover request and stays identical from a shelf into its detail sheet.
struct PublicLibraryCover: View {
    let title: String
    let author: String

    var body: some View {
        GeneratedBookCover(title: title, author: author)
            .aspectRatio(DSLayout.discoverCoverAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.searchListCover))
            .shadow(color: DSColor.coverHeroShadow, radius: DSLayout.bookCoverHeroShadowRadius,
                    y: DSLayout.bookCoverHeroShadowOffsetY)
            .accessibilityHidden(true)
    }
}

struct PublicLibraryBookCard: View {
    let book: PublicLibraryBook
    var showsMetadata = true
    /// 已加入書架 or 已下載 (unified library 2c), shown where the price line would be.
    var status: CopyLookup.Status? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            PublicLibraryCover(title: book.title, author: book.author)
                .publicLibraryCoverFrame(id: book.id)
                .padding(.bottom, DSSpacing.sm)
            if showsMetadata {
                Text(book.title).font(DSFont.headline).foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                Text(book.author).font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1, reservesSpace: true)
                Text(status?.title ?? localized("免費"))
                    .font(DSFont.caption.weight(.semibold)).foregroundStyle(DSColor.textPrimary)
            }
        }
    }
}

struct PublicLibraryBooksGrid: View {
    let books: [PublicLibraryBook]
    let select: (PublicLibraryBookSelection) -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var minimumWidth = DSLayout.publicLibraryMinimumCoverWidth
    @Environment(\.publicLibraryCoverFrames) private var coverFrames
    @EnvironmentObject private var store: BookStore
    private static let scope = "grid"

    private var columns: [GridItem] {
        textSize.isAccessibilitySize ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: minimumWidth), spacing: DSSpacing.lg, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpacing.xl) {
            ForEach(books) { book in
                let status = store.copyLookup().status(for: book.sourceItemKey)
                Button {
                    coverFrames?.activeScope = Self.scope
                    if let selection = PublicLibraryBookSelection(books: books, selectedID: book.id) { select(selection) }
                } label: { PublicLibraryBookCard(book: book, status: status) }
                .buttonStyle(ExploreTileButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(book.title)
                .accessibilityValue([book.author, status?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                .accessibilityIdentifier("publicLibrary.book.\(book.id)")
            }
        }
        .padding(.horizontal, DSLayout.publicLibraryMargin)
        .padding(.vertical, DSSpacing.lg)
        .environment(\.publicLibraryCoverScope, Self.scope)
    }
}

struct PublicLibraryCollectionView: View {
    let collection: PublicLibraryCollection
    @Environment(\.openPublicLibraryBooks) private var openBooks

    var body: some View {
        ScrollView {
            PublicLibraryBooksGrid(books: collection.books.map(PublicLibraryBook.gutenberg)) { openBooks?($0) }
        }
        .softScrollEdges()
        .navigationTitle(localized(collection.titleKey))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

/// A Gutenberg category, submitted search or author's own catalog. It uses the
/// same browse model as the existing OPDS list and never loads the next page itself.
struct PublicLibraryFeedView: View {
    let route: OPDSFeedRoute
    @StateObject private var model: OPDSBrowseModel
    @Environment(\.openPublicLibraryBooks) private var openBooks
    @State private var query = ""
    @State private var request: Task<Void, Never>?

    init(route: OPDSFeedRoute) {
        self.route = route
        _model = StateObject(wrappedValue: OPDSBrowseModel(route: route))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DSSpacing.lg) {
                if !model.entries.isEmpty {
                    PublicLibraryBooksGrid(books: model.entries.compactMap(GutenbergBook.init(entry:)).map(PublicLibraryBook.gutenberg)) {
                        openBooks?($0)
                    }
                }
                if let error = model.loadError {
                    ContentUnavailableView {
                        UnavailableLabel(localized("無法載入書庫"), systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button(localized("重試")) {
                            request = Task {
                                if model.failedWhileLoadingMore { await model.loadMore() }
                                else { await model.load(query: query) }
                            }
                        }.disabled(model.isLoading || model.isLoadingMore)
                    }
                } else if model.isLoading {
                    ProgressView(localized("正在載入書庫"))
                        .frame(maxWidth: .infinity).padding(.vertical, DSSpacing.xxl)
                } else if model.didLoad && model.entries.isEmpty {
                    ContentUnavailableView(localized("此目錄沒有內容"), systemImage: "books.vertical")
                }
                if model.nextPageURL != nil {
                    Button { request = Task { await model.loadMore() } } label: {
                        if model.isLoadingMore { ProgressView() }
                        else { Text(localized("載入更多")) }
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(model.isLoading || model.isLoadingMore)
                }
            }
            .padding(.bottom, DSSpacing.xxl)
        }
        .softScrollEdges()
        .navigationTitle(route.title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .searchable(text: $query, prompt: localized("搜尋此目錄"))
        .onSubmit(of: .search) {
            request?.cancel()
            request = Task { await model.load(query: query) }
        }
        .submitScope()
        .task { if !model.didLoad { await model.load() } }
        .onDisappear { request?.cancel() }
    }
}

#Preview("公有書庫雙欄書架") {
    NavigationStack { PublicLibraryCollectionView(collection: .chinese) }.environmentObject(BookStore())
}

#Preview("公有書庫分類") {
    NavigationStack {
        PublicLibraryFeedView(route: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
            url: PublicLibrary.gutenbergSearchURL(query: "l.zh").absoluteString, title: localized("中文書籍")))
    }.environmentObject(BookStore())
}

#Preview("書卡狀態") {
    HStack(alignment: .top, spacing: DSSpacing.lg) {
        ForEach([nil, CopyLookup.Status.onShelf, .downloaded], id: \.self) { status in
            PublicLibraryBookCard(book: .gutenberg(GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Jane Austen")),
                                  status: status)
                .frame(width: 120)
        }
    }
    .padding()
}
