import CryptoKit
import UIKit
import Foundation

/// Unified library Phase 3b: the reader's own book sources as a metadata provider. A local or
/// remote-library copy whose description or categories are empty is searched for by title in
/// the enabled sources, through the same fan-out 換源 and 封面搜索 use
/// (`BookOriginSearchService`); a result whose title and author both match (level B) gives
/// them. Maintainer, 2026-10-14: 來源配置查到的資料「也自動補空欄位」.
///
/// Only search results are read, never a detail page: they already carry `intro` and `kind`,
/// and a detail fetch would write the detail cache for a book nobody opened.
///
/// Maintainer, 2026-10-17: a copy with no cover of its own takes the match's (downloaded with
/// its source's headers, as 封面搜索's pick is), and a copy that names no author (a TXT with
/// no 「作者：」 line is 「未知作者」) is matched by title when every match names one author.
@MainActor
final class BookSourceFillProvider: MetadataFillProvider {
    /// The ledger's key for every source together: a copy is searched once, not once per
    /// source. A value keeps the key of the source that gave it.
    nonisolated static let allSourcesKey = SourceInstanceKey(type: .bookSource, id: "*")

    /// The fields search results can give.
    static let fields: Set<MetadataField> = [.intro, .tags, .cover]

    /// How many sources one copy is searched in at most, in the reader's source order. The
    /// fan-out stops earlier at the first match with a description.
    static let sourcesPerCopy = 40

    struct Search {
        var origins: [BookOrigin]
        /// Sources that answered, matches or not; zero means the lookup failed.
        var answered: Int
        var queried: Int
    }

    /// `author` is empty when the copy names none. `isEnough` tells, from the matches so far,
    /// that no other source needs asking.
    typealias Searching = @MainActor (_ title: String, _ author: String,
                                      _ isEnough: @escaping @MainActor ([BookOrigin]) -> Bool) async -> Search
    /// Saves a match's cover in the filled covers' folder; its file name, or nil when it could
    /// not be fetched or read (logged where it failed).
    typealias SavingCover = @MainActor (_ url: String, _ sourceID: UUID) async -> String?

    let key: SourceInstanceKey = BookSourceFillProvider.allSourcesKey
    let grade: MetadataMatchGrade = .b
    let fillsCoverByTitle = true
    private let search: Searching
    private let saveCover: SavingCover
    private let sourceURL: @MainActor (UUID) -> String?
    private let hasSources: @MainActor () -> Bool
    /// `hasSources()`, asked once: a provider lives for one pass, and the source list is
    /// thousands long.
    private var sourcesKnown: Bool?

    init(search: Searching? = nil, sourceURL: (@MainActor (UUID) -> String?)? = nil,
         hasSources: (@MainActor () -> Bool)? = nil, saveCover: SavingCover? = nil) {
        self.search = search ?? Self.live
        self.saveCover = saveCover ?? Self.liveSaveCover
        self.sourceURL = sourceURL ?? { BookSourceStore.shared.source(id: $0)?.bookSourceUrl }
        self.hasSources = hasSources ?? { !Self.eligibleSources().isEmpty }
    }

