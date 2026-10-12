import SwiftUI

/// 作者其他作品 at the foot of 作品詳情: the author's other works as a shelf of covers, drawn as
/// Explore's home draws a row of them. Not shown when the version's data names no other work
/// (`AuthorWorksModel.State.hidden`).
struct BookDetailAuthorWorksSection: View {
    let state: AuthorWorksModel.State
    /// The author's page, for the libraries that have one.
    let onShowAll: (() -> Void)?
    let onSelect: (WorkDetailRoute) -> Void
    let onRetry: () -> Void
    @EnvironmentObject private var store: BookStore

    var body: some View {
        if state != .hidden {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(
                    title: localized("作者其他作品"),
                    actionTitle: onShowAll == nil ? nil : localized("查看全部"),
                    action: onShowAll
                )
                .padding(.horizontal, DSSpacing.lg)
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loaded(let entries):
            shelf(HomeRowContent(entries: entries, store: store).cards)
        case .failed:
            Button(action: onRetry) {
                Label(localized("載入失敗，點按重試"), systemImage: "arrow.clockwise")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.accent)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.discoverShelfCoverHeight)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DSSpacing.lg)
        case .loading, .hidden:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: DSLayout.discoverShelfCoverHeight)
        }
    }

    private func shelf(_ cards: [HomeCardContent]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                // By position: a source can list one item twice.
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    if let route = card.route {
                        Button { onSelect(route) } label: {
                            HomeBookCard(content: card, coverWidth: DSLayout.discoverShelfCoverWidth)
                        }
                        .buttonStyle(ExploreTileButtonStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(card.accessibilityLabel)
                        .accessibilityValue(card.accessibilityValue)
                        .accessibilityIdentifier("detail.authorWorks.book")
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

/// A public library's author page pushed from 作品詳情: a book on it opens that book's 作品詳情
/// on top, keeping the author's page to come back to.
struct WorkDetailAuthorPage: View {
    let destination: PublicLibraryAuthorDestination
    @EnvironmentObject private var store: BookStore
    @State private var pushedWork: WorkDetailRoute?

    var body: some View {
        PublicLibraryAuthorPage(destination: destination)
            .environment(\.openPublicLibraryBooks) { selection in
                if let book = selection.selectedBook { pushedWork = WorkDetailRoute(book) }
            }
            .navigationDestination(item: $pushedWork) { route in
                WorkDetailView(route: route).environmentObject(store)
            }
    }
}

/// An author's page in a public library: Gutenberg's feed of their books, or 青空文庫's list of
/// their works. A book on it opens through `openPublicLibraryBooks`, as the page's host sets it.
struct PublicLibraryAuthorPage: View {
    let destination: PublicLibraryAuthorDestination

    var body: some View {
        switch destination {
        case .gutenberg(let author):
            PublicLibraryFeedView(route: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                url: author.url.absoluteString, title: author.name, presentation: .storefront))
        case .aozora(let author, let index):
            AozoraWorksView(index: index, works: index.works(forPerson: author.id), title: author.name)
        }
    }
}

#Preview("作者其他作品") {
    let index = AozoraCatalogIndex.preview
    let entries = index.newWorks.map { CollectionEntry.aozora($0, index: index) }
    return ScrollView {
        VStack(spacing: DSSpacing.xl) {
            BookDetailAuthorWorksSection(state: .loaded(entries), onShowAll: {}, onSelect: { _ in }, onRetry: {})
            BookDetailAuthorWorksSection(state: .loading, onShowAll: nil, onSelect: { _ in }, onRetry: {})
            BookDetailAuthorWorksSection(state: .failed("timeout"), onShowAll: {}, onSelect: { _ in }, onRetry: {})
        }
    }
    .environmentObject(BookStore())
}
