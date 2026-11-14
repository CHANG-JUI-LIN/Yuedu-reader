import Combine
import Foundation

/// An author's works by kind, as the author's page lists them: 書籍 (text and comics) and 有聲書.
///
/// Maintainer, 2026-11-14: an author's name opens the author's own page from every source's
/// detail page, never the search screen (「作者分類就不應該直接進搜索，應該都是自己一個頁面」). An
/// author with both kinds has a row of each, as Apple Books' store draws an author; an author
/// with one kind has that kind's works alone.
struct AuthorShelf: Hashable, Sendable {
    /// Text and comics.
    var books: [CollectionEntry]
    var audiobooks: [CollectionEntry]

    var hasBothKinds: Bool { !books.isEmpty && !audiobooks.isEmpty }
    var isEmpty: Bool { books.isEmpty && audiobooks.isEmpty }

    /// Works kept per kind: a shelf of thousands by one name is still a page.
    static let limit = 60

    /// `more` after this shelf's own works, each by its kind (a video is neither), without a work
    /// the kind already has, by title. A book and its audiobook share a title and are both kept.
    ///
    /// A title is the author's work's own (`WorkMatchKey.title(_:by:)`): one a source wrote the
    /// author's name before is the same work, and of the two the one written plainly is shown,
    /// in the place the first had.
    func adding(_ more: [CollectionEntry], limit: Int = AuthorShelf.limit) -> AuthorShelf {
        func keys(_ entry: CollectionEntry) -> (work: String, plain: Bool)? {
            guard case .item(let record, _, _) = entry else { return nil }
            let work = WorkMatchKey.title(record.title, by: record.authors)
            return work.isEmpty ? nil : (work, work == WorkMatchKey.title(record.title))
        }
        var books = books, audiobooks = audiobooks
        func place(_ entry: CollectionEntry, in shelf: inout [CollectionEntry], _ placed: inout [String: (index: Int, plain: Bool)]) {
            guard let key = keys(entry) else { return }
            if let held = placed[key.work] {
                guard key.plain, !held.plain else { return }
                shelf[held.index] = entry
                placed[key.work] = (held.index, true)
            } else {
                placed[key.work] = (shelf.count, key.plain)
                shelf.append(entry)
            }
        }
        var bookTitles: [String: (index: Int, plain: Bool)] = [:], audioTitles: [String: (index: Int, plain: Bool)] = [:]
        for (index, entry) in books.enumerated() { if let key = keys(entry) { bookTitles[key.work] = bookTitles[key.work] ?? (index, key.plain) } }
        for (index, entry) in audiobooks.enumerated() { if let key = keys(entry) { audioTitles[key.work] = audioTitles[key.work] ?? (index, key.plain) } }
        for entry in more {
            guard case .item(let record, _, _) = entry else { continue }
            switch record.contentKind {
            case .text, .comic: place(entry, in: &books, &bookTitles)
            case .audio: place(entry, in: &audiobooks, &audioTitles)
            case .video: continue
            }
        }
        return AuthorShelf(books: Array(books.prefix(limit)), audiobooks: Array(audiobooks.prefix(limit)))
    }
}

/// The author's page a detail page pushes: the name, and where the page it was opened from has
/// its author's works.
struct AuthorPageRequest: Hashable, Sendable {
    let name: String
    let context: Context

    enum Context: Hashable, Sendable {
        /// A copy, a library file, a module's or a bibliographic record: this device's works, and
        /// the modules that search by author.
        case device
        /// A 來源配置's book: this device's works, and the source's own search for the name.
        case source(UUID)
        /// A public library's book: this device's works, and the library's record of the author.
        case library(PublicLibraryAuthorDestination)
    }
}

