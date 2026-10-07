import SwiftUI

struct PublicLibrarySheetContext {
    let artworkHeight: CGFloat
    let openReader: (UUID) -> Void
    let openAuthor: (PublicLibraryAuthorDestination) -> Void
}
private struct PublicLibrarySheetContextKey: EnvironmentKey {
    static let defaultValue: PublicLibrarySheetContext? = nil
}
extension EnvironmentValues {
    var publicLibrarySheet: PublicLibrarySheetContext? {
        get { self[PublicLibrarySheetContextKey.self] }
        set { self[PublicLibrarySheetContextKey.self] = newValue }
    }
}

/// UIKit owns the detent pan, velocity, interruption and rubber-banding through
/// SwiftUI's native sheet. The perpendicular native scroll view owns paging.
/// There is no competing vertical DragGesture or timer-driven handoff.
struct PublicLibraryBookSheet: View {
    let selection: PublicLibraryBookSelection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detent = PresentationDetent.medium
    @State private var selectedID: String?
    @State private var path = NavigationPath()
    @State private var readerBookID: UUID?
    @EnvironmentObject private var store: BookStore

    init(selection: PublicLibraryBookSelection) {
        self.selection = selection
        _selectedID = State(initialValue: selection.selectedID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: DSSpacing.md) {
                        ForEach(selection.books) { book in
                            PublicLibraryDetailPage(book: book, isSelected: selectedID == book.id)
                                .accessibilityHidden(selectedID != book.id)
                                .containerRelativeFrame(.horizontal) { width, _ in width - DSSpacing.md }
                                .frame(height: proxy.size.height)
                                .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
                                .id(book.id)
                        }
                    }.scrollTargetLayout()
                }
                .contentMargins(.horizontal, DSSpacing.md, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                // Equal-width pages let the native initial anchor place the
                // chosen book before the lazy sheet has laid out its children.
                .defaultScrollAnchor(initialAnchor)
                .scrollPosition(id: $selectedID, anchor: .center)
                .scrollIndicators(.hidden)
                .environment(\.publicLibrarySheet, PublicLibrarySheetContext(
                    artworkHeight: min(DSLayout.publicLibraryExpandedCoverHeight,
                        max(DSLayout.publicLibraryCompactCoverHeight, proxy.size.height - DSLayout.publicLibrarySheetChromeAllowance)),
                    openReader: { id in expandAndNavigate { readerBookID = id } },
                    openAuthor: { author in expandAndNavigate { path.append(author) } }))
                .accessibilityIdentifier("publicLibrary.carousel")
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label(localized("關閉"), systemImage: "xmark").labelStyle(.iconOnly)
                    }.accessibilityIdentifier("publicLibrary.closeSheet")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { resize(to: detent == .large ? .medium : .large) } label: {
                        Label(localized(detent == .large ? "還原為半螢幕" : "展開為全螢幕"),
                              systemImage: detent == .large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("publicLibrary.resizeSheet")
                    .accessibilityLabel(localized(detent == .large ? "還原為半螢幕" : "展開為全螢幕"))
                }
            }
            .navigationDestination(item: $readerBookID) { id in
                BookReaderView(bookId: id).environmentObject(store)
                    .environment(\.readerNavigator, nil)
                    .environment(\.readerUsesParentNavigationStack, true)
                    .navigationBarBackButtonHidden(true)
                    .reservingNavigationBackSwipe()
            }
            .navigationDestination(for: OPDSFeedRoute.self) { PublicLibraryFeedView(route: $0) }
            .navigationDestination(for: PublicLibraryAuthorDestination.self) { destination in
                Group {
                    switch destination {
                    case .gutenberg(let author):
                        PublicLibraryFeedView(route: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                            url: author.url.absoluteString, title: author.name))
                    case .aozora(let author, let index):
                        AozoraWorksView(index: index, works: index.works(forPerson: author.id), title: author.name)
                    }
                }
            }
        }
        .presentationDetents(path.isEmpty && readerBookID == nil ? [.medium, .large] : [.large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .presentationBackground(DSColor.background)
        .themedAppSurface(for: .explore)
    }

    private var initialAnchor: UnitPoint {
        let index = selection.books.prefix { $0.id != selection.selectedID }.count
        return UnitPoint(x: CGFloat(index) / CGFloat(max(selection.books.count - 1, 1)), y: 0)
    }

    private func expandAndNavigate(_ navigate: @escaping () -> Void) {
        guard detent != .large else { navigate(); return }
        // A simultaneous detent change and navigation push leaves UIKit at its
        // old height even though the binding already says .large. Commit the
        // resize transaction before pushing; use animation completion, not a delay.
        withAnimation(reduceMotion ? nil : DSAnimation.standard, completionCriteria: .removed) {
            detent = .large
        } completion: {
            navigate()
        }
    }

    private func resize(to value: PresentationDetent) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) { detent = value }
    }
}

private struct PublicLibraryDetailPage: View {
    let book: PublicLibraryBook
    let isSelected: Bool

    var body: some View {
        switch book {
        case .gutenberg(let book): GutenbergBookDetailPage(book: book, isSelected: isSelected)
        case .aozora(let work, let index):
            AozoraWorkDetailView(work: work, index: index)
        }
    }
}

private struct GutenbergBookDetailPage: View {
    let book: GutenbergBook
    let isSelected: Bool
    @StateObject private var model: GutenbergBookPageModel
    @Environment(\.publicLibrarySheet) private var sheet

    init(book: GutenbergBook, isSelected: Bool) {
        self.book = book
        self.isSelected = isSelected
        _model = StateObject(wrappedValue: GutenbergBookPageModel(book: book))
    }

    var body: some View {
        Group {
            if let detail = model.detail, isSelected {
                RemoteLibraryBookDetailView(item: detail.item, storefront: true, authors: detail.authors,
                                            artworkTitle: book.title, artworkAuthor: book.author)
            } else {
                ScrollView {
                    VStack(spacing: DSSpacing.lg) {
                        PublicLibraryCover(title: book.title, author: book.author)
                            .frame(height: sheet?.artworkHeight ?? DSLayout.bookCoverHeroHeight)
                        Text(book.title).font(DSFont.title2.weight(.bold)).foregroundStyle(DSColor.textPrimary)
                        Text(book.author).font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary)
                        if model.isLoading { ProgressView(localized("正在載入書庫")) }
                        if let error = model.errorMessage, isSelected {
                            Text(error).foregroundStyle(DSColor.textSecondary)
                            Button(localized("重試")) { Task { await model.load(force: true) } }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DSSpacing.lg)
                }
            }
        }
        .task(id: isSelected) { if isSelected { await model.load() } }
    }
}

#Preview("可調整大小的書籍輪播") {
    PublicLibraryBookSheet(selection: PublicLibraryBookSelection(
        books: PublicLibraryCollection.chinese.books.map(PublicLibraryBook.gutenberg),
        selectedID: PublicLibraryBook.gutenberg(PublicLibraryCollection.chinese.books[0]).id)!)
        .environmentObject(BookStore())
}