    /// A copy that came from a book source has its own source's values already (tier 1). With
    /// no source to ask, nothing is asked and nothing recorded, so adding sources later asks
    /// (`MetadataFillCoordinator` runs a pass when they change).
    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        query.contentKind == .text && query.copySource.type != .bookSource
            && !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !query.missing.isDisjoint(with: Self.fields)
            && anySource
    }

    private var anySource: Bool {
        if let sourcesKnown { return sourcesKnown }
        let known = hasSources()
        sourcesKnown = known
        return known
    }

    /// The enabled sources whose search rule reads a description or categories, in the
    /// reader's order, at most `sourcesPerCopy`.
    static func eligibleSources() -> [BookSource] {
        eligibleSources(in: BookSourceStore.shared.sources)
    }

    static func eligibleSources(in sources: [BookSource]) -> [BookSource] {
        Array(sources
            .lazy
            .filter { $0.enabled && (!$0.ruleSearch.intro.isEmpty || !$0.ruleSearch.kind.isEmpty) }
            .prefix(sourcesPerCopy))
    }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        let authors = WorkMatchKey.knownAuthors(query.authors)
        let missing = query.missing
        let started = SourcePerfTrace.now
        // With no author, every source's answer is needed to tell one author from two.
        let found = await search(query.title, authors.first ?? "") { origins in
            !authors.isEmpty && origins.contains { Self.givesAll(missing, $0) }
        }
        SourcePerfTrace.record("metadata.fill.sources", "queried=\(found.queried) answered=\(found.answered) matches=\(found.origins.count)",
                               since: started, thresholdMs: 0)
        guard found.answered > 0 || !found.origins.isEmpty else {
            throw LookupError.noSourceAnswered(queried: found.queried)
        }
        if authors.isEmpty, !found.origins.isEmpty, !WorkMatchKey.nameOneAuthor(found.origins.map { [$0.author] }) {
            AppLogger.info("metadata.fill.sources title-only matches name more than one author; nothing taken "
                           + "copy=\(query.copyID.uuidString) matches=\(found.origins.count)")
            return MetadataFillResult(values: [:])
        }
        guard let chosen = Self.chosen(from: found.origins, missing: missing) else { return MetadataFillResult(values: [:]) }
        var result = Self.result(from: chosen, missing: missing, sourceURL: sourceURL)
        let cover = chosen.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if missing.contains(.cover), !cover.isEmpty, result.place != nil,
           let name = await saveCover(cover, chosen.sourceId) {
            result.values[.cover] = .text(name)
        }
        return result
    }

    enum LookupError: Error {
        case noSourceAnswered(queried: Int)
    }

    /// Whether `origin` has every wanted field a search result can give: a description and a
    /// cover, or with neither wanted, categories.
    static func givesAll(_ missing: Set<MetadataField>, _ origin: BookOrigin) -> Bool {
        let wantsIntro = missing.contains(.intro), wantsCover = missing.contains(.cover)
        guard wantsIntro || wantsCover else { return !tags(from: origin.kind).isEmpty }
        return (!wantsIntro || !intro(of: origin).isEmpty)
            && (!wantsCover || !origin.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The match the values come from, all from one so they keep one source: the first with
    /// everything wanted, else the first with a description, else with categories, else with
    /// a cover.
    static func chosen(from origins: [BookOrigin], missing: Set<MetadataField>) -> BookOrigin? {
        origins.first { givesAll(missing, $0) }
            ?? origins.first { missing.contains(.intro) && !intro(of: $0).isEmpty }
            ?? origins.first { missing.contains(.tags) && !tags(from: $0.kind).isEmpty }
            ?? origins.first { missing.contains(.cover) && !$0.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// `chosen`'s description and categories, as its source; the cover is saved by `lookUp`.
    static func result(from chosen: BookOrigin, missing: Set<MetadataField>,
                       sourceURL: (UUID) -> String?) -> MetadataFillResult {
        guard let url = sourceURL(chosen.sourceId) else { return MetadataFillResult(values: [:]) }
        var values: [MetadataField: MetadataPayload] = [:]
        let intro = intro(of: chosen), tags = tags(from: chosen.kind)
        if missing.contains(.intro), !intro.isEmpty { values[.intro] = .text(intro) }
        if missing.contains(.tags), !tags.isEmpty { values[.tags] = .texts(tags) }
        let place = SourceInstanceKey(type: .bookSource, id: url)
        return MetadataFillResult(values: values, sourceItem: SourceItemKey(instance: place, item: chosen.bookUrl),
                                  place: place)
    }

    private static func intro(of origin: BookOrigin) -> String {
        OnlineBookDetailPresentationPolicy.sanitizeIntro(origin.intro, indentParagraphs: false)
    }

    /// A source's `kind` as categories: split on the separators sources use, without word
    /// counts, dates or anything too long to be a category.
    nonisolated static func tags(from kind: String) -> [String] {
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
    /// `sourcesPerCopy`, at the reader's 搜索並發數; stops once `isEnough`.
    static let live: Searching = { title, author, isEnough in
        let sources = eligibleSources()
        var found = Search(origins: [], answered: 0, queried: sources.count)
        var enough = false
        await BookOriginSearchService.stream(
            title: title,
            author: author,
            sources: sources,
            concurrency: NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency),
            fetcher: AppDependencies.live.bookSourceFetcher,
            requiresAuthor: true,
            shouldStop: { _ in enough },
            onSourceAnswered: { found.answered += 1 },
            onBatch: { batch in
                found.origins += batch
                if isEnough(found.origins) { enough = true }
            }
        )
        return found
    }

    /// Downloaded with the source's headers, as `BookStore.applyCustomCover` does, and saved as
    /// `bs-<hash of the url>.jpg` in the filled covers' folder.
    static let liveSaveCover: SavingCover = { url, sourceID in
        let source = BookSourceStore.shared.source(id: sourceID)
        let headers = BookCoverLoader.headers(sourceBaseURL: source?.bookSourceUrl, sourceHeaders: source?.parsedHeaders ?? [:])
        CoverDecodeService.shared.registerIfNeeded(coverUrl: url, source: source)
        // `loadImage` logs a request that failed or an image it could not read.
        guard let image = await BookCoverLoader.loadImage(urlString: url, headers: headers) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            AppLogger.cache("⟐ filled cover could not be encoded", context: ["url": String(url.prefix(300))])
            return nil
        }
        let name = "bs-" + SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let directory = FilledMetadata.coverDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            AppLogger.cache("⟐ filled cover could not be saved", error: error)
            return nil
        }
        return name
    }
}
