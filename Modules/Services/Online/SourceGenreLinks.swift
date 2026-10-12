import Combine
import Foundation

/// Where a genre under a book-source book's title leads (作品詳情 · Editorial Minimalism,
/// 2026-10-12): a genre the source also lists as one of its own explore categories opens that
/// category; any other genre searches the source for it, as legado does for a tapped label.
enum SourceGenreDestination: Equatable {
    case category(ExploreCategoryReference)
    case search(String)
}

/// Matching a book's genres against its source's explore categories. Only a category of the
/// same name counts: a genre the source does not list as a category gets no guessed one.
enum SourceGenreMatching {
    /// The category `tag` names, the first one when the source lists it under several groups.
    static func category(for tag: String, among items: [DiscoverCardItem]) -> DiscoverCardItem? {
        let key = normalized(tag)
        guard !key.isEmpty else { return nil }
        return items.first { $0.isFetchable && normalized($0.title) == key }
    }

    /// The first of `tags`, in their order, that names a category, with that category.
    static func firstCategory(
        for tags: [String], among items: [DiscoverCardItem]
    ) -> (tag: String, item: DiscoverCardItem)? {
        for tag in tags {
            if let item = category(for: tag, among: items) { return (tag, item) }
        }
        return nil
    }

    /// Case, character width and spacing set aside: 「ＡＢＣ 小說」 names the category 「abc小說」.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    /// A category's books without the one on the page, at most `limit`.
    static func related(
        _ displays: [DiscoverBookDisplay], excluding book: OnlineBook, limit: Int
    ) -> [DiscoverBookDisplay] {
        let url = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = normalized(book.name)
        let filtered = displays.filter { display in
            let other = display.book
            if !url.isEmpty, other.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines) == url { return false }
            return name.isEmpty || normalized(other.name) != name
        }
        return Array(filtered.prefix(limit))
    }
}

/// One detail page's genre links and its 同題材 section, both read from the book's source.
///
/// The source's categories are read through `BookSourceFetcher.discoverItems`, the path its
/// own discover page reads them by, once per page and source; a genre tapped while they are
/// still arriving waits for them. 同題材 is the first page of the first genre's category,
/// through `SectionPageLoader`, the one loader of a category's pages. No cache of its own.
@MainActor
final class SourceGenreLinks: ObservableObject {
    enum Related: Equatable {
        /// No genre names a category of the source, or that category has no other book.
        case hidden
        case loading(ExploreCategoryReference)
        /// The category's books as a section, with the source's cover context.
        case loaded(ExploreCategoryReference, DiscoverShowcaseSection)
        case failed(ExploreCategoryReference, String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.hidden, .hidden): return true
            case let (.loading(a), .loading(b)): return a == b
            case let (.loaded(a, x), .loaded(b, y)): return a == b && x.books.map(\.id) == y.books.map(\.id)
            case let (.failed(a, x), .failed(b, y)): return a == b && x == y
            default: return false
            }
        }
    }

    /// How many books 同題材 shows.
    static let relatedLimit = 12

    @Published private(set) var related: Related = .hidden

    typealias LoadCategories = @Sendable (BookSource) async -> [ModernParserBridge.DiscoverItem]
    typealias PrimeCookies = @Sendable (BookSource) async -> Void

    private let loadCategories: LoadCategories
    private let primeCookies: PrimeCookies
    private let pageLoader: SectionPageLoader
    private var categories: Task<[DiscoverCardItem], Never>?
    private var categoriesSource: String?
    /// The page's last finished load; the same one is not run again when the page reappears.
    private var loadedKey: String?

    init(
        loadCategories: @escaping LoadCategories = {
            await BookSourceFetcher.shared.discoverItems(page: 1, in: $0, variableOverlay: [:])
        },
        primeCookies: @escaping PrimeCookies = {
            await BookSourceFetcher.shared.primeDiscoverCookies(in: $0)
        },
        pageLoader: SectionPageLoader = .live
    ) {
        self.loadCategories = loadCategories
        self.primeCookies = primeCookies
        self.pageLoader = pageLoader
    }

    /// `source`'s categories, read once for the page. Not cancelled with the page's task: the
    /// genre taps and the page's return from its reader read the same list.
    private func categories(of source: BookSource) -> Task<[DiscoverCardItem], Never> {
        if let categories, categoriesSource == source.bookSourceUrl { return categories }
        let loadCategories = loadCategories
        let primeCookies = primeCookies
        let task = Task {
            // Some sources' categories read a site cookie only browsing sets (起点 _csrfToken),
            // as the source's own discover page primes before it lists them.
            await primeCookies(source)
            let started = SourcePerfTrace.now
            let raw = await loadCategories(source)
            let items = raw.compactMap(DiscoverViewModel.mapItem).filter(\.isFetchable)
            SourcePerfTrace.record("detail.genre.categories", "items=\(items.count)",
                                   since: started, thresholdMs: 0)
            return items
        }
        categories = task
        categoriesSource = source.bookSourceUrl
        return task
    }

    /// Reads `source`'s categories and loads 同題材 for `book`. A page calls it from
    /// `.task(id: key)`, `key` naming the source, the genres and the book. A load already
    /// finished under `key` is kept, as the page returning from its reader finds it.
    func load(key: String, source: BookSource?, tags: [String], book: OnlineBook) async {
        guard key != loadedKey else { return }
        related = .hidden
        guard let source else {
            loadedKey = key
            return
        }
        let items = await categories(of: source).value
        guard !Task.isCancelled else { return }
        guard let match = SourceGenreMatching.firstCategory(for: tags, among: items),
              let reference = ExploreCategoryReference(source: source, item: match.item)
        else {
            loadedKey = key
            return
        }

        related = .loading(reference)
        var section = DiscoverShowcaseSection(
            item: match.item, coverBaseURL: source.bookSourceUrl, coverHeaders: source.parsedHeaders
        )
        let started = SourcePerfTrace.now
        do {
            let displays = try await pageLoader.books(page: 1, of: section, in: source, after: [])
            guard !Task.isCancelled else { return }
            let shown = SourceGenreMatching.related(displays, excluding: book, limit: Self.relatedLimit)
            SourcePerfTrace.record("detail.genre.related", "category=\(reference.title) books=\(shown.count)",
                                   since: started, thresholdMs: 0)
            section.books = shown
            section.phase = .loaded
            related = shown.isEmpty ? .hidden : .loaded(reference, section)
        } catch {
            // `SectionPageLoader` has logged the failure.
            guard !Task.isCancelled else { return }
            related = .failed(reference, error.localizedDescription)
        }
        loadedKey = key
    }

    /// Loads 同題材 again after it failed.
    func retryRelated(key: String, source: BookSource?, tags: [String], book: OnlineBook) async {
        loadedKey = nil
        await load(key: key, source: source, tags: tags, book: book)
    }

    /// Where tapping `tag` leads: the source's category of that name, once its categories have
    /// arrived, or a search of the source.
    func destination(for tag: String, in source: BookSource?) async -> SourceGenreDestination {
        guard let source else { return .search(tag) }
        guard let item = SourceGenreMatching.category(for: tag, among: await categories(of: source).value),
              let reference = ExploreCategoryReference(source: source, item: item)
        else { return .search(tag) }
        return .category(reference)
    }
}
