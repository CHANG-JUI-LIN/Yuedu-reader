import SwiftUI

// MARK: - Detail page per selected source kind

/// The online-book detail page that matches the content kind of the source the
/// user has selected.
///
/// Legado (original, legado-E and MD3 alike) hands a changed source's type to the
/// book: `SearchBook.toBook()` carries the new source's `type`, and the read action
/// branches on that type. Yuedu has one detail page per kind — `AudiobookDetailView`
/// for audio, `OnlineBookView` for everything else — so here the kind picks the
/// page. Switching an audiobook detail to a text source replaces it with the text
/// detail, and switching a text detail to an audio source does the reverse; the
/// page was previously fixed by the source that happened to open it.
struct OnlineBookDetailDestination: View {
    enum Entry {
        /// Aggregated search result; the pages switch among its origins.
        case search(SearchBook)
        /// Single-source book (Discover, bookshelf); the pages switch through a source search.
        case book(OnlineBook)
    }

    private let entry: Entry
    private let onRemoveFromShelf: (() -> Void)?
    /// On 作品詳情, the work's versions, which 換源 lists first (unified library 5f-3).
    private let workVersions: BookDetailInfoChoice?
    /// The bookshelf's reader coordinator, given to the text page only: its reader
    /// opens through the coordinator, while the audiobook page's player does not.
    private let textPageReaderNavigator: ReaderNavigationCoordinator?
    @Environment(\.readerNavigator) private var inheritedReaderNavigator

    /// The origin selected across a kind change. `nil` until the first such change,
    /// so the entry opens on each page's own default origin.
    @State private var switchedOrigin: BookOrigin?
    @State private var showsAudioPage: Bool

    init(
        _ entry: Entry,
        onRemoveFromShelf: (() -> Void)? = nil,
        textPageReaderNavigator: ReaderNavigationCoordinator? = nil,
        workVersions: BookDetailInfoChoice? = nil
    ) {
        self.entry = entry
        self.onRemoveFromShelf = onRemoveFromShelf
        self.workVersions = workVersions
        self.textPageReaderNavigator = textPageReaderNavigator
        let isAudio: Bool
        switch entry {
        case .search(let searchBook):
            isAudio = BookSourceStore.shared.isAudiobook(searchBook)
        case .book(let book):
            isAudio = BookSourceStore.shared.isAudiobook(book)
        }
        _showsAudioPage = State(initialValue: isAudio)
    }

    var body: some View {
        page
            // A kind change is a different page for a different source; nothing in
            // the previous page's state carries over.
            .id(switchedOrigin?.id)
    }

    @ViewBuilder
    private var page: some View {
        switch entry {
        case .search(let searchBook):
            if showsAudioPage {
                AudiobookDetailView(
                    searchBook: searchBook,
                    initialOrigin: switchedOrigin,
                    onRemoveFromShelf: onRemoveFromShelf,
                    onSourceKindChange: switchPage
                )
            } else {
                OnlineBookView(
                    searchBook: searchBook,
                    initialOrigin: switchedOrigin,
                    onRemoveFromShelf: onRemoveFromShelf,
                    onSourceKindChange: switchPage
                )
                .environment(\.readerNavigator, textPageReaderNavigator ?? inheritedReaderNavigator)
            }
        case .book(let book):
            let shown = switchedOrigin.map {
                OnlineBook(detailOrigin: $0, name: book.name, author: book.author)
            } ?? book
            if showsAudioPage {
                AudiobookDetailView(
                    book: shown,
                    onRemoveFromShelf: onRemoveFromShelf,
                    onSourceKindChange: switchPage,
                    workVersions: workVersions
                )
            } else {
                OnlineBookView(
                    book: shown,
                    onRemoveFromShelf: onRemoveFromShelf,
                    onSourceKindChange: switchPage,
                    workVersions: workVersions
                )
                .environment(\.readerNavigator, textPageReaderNavigator ?? inheritedReaderNavigator)
            }
        }
    }

    private func switchPage(to origin: BookOrigin) {
        showsAudioPage = DetailSourceKind.kind(of: origin, in: searchBook) == .audio
        switchedOrigin = origin
    }

