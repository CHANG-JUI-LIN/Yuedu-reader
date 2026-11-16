import Combine
import Foundation

/// 作者其他作品 on 作品詳情 (Editorial Minimalism, 2026-10-12): other works by the author of the
/// version shown, from where that version's data says they are. Each source answers from its
/// own record of authors, never a guess: 青空文庫 from its catalogue's credits, Gutenberg from
/// the author's own feed, the shelf from the work index's author keys.
///
/// A 來源配置 has no author record, and until 2026-11-14 its page had no such row: the author's
/// name searched the source when tapped. Maintainer, 2026-11-14 (「為什麼只有這 3 種來源」): its
/// page lists the author's other books too — the source's own search for the author's name,
/// only the books whose author is that author. A record with no library of its own (a module's,
/// a bibliographic one) and a shelf with few of the author's works ask the modules whose
/// search takes an author's name (`searchesAuthors`).
enum AuthorWorksRequest: Hashable {
    /// The work's first 著者 (else its first credit) in the bundled catalogue.
    case aozora(AozoraWork, AozoraCatalogIndex)
    /// The catalog entry's first author's Gutenberg feed, without `excluding`.
    case gutenberg(GutenbergAuthor, excluding: GutenbergBook)
    /// Other works by `versions`' authors on the shelf and in the WebDAV index, then in the
    /// modules that search by author.
    case shelf(versions: [WorkDetailRoute])
    /// The 來源配置's search for the author, without the page's own book.
    case source(sourceID: UUID, author: String, title: String, bookURL: String)
    /// A record with no library of its own: the modules that search by author.
    case modules(authors: [String], title: String)