extension RelatedWorks {
    /// The entries by one of `authorKeys`, as books (text, comics) and as audiobooks: one card
    /// per work in each, a shelf copy before an indexed file, by title.
    ///
    /// Per kind, unlike `byAuthors`: the index joins a book and its audiobook into one work
    /// (same title, same author), and one card for the work would hide the audiobook behind
    /// the book.
    static func byAuthorKinds(in index: WorkIndex, authorKeys: [String], shown: Set<SourceItemKey>,
                              limit: Int) -> (books: [SourceItemKey], audiobooks: [SourceItemKey]) {
        let authors = Set(authorKeys.filter { !$0.isEmpty })
        guard limit > 0, !authors.isEmpty else { return ([], []) }
        let workOf = index.workPositions()
        var books: [Int: Int] = [:], audiobooks: [Int: Int] = [:]
        var looseBooks: [Int] = [], looseAudiobooks: [Int] = []
        for (position, entry) in index.entries.enumerated()
        where shown.contains(entry.nodeKey) && !authors.isDisjoint(with: entry.authorKeys) {
            let isAudio: Bool
            switch entry.record.contentKind {
            case .text, .comic: isAudio = false
            case .audio: isAudio = true
            case .video: continue
            }
            guard let work = workOf[entry.nodeKey] else {
                if isAudio { looseAudiobooks.append(position) } else { looseBooks.append(position) }
                continue
            }
            let current = isAudio ? audiobooks[work] : books[work]
            // A shelf copy stands for its work before an indexed file does.
            let replaces = current.map { index.entries[$0].record.copyID == nil && entry.record.copyID != nil } ?? true
            guard replaces else { continue }
            if isAudio { audiobooks[work] = position } else { books[work] = position }
        }
        func ordered(_ positions: [Int]) -> [SourceItemKey] {
            positions.sorted { (index.entries[$0].titleKey, index.entries[$0].nodeKey.sortKey)
                < (index.entries[$1].titleKey, index.entries[$1].nodeKey.sortKey) }
                .prefix(limit).map { index.entries[$0].nodeKey }
        }
        return (ordered(Array(books.values) + looseBooks), ordered(Array(audiobooks.values) + looseAudiobooks))
    }
}