    private var searchBook: SearchBook? {
        if case .search(let searchBook) = entry { return searchBook }
        return nil
    }
}

// MARK: - Source kind

/// Content kind of a detail page's book and of the origins it can switch to.
///
/// A search result's kinds were snapshotted when its origins arrived (see
/// `SearchBook.inferredContentKind`), so they are read from that snapshot; origins
/// from a source search are inferred the same way the search snapshot was built.
enum DetailSourceKind {
    static func kind(of origin: BookOrigin, in searchBook: SearchBook?) -> OnlineBookContentKind {
        searchBook?.contentKind(for: origin) ?? origin.inferredContentKind()
    }

    static func kind(of book: OnlineBook, in searchBook: SearchBook?) -> OnlineBookContentKind {
        if let searchBook,
           let origin = searchBook.origins.first(where: {
               $0.sourceId == book.sourceId && $0.bookUrl == book.bookUrl
           }),
           let kind = searchBook.contentKind(for: origin) {
            return kind
        }
        let source = BookSourceStore.shared.source(id: book.sourceId)
        return book.inferredContentKind(source: source)
    }
}

// MARK: - Kind-mismatch confirmation

extension View {
    /// Legado's `book_type_different` prompt: switching to a source of another book
    /// type asks first, and switches only on confirmation.
    func sourceKindMismatchAlert(
        origin: Binding<BookOrigin?>,
        onConfirm: @escaping (BookOrigin) -> Void
    ) -> some View {
        alert(
            localized("書籍類型不一樣"),
            isPresented: Binding(
                get: { origin.wrappedValue != nil },
                set: { if !$0 { origin.wrappedValue = nil } }
            ),
            presenting: origin.wrappedValue
        ) { pending in
            Button(localized("取消"), role: .cancel) {}
            Button(localized("確定")) { onConfirm(pending) }
        } message: { _ in
            Text(localized("是否確認換源"))
        }
    }
}

// MARK: - Detail book from an origin

extension OnlineBook {
    /// Detail-page book for one origin of a search result.
    init(detailOrigin origin: BookOrigin, in searchBook: SearchBook) {
        let selectedIntro = searchBook.detailIntro(for: origin)
        self.init(
            id: SearchResultDetailIdentity.onlineBookID(
                searchBookID: searchBook.id,
                originID: origin.id
            ),
            name: searchBook.name,
            author: searchBook.author,
            intro: selectedIntro.isEmpty ? searchBook.detailIntro : selectedIntro,
            coverUrl: origin.coverUrl.isEmpty ? searchBook.coverUrl : origin.coverUrl,
            bookUrl: origin.bookUrl,
            tocUrl: origin.tocUrl,
            wordCount: origin.wordCount,
            lastChapter: origin.lastChapter,
            kind: origin.kind,
            sourceId: origin.sourceId,
            sourceName: origin.sourceName,
            runtimeVariables: origin.runtimeVariables
        )
    }

    /// Detail-page book for an origin found by a source search.
    init(detailOrigin origin: BookOrigin, name: String, author: String) {
        self.init(
            name: name,
            author: author,
            intro: OnlineBookDetailPresentationPolicy.sanitizeIntro(origin.intro),
            coverUrl: origin.coverUrl,
            bookUrl: origin.bookUrl,
            tocUrl: origin.tocUrl,
            wordCount: origin.wordCount,
            lastChapter: origin.lastChapter,
            kind: origin.kind,
            sourceId: origin.sourceId,
            sourceName: origin.sourceName,
            runtimeVariables: origin.runtimeVariables
        )
    }
}

#Preview {
    NavigationStack {
        OnlineBookDetailDestination(.search(SearchBook(
            name: "斗羅大陸",
            author: "唐家三少",
            origins: [
                BookOrigin(
                    sourceId: UUID(), sourceName: "示範小說源",
                    bookUrl: "https://example.com/book/1", tocUrl: "https://example.com/book/1/toc",
                    coverUrl: "", intro: "唐門外門弟子唐三，跳崖明志卻來到了另一個世界——斗羅大陸。",
                    lastChapter: "第一章", wordCount: "", kind: "玄幻", runtimeVariables: nil
                )
            ]
        )))
        .environmentObject(BookStore())
    }
}
