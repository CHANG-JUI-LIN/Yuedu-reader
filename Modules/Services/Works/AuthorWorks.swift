import Combine
import Foundation

/// 作者其他作品 on 作品詳情 (Editorial Minimalism, 2026-10-12): other works by the author of the
/// version shown, from where that version's data says they are. Each source answers from its
/// own record of authors, never a guess: 青空文庫 from its catalogue's credits, Gutenberg from
/// the author's own feed, the shelf from the work index's author keys. A book source has no
/// author record; its page searches the source when the author is tapped instead.
enum AuthorWorksRequest: Hashable {
    /// The work's first 著者 (else its first credit) in the bundled catalogue.
    case aozora(AozoraWork, AozoraCatalogIndex)
    /// The catalog entry's first author's Gutenberg feed, without `excluding`.
    case gutenberg(GutenbergAuthor, excluding: GutenbergBook)
    /// Other works by `versions`' authors on the shelf and in the WebDAV index.
    case shelf(versions: [WorkDetailRoute])

    /// Where 查看全部 leads, for the libraries with an author page.
    var authorPage: PublicLibraryAuthorDestination? {
        switch self {
        case .aozora(let work, let index):
            return AuthorWorks.aozoraPerson(of: work, in: index).map { .aozora($0, index) }
        case .gutenberg(let author, _):
            return .gutenberg(author)
        case .shelf:
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
    static func byAuthors(in index: WorkIndex, authorKeys: [String], excluding: Set<SourceItemKey>,
                          shown: Set<SourceItemKey>, limit: Int) -> [SourceItemKey] {
        let authors = Set(authorKeys.filter { !$0.isEmpty })
        guard limit > 0, !authors.isEmpty else { return [] }
        var workOf: [SourceItemKey: Int] = [:]
        for (position, work) in index.works.enumerated() {
            for member in work.members { workOf[member] = position }
        }
        let excludedWorks = Set(excluding.compactMap { workOf[$0] })
        var choice: [Int: Int] = [:]
        var unindexed: [Int] = []
        for (position, entry) in index.entries.enumerated()
        where shown.contains(entry.nodeKey) && !excluding.contains(entry.nodeKey)
            && !authors.isDisjoint(with: entry.authorKeys) {
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

    private let loadGutenberg: LoadGutenberg
    private let loadShelf: LoadShelf

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
        }
    ) {
        self.loadGutenberg = loadGutenberg
        self.loadShelf = loadShelf
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
            let entries = await loadShelf(versions, store)
            guard !Task.isCancelled else { return }
            show(entries)
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