/// One author's page: this device's works by the author at once (the shelf's and the WebDAV
/// index's), then what the page's own source has by the author, then — in the background, as
/// 作品詳情 finds a work's sources (maintainer, 2026-11-14: 「作者的頁面能做後台搜索來補齊嗎」) —
/// what every enabled 來源配置's search finds for the name, only the books whose author is that
/// author. Each book joins the page as its source answers; nothing is stored.
@MainActor
final class AuthorPageModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(AuthorShelf)
    }

    @Published private(set) var state: State = .loading
    /// While the background search still has sources to hear from.
    @Published private(set) var isSearching = false
    private var loaded: AuthorPageRequest?

    private let aggregator = SearchAggregator()
    private var subscriptions: Set<AnyCancellable> = []
    /// What the page had before the search, and what the search has added, in the order found:
    /// a later answer reorders the aggregator's results, and the page's cards must not move.
    private var base = AuthorShelf(books: [], audiobooks: [])
    private var found: [CollectionEntry] = []
    private var foundKeys: Set<String> = []
    private var searchedAuthor = ""
    private var searchedSources: [UUID: BookSource] = [:]

    typealias ReadDevice = @MainActor (String, BookStore) async -> AuthorShelf
    /// What the request's own source has by the author; throws when its request failed.
    typealias ReadSource = @MainActor (AuthorPageRequest) async throws -> [CollectionEntry]

    private let readDevice: ReadDevice
    private let readSource: ReadSource
    private let enabledSources: @MainActor () -> [BookSource]

    init(readDevice: @escaping ReadDevice = { name, store in
             await ShelfProvider(store: store).shelf(ofAuthor: name, limit: AuthorShelf.limit)
         },
         readSource: @escaping ReadSource = { try await AuthorPageModel.sourceWorks($0) },
         enabledSources: @escaping @MainActor () -> [BookSource] = { BookSourceStore.shared.sources.filter(\.enabled) }) {
        self.readDevice = readDevice
        self.readSource = readSource
        self.enabledSources = enabledSources
        // The aggregator publishes its results through `objectWillChange` alone; read them once
        // the change has landed (`WorkSourceFinder`).
        aggregator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.searchChanged() }
            .store(in: &subscriptions)
    }

    /// Loads the page once; the same request is not read again when the page reappears.
    func load(_ request: AuthorPageRequest, store: BookStore) async {
        guard request != loaded else { return }
        state = .loading
        let started = SourcePerfTrace.now
        var shelf = await readDevice(request.name, store)
        guard !Task.isCancelled else { return }
        do {
            shelf = shelf.adding(try await readSource(request))
        } catch is CancellationError {
            return
        } catch {
            // The source's own failure (a site that is down): the page still lists what this
            // device has by the author. Nothing is retried.
            AppLogger.network("⟐ author page: source works failed", error: SourceFailure.loggable(error),
                              context: ["author": request.name])
        }
        guard !Task.isCancelled else { return }
        state = .loaded(shelf)
        loaded = request
        SourcePerfTrace.record("works.authorPage", "books=\(shelf.books.count) audiobooks=\(shelf.audiobooks.count)",
                               since: started, thresholdMs: 0)
        searchSources(for: request.name, after: shelf)
    }

    /// The background search: every enabled 來源配置 is asked for the name, as 搜索 asks them
    /// (`SearchAggregator`). None when no source is enabled. Leaving the page ends it: the
    /// aggregator goes with this model.
    private func searchSources(for name: String, after shelf: AuthorShelf) {
        let sources = enabledSources()
        guard !sources.isEmpty else { return }
        base = shelf
        found = []
        foundKeys = []
        searchedAuthor = name
        searchedSources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        isSearching = true
        aggregator.search(query: name, sources: sources, origin: .changeSource)
    }

    private func searchChanged() {
        guard isSearching else { return }
        let books = aggregator.results.flatMap { result in result.origins.map { OnlineBook(detailOrigin: $0, in: result) } }
        let added = Self.byAuthor(books, author: searchedAuthor, sources: searchedSources, seen: &foundKeys)
        if !added.isEmpty {
            found += added
            state = .loaded(base.adding(found))
        }
        guard !aggregator.isSearching else { return }
        isSearching = false
        AppLogger.info("works.authorPage search done found=\(found.count) "
                       + "completed=\(aggregator.progress.completed) failed=\(aggregator.progress.failed) "
                       + "timedOut=\(aggregator.progress.timedOut)")
    }

    /// An inactive scene is never handed results (`SearchAggregator.setResultPresentationActive`).
    func setPresentationActive(_ active: Bool) {
        aggregator.setResultPresentationActive(active)
    }

    /// The search's books that are the author's and not yet on the page: a search matches titles
    /// too, so only a book whose author is `author` by name is one (`WorkMatchKey.authorsSame`), each title once a kind
    /// (`seen`), from the first source that has it.
    static func byAuthor(_ books: [OnlineBook], author: String, sources: [UUID: BookSource],
                         seen: inout Set<String>) -> [CollectionEntry] {
        var added: [CollectionEntry] = []
        for book in books {
            guard WorkMatchKey.authorsSame([author], [book.author]), let source = sources[book.sourceId] else { continue }
            let entry = CollectionEntry.onlineBook(book, source: source)
            guard case .item(let record, _, _) = entry else { continue }
            let title = WorkMatchKey.title(record.title)
            guard !title.isEmpty, seen.insert("\(record.contentKind.rawValue)\u{1F}\(title)").inserted else { continue }
            added.append(entry)
        }
        return added
    }

    /// The app's own sources: a 來源配置's search for the name (only the books whose author is that
    /// author, `AuthorWorks.sameAuthor`), a public library's record of the author, the modules
    /// that search by author.
    static func sourceWorks(_ request: AuthorPageRequest) async throws -> [CollectionEntry] {
        switch request.context {
        case .device:
            return await ModuleAuthorWorks.load(authors: [request.name], limit: AuthorShelf.limit)
        case .source(let sourceID):
            guard let source = BookSourceStore.shared.source(id: sourceID), !source.searchUrl.isEmpty else { return [] }
            // Through the source's own search, as 搜索 asks it (`BookSourceSession` under it).
            switch try await BookSourceFetcher.shared.searchOutcome(query: request.name, in: source) {
            case .results(let books):
                return AuthorWorks.sameAuthor(books, author: request.name, excludingTitle: "", bookURL: "", limit: AuthorShelf.limit)
                    .map { CollectionEntry.onlineBook($0, source: source) }
            case .empty:
                return []
            case .failed(let failure):
                throw failure
            }
        case .library(.aozora(let person, let index)):
            return index.works(forPerson: person.id).prefix(AuthorShelf.limit).map { CollectionEntry.aozora($0, index: index) }
        case .library(.gutenberg(let author)):
            return try await SourceProviderRegistry.shared.gutenberg
                .browse(CollectionLocation(id: author.url.absoluteString, title: author.name), after: nil)
                .items(limit: AuthorShelf.limit)
        }
    }
}
