import Foundation

/// Unified library Phase 3b: the reader's own book sources as a metadata provider. A local or
/// remote-library copy whose description or categories are empty is searched for by title in
/// the enabled sources, through the same fan-out 換源 and 封面搜索 use
/// (`BookOriginSearchService`); a result whose title and author both match (level B) gives
/// them. Maintainer, 2026-10-14: 來源配置查到的資料「也自動補空欄位」.
///
/// Only search results are read, never a detail page: they already carry `intro` and `kind`,
/// and a detail fetch would write the detail cache for a book nobody opened.
@MainActor
final class BookSourceFillProvider: MetadataFillProvider {
    /// The ledger's key for every source together: a copy is searched once, not once per
    /// source. A value keeps the key of the source that gave it.
    nonisolated static let allSourcesKey = SourceInstanceKey(type: .bookSource, id: "*")

    /// The fields search results can give.
    static let fields: Set<MetadataField> = [.intro, .tags]

    /// How many sources one copy is searched in at most, in the reader's source order. The
    /// fan-out stops earlier at the first match with a description.
    static let sourcesPerCopy = 40

    struct Search {
        var origins: [BookOrigin]
        /// Sources that answered, matches or not; zero means the lookup failed.
        var answered: Int
        var queried: Int
    }

    typealias Searching = @MainActor (_ title: String, _ author: String) async -> Search

    let key: SourceInstanceKey = BookSourceFillProvider.allSourcesKey
    let grade: MetadataMatchGrade = .b
    private let search: Searching
    private let sourceURL: @MainActor (UUID) -> String?

    init(search: Searching? = nil, sourceURL: (@MainActor (UUID) -> String?)? = nil) {
        self.search = search ?? Self.live
        self.sourceURL = sourceURL ?? { BookSourceStore.shared.source(id: $0)?.bookSourceUrl }
    }

    /// A copy that came from a book source has its own source's values already (tier 1).
    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        query.copySource.type != .bookSource
            && !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && query.authors.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !query.missing.isDisjoint(with: Self.fields)
    }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        let author = query.authors.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let started = SourcePerfTrace.now
        let found = await search(query.title, author)
        SourcePerfTrace.record("metadata.fill.sources", "queried=\(found.queried) answered=\(found.answered) matches=\(found.origins.count)",
                               since: started, thresholdMs: 0)
        guard found.answered > 0 || !found.origins.isEmpty else {
            throw LookupError.noSourceAnswered(queried: found.queried)
        }
        return Self.result(from: found.origins, missing: query.missing, sourceURL: sourceURL)
    }

    enum LookupError: Error {
        case noSourceAnswered(queried: Int)
    }

    /// The first match with a description gives it, and its categories; without one, the
    /// first match with categories gives those.
    static func result(from origins: [BookOrigin], missing: Set<MetadataField>,
                       sourceURL: (UUID) -> String?) -> MetadataFillResult {
        let candidates = origins.map { origin in
            (origin: origin,
             intro: OnlineBookDetailPresentationPolicy.sanitizeIntro(origin.intro, indentParagraphs: false),
             tags: tags(from: origin.kind))
        }
        guard let chosen = candidates.first(where: { missing.contains(.intro) && !$0.intro.isEmpty })
            ?? candidates.first(where: { missing.contains(.tags) && !$0.tags.isEmpty }),
            let url = sourceURL(chosen.origin.sourceId) else {
            return MetadataFillResult(values: [:])
        }
        var values: [MetadataField: MetadataPayload] = [:]
        if missing.contains(.intro), !chosen.intro.isEmpty { values[.intro] = .text(chosen.intro) }
        if missing.contains(.tags), !chosen.tags.isEmpty { values[.tags] = .texts(chosen.tags) }
        let place = SourceInstanceKey(type: .bookSource, id: url)
        return MetadataFillResult(values: values, sourceItem: SourceItemKey(instance: place, item: chosen.origin.bookUrl),
                                  place: place)
    }

    /// A source's `kind` as categories: split on the separators sources use, without word
    /// counts, dates or anything too long to be a category.
    static func tags(from kind: String) -> [String] {
        var seen = Set<String>()
        return kind
            .components(separatedBy: CharacterSet(charactersIn: ",，、/|;；\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { tag in
                !tag.isEmpty && tag.count <= 12 && !tag.contains(where: \.isNumber)
            }
            .filter { seen.insert($0).inserted }
            .prefix(5)
            .map { $0 }
    }

    /// The enabled sources whose search rule reads a description or categories, at most
    /// `sourcesPerCopy`, at the reader's 搜索並發數; stops at the first match with a
    /// description.
    static let live: Searching = { title, author in
        let sources = BookSourceStore.shared.enabledSources
            .filter { !$0.ruleSearch.intro.isEmpty || !$0.ruleSearch.kind.isEmpty }
            .prefix(sourcesPerCopy)
        var found = Search(origins: [], answered: 0, queried: sources.count)
        var hasDescription = false
        await BookOriginSearchService.stream(
            title: title,
            author: author,
            sources: Array(sources),
            concurrency: NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency),
            fetcher: AppDependencies.live.bookSourceFetcher,
            requiresAuthor: true,
            shouldStop: { _ in hasDescription },
            onSourceAnswered: { found.answered += 1 },
            onBatch: { batch in
                found.origins += batch
                if batch.contains(where: { !$0.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    hasDescription = true
                }
            }
        )
        return found
    }
}
