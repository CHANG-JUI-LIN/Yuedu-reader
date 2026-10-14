import Foundation

/// Open Library in 搜索 (unified search 4b-3): asked on submit, behind 設定 → 網路設定 →
/// 搜尋時也查 Open Library (default on). Its books are data only (「只有資料」, maintainer,
/// 2026-10-14): 作品詳情 shows them with 尋找可用來源 and nothing to read.
///
/// Its terms (read 2026-10-14, https://openlibrary.org/developers/api) as Phase 3 reads them:
/// one request a second through `RequestPacer.openLibrary`, shared with the metadata fill; the
/// app's User-Agent, never the user's email. A search is one request; covers come by cover id,
/// which the ISBN cover limit does not apply to.
@MainActor
final class OpenLibrarySearch: SearchAnswering {
    static let timeout: Duration = .seconds(15)
    /// Results asked for: one screen of rows.
    static let limit = 20
    /// ISBNs kept per work: a work lists every edition's, hundreds for a classic.
    static let isbnLimit = 5

    private let fetcher: WebFetcher
    private let pacer: RequestPacer
    private let enabled: @MainActor () -> Bool
    private let timeout: Duration

    init(fetcher: WebFetcher = .shared, pacer: RequestPacer = .openLibrary,
         enabled: (@MainActor () -> Bool)? = nil, timeout: Duration = OpenLibrarySearch.timeout) {
        self.fetcher = fetcher
        self.pacer = pacer
        self.enabled = enabled ?? { GlobalSettings.shared.searchOpenLibrary }
        self.timeout = timeout
    }

    var isAvailable: Bool { enabled() }

    func search(_ query: String, onAnswer: (LibrarySearchAnswer) -> Void) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, enabled() else { return }
        let started = SourcePerfTrace.now
        func finish(_ outcome: LibrarySearchAnswer.Outcome, _ entries: [CollectionEntry] = []) {
            let label: String = switch outcome {
            case .results: "results"
            case .empty: "empty"
            case .noSearch: "noSearch"
            case .failed: "failed"
            }
            SourcePerfTrace.record("search.openLibrary", "outcome=\(label) items=\(entries.count)", since: started, thresholdMs: 0)
            onAnswer(LibrarySearchAnswer(connectionID: OpenLibrary.providerID, name: FilledMetadata.providerName(OpenLibrary.key), outcome: outcome, entries: entries))
        }
        do {
            let entries = try await LibrarySearch.within(timeout) { [self] in try await self.entries(for: query) }
            guard !Task.isCancelled else { return }
            finish(entries.isEmpty ? .empty : .results, entries)
        } catch {
            let failure: SourceFailure
            do { failure = try SourceFailure.classify(error) } catch {
                // Cancelled: the search was replaced or cleared, and nobody reads this answer.
                return
            }
            AppLogger.network("open library search failed", error: SourceFailure.loggable(error),
                              context: ["failure": failure.kind.rawValue])
            finish(.failed(failure.localizedDescription))
        }
    }

    private func entries(for query: String) async throws -> [CollectionEntry] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,language,isbn"),
            URLQueryItem(name: "limit", value: String(Self.limit)),
        ]
        let url = components.url!
        await pacer.wait(for: url.host ?? "")
        let page = try await fetcher.fetchPage(
            url: url, method: "GET", body: nil,
            headers: ["User-Agent": RemoteLibraryHTTPClient.userAgent, "Accept": "application/json"],
            baseURL: ""
        )
        guard (200...299).contains(page.statusCode) else {
            throw SourceFailure(kind: .rejected, status: page.statusCode,
                                underlying: OpenLibraryFillProvider.LookupError.status(page.statusCode, url.host ?? ""))
        }
        return try JSONDecoder().decode(Response.self, from: page.data).docs.compactMap(Self.entry(_:))
    }

    /// A work as a data-only item. Its key is the one Phase 3 records a filled copy's source
    /// under (`/works/OL…W`), and its work id the same `openLibraryWork` identifier.
    nonisolated static func entry(_ doc: Response.Doc) -> CollectionEntry? {
        guard let key = doc.key, key.hasPrefix("/works/") else { return nil }
        let title = OPDSClient.plainMetadata(doc.title ?? "", limit: 200)
        guard !title.isEmpty else { return nil }
        let authors = (doc.author_name ?? []).prefix(5).map { OPDSClient.plainMetadata($0, limit: 100) }.filter { !$0.isEmpty }
        // MARC codes (`chi`, `jpn`) read as every other source's tags are.
        let language = (doc.language?.count == 1 ? doc.language?.first : nil).flatMap { LanguageTag($0)?.identifier }
        var identifiers = Set<ExternalIdentifier>()
        if let workID = key.split(separator: "/").last.flatMap({ ExternalIdentifier.normalized(.openLibraryWork, String($0)) }) {
            identifiers.insert(workID)
        }
        // ISBN-10s and -13s of one edition normalize to the same value: counted once each.
        var isbns = 0
        for isbn in (doc.isbn ?? []).lazy.compactMap({ ExternalIdentifier.normalized(.isbn13, $0) }) where isbns < Self.isbnLimit {
            if identifiers.insert(isbn).inserted { isbns += 1 }
        }
        let record = SourceRecord(key: SourceItemKey(instance: OpenLibrary.key, item: key), title: title,
                                  authors: Array(authors), language: language, contentKind: .text,
                                  identifiers: identifiers, copyID: nil, acquisitions: [.viewOnly])
        let cover: CoverReference = doc.cover_i.flatMap { $0 > 0 ? $0 : nil }
            .flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg") }
            .map { .remote($0, headers: ["User-Agent": RemoteLibraryHTTPClient.userAgent]) }
            ?? .generated(seed: title)
        let summary = WorkSummary(title: title, authors: Array(authors), cover: cover, blurb: nil,
                                  language: language, contentKind: .text)
        return .item(record, summary, .bibliographic)
    }

    struct Response: Decodable, Sendable {
        var docs: [Doc]
        struct Doc: Decodable, Sendable {
            var key: String?
            var title: String?
            var author_name: [String]?
            var cover_i: Int?
            var language: [String]?
            var isbn: [String]?
        }
    }
}
