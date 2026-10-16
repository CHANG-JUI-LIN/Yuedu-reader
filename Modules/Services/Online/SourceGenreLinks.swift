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

    /// The categories the book's genres name, in the genres' order, each once.
    static func matchedCategories(for tags: [String], among items: [DiscoverCardItem]) -> [DiscoverCardItem] {
        var seen = Set<String>()
        return tags.compactMap { category(for: $0, among: items) }
            .filter { seen.insert(normalized($0.title)).inserted }
    }

    /// The category 同題材 reads (`RelatedCategoryChoiceStore`): the one picked for the book
    /// from 其他分類 while the source still lists it; else the genre picked latest for the
    /// source among those the book's genres name; else the first of those.
    static func relatedCategory(
        for tags: [String], among items: [DiscoverCardItem], preferred: [String], bookPick: String?
    ) -> DiscoverCardItem? {
        if let bookPick, let item = category(for: bookPick, among: items) { return item }
        let matched = matchedCategories(for: tags, among: items)
        let ranks = Dictionary(preferred.enumerated().map { (normalized($0.element), $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        return matched.min { (ranks[normalized($0.title)] ?? .max) < (ranks[normalized($1.title)] ?? .max) }
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

/// What 同題材's menu offers: the categories the book's genres name, in the genres' order,
/// then the source's other categories, each once.
struct RelatedCategoryChoices: Equatable {
    var matched: [String]
    var others: [String]
    var current: String

    init(matched: [String], others: [String], current: String) {
        self.matched = matched
        self.others = others
        self.current = current
    }

    init(tags: [String], items: [DiscoverCardItem], current: String) {
        let matched = SourceGenreMatching.matchedCategories(for: tags, among: items).map(\.title)
        var seen = Set(matched.map(SourceGenreMatching.normalized))
        let others = items.filter { $0.isFetchable && seen.insert(SourceGenreMatching.normalized($0.title)).inserted }
            .map(\.title)
        self.init(matched: matched, others: others, current: current)
    }

    /// The menu shows only when there is something to pick.
    var offersChoice: Bool { matched.count + others.count > 1 }
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
    /// What the section's menu offers; nil while 同題材 is hidden.
    @Published private(set) var choices: RelatedCategoryChoices?

    typealias LoadCategories = @Sendable (BookSource) async -> [ModernParserBridge.DiscoverItem]
    typealias PrimeCookies = @Sendable (BookSource) async -> Void

    private let loadCategories: LoadCategories
    private let primeCookies: PrimeCookies
    private let pageLoader: SectionPageLoader
    private let choiceStore: RelatedCategoryChoiceStore
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
        pageLoader: SectionPageLoader = .live,
        choiceStore: RelatedCategoryChoiceStore? = nil
    ) {
        self.loadCategories = loadCategories
        self.primeCookies = primeCookies
        self.pageLoader = pageLoader
        self.choiceStore = choiceStore ?? .shared
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
        choices = nil
        await loadRelated(key: key, source: source, tags: tags, book: book, switching: false)
    }

    /// Loads 同題材 again after it failed.
    func retryRelated(key: String, source: BookSource?, tags: [String], book: OnlineBook) async {
        loadedKey = nil
        await loadRelated(key: key, source: source, tags: tags, book: book, switching: true)
    }

    /// The reader picked `title` from the section's menu: it is remembered
    /// (`RelatedCategoryChoiceStore`) and its first page replaces the shown books when it
    /// arrives, the section staying in place meanwhile.
    func choose(_ title: String, key: String, source: BookSource?, tags: [String], book: OnlineBook) async {
        guard let source, let choices, title != choices.current else { return }
        let fromGenres = choices.matched.contains(title)
        choiceStore.record(title, fromGenres: fromGenres, source: source.bookSourceUrl, book: book.bookUrl)
        loadedKey = nil
        await loadRelated(key: key, source: source, tags: tags, book: book, switching: true)
    }

    /// - Parameter switching: whether the section is already shown, and stays shown until the
    ///   new books arrive rather than vanishing under the reader.
    private func loadRelated(key: String, source: BookSource?, tags: [String], book: OnlineBook, switching: Bool) async {
        guard let source else {
            related = .hidden
            choices = nil
            loadedKey = key
            return
        }
        let items = await categories(of: source).value
        guard !Task.isCancelled else { return }
        let sourceKey = source.bookSourceUrl
        guard let item = SourceGenreMatching.relatedCategory(
                  for: tags, among: items,
                  preferred: choiceStore.preferred(source: sourceKey),
                  bookPick: choiceStore.bookPick(source: sourceKey, book: book.bookUrl)),
              let reference = ExploreCategoryReference(source: source, item: item)
        else {
            related = .hidden
            choices = nil
            loadedKey = key
            return
        }

        choices = RelatedCategoryChoices(tags: tags, items: items, current: item.title)
        if !switching { related = .loading(reference) }
        var section = DiscoverShowcaseSection(
            item: item, coverBaseURL: source.bookSourceUrl, coverHeaders: source.parsedHeaders
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
            // A category the reader picked keeps its header even when it has no other book, so
            // the menu stays to pick another.
            if shown.isEmpty, !switching {
                related = .hidden
                choices = nil
            } else {
                related = .loaded(reference, section)
            }
        } catch {
            // `SectionPageLoader` has logged the failure.
            guard !Task.isCancelled else { return }
            related = .failed(reference, error.localizedDescription)
        }
        loadedKey = key
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