    /// Where 查看全部 leads, for the libraries with an author page.
    var authorPage: PublicLibraryAuthorDestination? {
        switch self {
        case .aozora(let work, let index):
            return AuthorWorks.aozoraPerson(of: work, in: index).map { .aozora($0, index) }
        case .gutenberg(let author, _):
            return .gutenberg(author)
        case .shelf, .source, .modules:
            return nil
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    private var key: [String] {
        switch self {
        case .aozora(let work, _): ["aozora", work.id]
        case .gutenberg(let author, let book): ["gutenberg", author.id, book.id]
        case .shelf(let versions): ["shelf"] + versions.map(\.nodeKey.sortKey)
        case .source(let sourceID, let author, let title, let bookURL): ["source", sourceID.uuidString, author, title, bookURL]
        case .modules(let authors, let title): ["modules", title] + authors
        }
    }
}

enum AuthorWorks {
    /// How many works the section shows.
    static let limit = 12

    /// The person whose other works 青空文庫's section lists.
    static func aozoraPerson(of work: AozoraWork, in index: AozoraCatalogIndex) -> AozoraPerson? {
        let credit = work.credits.first { $0.role == "著者" } ?? work.credits.first
        return credit.flatMap { index.personsByID[$0.person] }
    }

    static func aozora(_ work: AozoraWork, index: AozoraCatalogIndex, limit: Int) -> [CollectionEntry] {
        guard let person = aozoraPerson(of: work, in: index) else { return [] }
        return index.works(forPerson: person.id)
            .filter { $0.id != work.id }
            .prefix(limit)
            .map { CollectionEntry.aozora($0, index: index) }
    }

    /// A source's search results for an author's name as that author's other books: a search
    /// matches titles too (「魯迅傳」 for 魯迅), so only a book whose author is `author` by name
    /// (`WorkMatchKey.authorsSame`: 飛天魚兒 is not 飛天魚) is kept; never the page's own book, by address or by title,
    /// and each title once.
    static func sameAuthor(_ books: [OnlineBook], author: String, excludingTitle title: String, bookURL: String,
                           limit: Int) -> [OnlineBook] {
        let own = WorkMatchKey.title(title, by: [author])
        let ownURL = OnlineBookURLKey.normalize(bookURL)
        var seen: Set<String> = [own]
        // Not lazy: the filter remembers the titles it has kept, and must see each book once. A
        // title with the author's name written before it is that title (`WorkMatchKey.title(_:by:)`).
        return Array(books.filter { book in
            WorkMatchKey.authorsSame([author], [book.author])
                && OnlineBookURLKey.normalize(book.bookUrl) != ownURL
                && seen.insert(WorkMatchKey.title(book.name, by: [author])).inserted
        }.prefix(limit))
    }

    /// `more` after `entries`, without a work `entries` or the page already has, by title.
    static func appending(_ more: [CollectionEntry], to entries: [CollectionEntry], excludingTitles titles: [String],
                          limit: Int) -> [CollectionEntry] {
        func title(_ entry: CollectionEntry) -> String? {
            if case .item(let record, _, _) = entry { return WorkMatchKey.title(record.title) }
            return nil
        }
        var seen = Set(titles.map(WorkMatchKey.title) + entries.compactMap(title))
        return Array((entries + more.filter { entry in title(entry).map { seen.insert($0).inserted } ?? false }).prefix(limit))
    }

    /// The feed's books without the one on the page.
    static func excluding(_ book: GutenbergBook, from entries: [CollectionEntry], limit: Int) -> [CollectionEntry] {
        let shown = SourceRecord.derived(from: book).key
        return Array(entries.filter { entry in
            guard case .item(let record, _, _) = entry else { return false }
            return record.key != shown
        }.prefix(limit))
    }
}

extension RelatedWorks {
    /// 作者其他作品 from the shelf and the WebDAV index: one card per other work with an entry
    /// sharing one of `authorKeys`, a shelf copy before an indexed file, by title. Unlike `pick`,
    /// no copy of the same work and no series-mate by another author.
    ///
    /// - Parameters:
    ///   - excluding: the page's versions; their works are left out whole.
    ///   - shown: the nodes a card may stand for, as `pick` takes them.
    ///   - excludingSeries: the page's series, whose volumes 同系列 shows; the two rows never
    ///     repeat each other.
    static func byAuthors(in index: WorkIndex, authorKeys: [String], excluding: Set<SourceItemKey>,
                          shown: Set<SourceItemKey>, excludingSeries: String? = nil, limit: Int) -> [SourceItemKey] {
        let authors = Set(authorKeys.filter { !$0.isEmpty })
        guard limit > 0, !authors.isEmpty else { return [] }
        let workOf = index.workPositions()
        let excludedWorks = Set(excluding.compactMap { workOf[$0] })
        var choice: [Int: Int] = [:]
        var unindexed: [Int] = []
        for (position, entry) in index.entries.enumerated()
        where shown.contains(entry.nodeKey) && !excluding.contains(entry.nodeKey)
            && !authors.isDisjoint(with: entry.authorKeys) {
            if let excludingSeries, index.seriesPlacement(of: entry, workOf: workOf)?.key == excludingSeries { continue }
            guard let work = workOf[entry.nodeKey] else {
                unindexed.append(position)
                continue
            }
            guard !excludedWorks.contains(work) else { continue }
            if let current = choice[work] {
                // A shelf copy stands for its work before an indexed file does.
                if index.entries[current].record.copyID == nil, entry.record.copyID != nil { choice[work] = position }
            } else {
                choice[work] = position
            }
        }
        return (Array(choice.values) + unindexed)
            .sorted { (index.entries[$0].titleKey, index.entries[$0].nodeKey.sortKey)
                < (index.entries[$1].titleKey, index.entries[$1].nodeKey.sortKey) }
            .prefix(limit)
            .map { index.entries[$0].nodeKey }
    }
}

/// One 作品詳情's 作者其他作品, loaded once per version shown.
@MainActor
final class AuthorWorksModel: ObservableObject {
    enum State: Equatable {
        case hidden
        case loading
        case loaded([CollectionEntry])
        case failed(String)
    }

    @Published private(set) var state: State = .hidden
    private var loaded: AuthorWorksRequest?

    typealias LoadGutenberg = @MainActor (GutenbergAuthor) async throws -> [CollectionEntry]
    typealias LoadShelf = @MainActor ([WorkDetailRoute], BookStore) async -> [CollectionEntry]
    /// A 來源配置's search for a keyword: nil when the source is gone or cannot search.
    typealias SearchSource = @MainActor (UUID, String) async throws -> (source: BookSource, books: [OnlineBook])?
    /// The modules' works by these authors, the most certain first.
    typealias LoadModules = @MainActor ([String]) async -> [CollectionEntry]

    private let loadGutenberg: LoadGutenberg
    private let loadShelf: LoadShelf
    private let searchSource: SearchSource
    private let loadModules: LoadModules

    /// Defaults to the app's sources: Gutenberg's provider for its author feeds, the shelf's
    /// for its works.
    init(
        loadGutenberg: @escaping LoadGutenberg = { author in
            try await SourceProviderRegistry.shared.gutenberg
                .browse(CollectionLocation(id: author.url.absoluteString, title: author.name), after: nil)
                .items(limit: .max)
        },
        loadShelf: @escaping LoadShelf = { versions, store in
            await ShelfProvider(store: store).otherWorks(byAuthorsOf: versions, limit: AuthorWorks.limit)
        },
        searchSource: @escaping SearchSource = { sourceID, keyword in
            guard let source = BookSourceStore.shared.source(id: sourceID), !source.searchUrl.isEmpty else { return nil }
            // Through the source's own search, as 搜索 asks it (`BookSourceSession` under it).
            switch try await BookSourceFetcher.shared.searchOutcome(query: keyword, in: source) {
            case .results(let books): return (source, books)
            case .empty: return (source, [])
            case .failed(let failure): throw failure
            }
        },
        loadModules: @escaping LoadModules = { await ModuleAuthorWorks.load(authors: $0, limit: AuthorWorks.limit) }
    ) {
        self.loadGutenberg = loadGutenberg
        self.loadShelf = loadShelf
        self.searchSource = searchSource
        self.loadModules = loadModules
    }

    /// Loads the section for `request`; nil hides it. The same request is not loaded again when
    /// the page reappears.
    func load(_ request: AuthorWorksRequest?, store: BookStore) async {
        guard request != loaded || request == nil else { return }
        guard let request else {
            loaded = nil
            state = .hidden
            return
        }
        let started = SourcePerfTrace.now
        switch request {
        case .aozora(let work, let index):
            show(AuthorWorks.aozora(work, index: index, limit: AuthorWorks.limit))
        case .gutenberg(let author, let book):
            state = .loading
            do {
                let entries = try await loadGutenberg(author)
                guard !Task.isCancelled else { return }
                show(AuthorWorks.excluding(book, from: entries, limit: AuthorWorks.limit))
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.network("⟐ author works feed failed", error: SourceFailure.loggable(error),
                                  context: ["author": author.url.absoluteString])
                state = .failed(error.localizedDescription)
            }
        case .shelf(let versions):
            var entries = await loadShelf(versions, store)
            guard !Task.isCancelled else { return }
            if entries.count < AuthorWorks.limit {
                // The shelf has few of them: the modules that search by author give the rest.
                let authors = WorkMatchKey.knownAuthors(versions.flatMap(\.summary.authors))
                let more = authors.isEmpty ? [] : await loadModules(authors)
                guard !Task.isCancelled else { return }
                entries = AuthorWorks.appending(more, to: entries, excludingTitles: versions.map(\.summary.title),
                                                limit: AuthorWorks.limit)
            }
            show(entries)
        case .source(let sourceID, let author, let title, let bookURL):
            do {
                guard let found = try await searchSource(sourceID, author) else {
                    show([])
                    break
                }
                guard !Task.isCancelled else { return }
                show(CollectionEntry.onlineBooks(
                    AuthorWorks.sameAuthor(found.books, author: author, excludingTitle: title, bookURL: bookURL,
                                           limit: AuthorWorks.limit),
                    source: found.source))
            } catch {
                guard !Task.isCancelled else { return }
                // The row was never promised: a source whose search fails shows none, as one that
                // finds nothing does. No retry block under a title the page did not have before.
                AppLogger.network("⟐ author works: source search failed", error: SourceFailure.loggable(error),
                                  context: ["source": sourceID.uuidString])
                show([])
            }
        case .modules(let authors, let title):
            let more = await loadModules(authors)
            guard !Task.isCancelled else { return }
            show(AuthorWorks.appending(more, to: [], excludingTitles: [title], limit: AuthorWorks.limit))
        }
        loaded = request
        if case .loaded(let entries) = state {
            SourcePerfTrace.record("works.detail.authorWorks", "works=\(entries.count)", since: started, thresholdMs: 0)
        }
    }

    /// Loads the section again after it failed.
    func retry(_ request: AuthorWorksRequest?, store: BookStore) async {
        loaded = nil
        await load(request, store: store)
    }

    private func show(_ entries: [CollectionEntry]) {
        state = entries.isEmpty ? .hidden : .loaded(entries)
    }
}
