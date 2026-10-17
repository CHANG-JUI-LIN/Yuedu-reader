import Foundation

/// Unified library Phase 3c: Open Library as the first bibliographic database (maintainer,
/// 2026-10-14). A copy with an ISBN is looked up by it, so a record found is the copy's own
/// (level A): it may give a missing cover, a description and subjects, and its work id is kept.
///
/// Its terms (read 2026-10-14, https://openlibrary.org/developers/api):
/// - at most 1 request a second with an app User-Agent (3 with a contact email in it; the
///   user's own email is never sent, so this stays at 1);
/// - no bulk use: each copy is asked once (`MetadataFillLedger`), never the whole shelf in a
///   burst;
/// - covers by cover id, which the 100-per-5-minutes limit on ISBN cover lookups does not
///   apply to.
@MainActor
final class OpenLibraryFillProvider: MetadataFillProvider {
    let key: SourceInstanceKey = OpenLibrary.key
    let grade: MetadataMatchGrade = .a

    static let fields: Set<MetadataField> = [.cover, .intro, .tags]

    private let fetcher: WebFetcher
    private let pacer: RequestPacer
    private let coverDirectory: URL

    init(fetcher: WebFetcher = .shared, pacer: RequestPacer = .openLibrary,
         coverDirectory: URL = FilledMetadata.coverDirectory) {
        self.fetcher = fetcher
        self.pacer = pacer
        self.coverDirectory = coverDirectory
    }

    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        query.contentKind == .text && query.identifiers.contains { $0.scheme == .isbn13 }
            && !query.missing.isDisjoint(with: Self.fields)
    }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        let isbns = query.identifiers.filter { $0.scheme == .isbn13 }.map(\.value).sorted()
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("metadata.fill.openLibrary", "isbns=\(isbns.count)", since: started, thresholdMs: 0) }

        // Every ISBN of the copy in one search; `editions` is the edition the ISBN names,
        // with its own cover and language.
        var search = URLComponents(string: "https://openlibrary.org/search.json")!
        search.queryItems = [
            URLQueryItem(name: "q", value: "isbn:(\(isbns.joined(separator: " OR ")))"),
            URLQueryItem(name: "fields", value: "key,subject,editions,editions.key,editions.cover_i,editions.isbn"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let found = try JSONDecoder().decode(SearchResponse.self, from: try await get(search.url!))
        // An edition that does not carry one of the copy's ISBNs is not the copy's. Its ISBNs
        // are ISBN-10s and -13s as catalogued; compared as ISBN-13s.
        guard let doc = found.docs.first, let workKey = doc.key, let edition = doc.editions?.docs.first,
              !Set((edition.isbn ?? []).compactMap { ExternalIdentifier.normalized(.isbn13, $0)?.value }).isDisjoint(with: isbns)
        else {
            return MetadataFillResult(values: [:])
        }

        // A work's description and subjects are in whatever language it was catalogued in
        // (三體's Chinese edition belongs to a work described in English): taken only in the
        // copy's own script.
        let script = WritingScript(of: query.title)
        var values: [MetadataField: MetadataPayload] = [:]
        if query.missing.contains(.tags) {
            let subjects = Self.subjects(doc.subject ?? []).filter { WritingScript(of: $0) == script }
            if !subjects.isEmpty { values[.tags] = .texts(subjects) }
        }
        if query.missing.contains(.intro), let intro = try await description(workKey: workKey, script: script) {
            values[.intro] = .text(intro)
        }
        // The edition's own cover only: the work's may be another language's edition.
        if query.missing.contains(.cover), let coverID = edition.cover_i, coverID > 0 {
            if let name = try await saveCover(id: coverID) { values[.cover] = .text(name) }
        }

        let workID = workKey.split(separator: "/").last.map(String.init) ?? workKey
        let editionID = edition.key.flatMap { $0.split(separator: "/").last.map(String.init) }
        return MetadataFillResult(
            values: values,
            identifiers: [ExternalIdentifier.normalized(.openLibraryWork, workID),
                          editionID.flatMap { ExternalIdentifier.normalized(.openLibraryEdition, $0) }].compactMap { $0 },
            sourceItem: SourceItemKey(instance: key, item: workKey)
        )
    }

    /// The work's description as plain text, when it has one written in `script`; nil
    /// otherwise. One request.
    func description(workKey: String, script: WritingScript) async throws -> String? {
        guard let url = URL(string: "https://openlibrary.org\(workKey).json") else { return nil }
        let work = try JSONDecoder().decode(WorkResponse.self, from: try await get(url))
        let intro = OnlineBookDetailPresentationPolicy.sanitizeIntro(work.description?.text ?? "", indentParagraphs: false)
        return !intro.isEmpty && WritingScript(of: intro) == script ? intro : nil
    }

    /// Subjects as categories: Open Library's are long and many, so only short ones, at most 5.
    static func subjects(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 24 && !$0.contains(":") }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Requests

    private func get(_ url: URL) async throws -> Data {
        await pacer.wait(for: url.host ?? "")
        let page = try await fetcher.fetchPage(
            url: url, method: "GET", body: nil,
            headers: ["User-Agent": RemoteLibraryHTTPClient.userAgent, "Accept": "application/json"],
            baseURL: ""
        )
        guard (200...299).contains(page.statusCode) else { throw LookupError.status(page.statusCode, url.host ?? "") }
        return page.data
    }

    /// `?default=false` answers 404 for a cover Open Library does not have, instead of a blank
    /// image. Saved as `ol-<id>.jpg` in the filled covers' folder.
    private func saveCover(id: Int) async throws -> String? {
        let url = URL(string: "https://covers.openlibrary.org/b/id/\(id)-L.jpg?default=false")!
        await pacer.wait(for: url.host ?? "")
        let page = try await fetcher.fetchPage(
            url: url, method: "GET", body: nil, headers: ["User-Agent": RemoteLibraryHTTPClient.userAgent], baseURL: ""
        )
        if page.statusCode == 404 { return nil }
        guard (200...299).contains(page.statusCode) else { throw LookupError.status(page.statusCode, url.host ?? "") }
        guard BookCoverLoader.decodedCover(from: page.data) != nil else { return nil }
        let name = "ol-\(id).jpg"
        try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        try page.data.write(to: coverDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    enum LookupError: Error {
        case status(Int, String)
    }

    private struct SearchResponse: Decodable {
        var docs: [Doc]
        struct Doc: Decodable {
            var key: String?
            var subject: [String]?
            var editions: Editions?
        }
        struct Editions: Decodable {
            var docs: [Edition]
        }
        struct Edition: Decodable {
            var key: String?
            var cover_i: Int?
            var isbn: [String]?
        }
    }

    private struct WorkResponse: Decodable {
        var description: Description?

        /// A plain string, or `{"type": "/type/text", "value": "…"}`.
        enum Description: Decodable {
            case text(String)
            var text: String { switch self { case .text(let text): text } }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .text(try container.decode(Typed.self).value)
                }
            }

            private struct Typed: Decodable { var value: String }
        }
    }
}

/// The script a text is mostly written in, coarsely: enough to tell a Chinese, Japanese or
/// Korean book from an English description of it.
enum WritingScript: Equatable {
    case cjk, latin, other

    init(of text: String) {
        var cjk = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .otherLetter where scalar.value >= 0x2E80: cjk += 1
            case .lowercaseLetter, .uppercaseLetter: if scalar.value < 0x0250 { latin += 1 }
            default: break
            }
        }
        if cjk == 0 && latin == 0 { self = .other }
        else { self = cjk >= latin ? .cjk : .latin }
    }
}

/// Spaces requests to one host by a minimum interval: Open Library's terms allow one a
/// second. This is the terms' rate, not a wait for some state to settle.
actor RequestPacer {
    static let openLibrary = RequestPacer(interval: 1)

    private let interval: TimeInterval
    private var next: [String: Date] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func wait(for host: String) async {
        let now = Date()
        let slot = max(now, next[host] ?? now)
        next[host] = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // Cancelled: the run is stopping, and the request that follows is cancelled too.
            }
        }
    }
}
