import Combine
import Foundation

/// Immutable presentation data, captured before a carousel or a pushed page is built.
struct GutenbergBook: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let feedURL: URL?
    let entry: OPDSEntry?
    /// The text's language (`zh`, `en`), for 偏好閱讀語言 (5d-3d): the bundled lists say it per
    /// book, since a list mixes languages; a feed's entry says it when the feed does.
    let language: String?

    /// The id stays the XML feed's URL whatever the endpoint, so a bundled
    /// book keeps one identity; only the feed it loads follows the endpoint.
    init(id: Int, title: String, author: String, language: String? = nil, endpoint: GutenbergEndpoint = .current) {
        self.id = "https://www.gutenberg.org/ebooks/\(id).opds"
        self.title = title
        self.author = author
        self.language = language
        feedURL = endpoint.bookFeedURL(id: id)
        entry = nil
    }

    init?(entry: OPDSEntry) {
        let url = entry.navigationURL
        let name = url?.deletingPathExtension().lastPathComponent ?? ""
        let isBookLink = url?.host == "www.gutenberg.org"
            && url?.pathComponents.dropLast().last == "ebooks"
            && !name.isEmpty && name.allSatisfy(\.isNumber)
        guard entry.isBook || isBookLink else { return nil }
        id = entry.id
        title = String(entry.title.prefix(500))
        language = entry.language
        // Gutenberg's navigation feed puts the creator in Atom content; the
        // acquisition feed uses Atom author. This is its two-level OPDS schema.
        let creator = String((entry.author ?? (isBookLink ? entry.summary : nil) ?? "").prefix(500))
        // A navigation entry without a credited creator uses its download count
        // as content (official Chinese fixture, work 52323). That is not a name.
        author = creator.range(of: "^[0-9,]+ downloads?$", options: .regularExpression) == nil ? creator : ""
        // OPDS 2 list entries are complete books but omit the description and
        // author links; their `self` link is the full publication, loaded once
        // the book is selected, as an XML book feed is.
        let publication = entry.isBook ? entry.navigationURL.flatMap { GutenbergEndpoint.current.isPublication($0) ? $0 : nil } : nil
        feedURL = publication ?? (entry.isBook ? nil : url)
        self.entry = entry.isBook && publication == nil ? entry : nil
    }
}

extension GutenbergBook {
    /// Gutenberg's own cover (Phase 5 plan, decision 15), from the ebook number: the
    /// `cover.medium.jpg` each book's feed links as its image, which a shelf copy keeps as its
    /// `coverUrl`, so the copy shows the same cover. Nil when the id carries no number; that
    /// book keeps its generated cover. The list feeds' own thumbnails are 22-point glyphs, not
    /// covers, and fetching every book's feed for its link would be a request per card.
    var coverURL: URL? {
        ExternalIdentifier.gutenbergNumber(from: id).flatMap(PublicLibrary.gutenbergCoverURL(number:))
    }
}

enum PublicLibraryBook: Identifiable {
    case gutenberg(GutenbergBook)
    case aozora(AozoraWork, AozoraCatalogIndex)

    var id: String {
        switch self {
        case .gutenberg(let book): "gutenberg:" + book.id
        case .aozora(let work, _): Self.aozoraID(work)
        }
    }

    /// An Aozora work's id, for a caller holding the work without its index (Explore's home).
    static func aozoraID(_ work: AozoraWork) -> String { "aozora:" + work.id }
    var title: String {
        switch self {
        case .gutenberg(let book): book.title
        case .aozora(let work, _): work.title
        }
    }
    var author: String {
        switch self {
        case .gutenberg(let book): book.author
        case .aozora(let work, let index):
            work.credits.compactMap { index.personsByID[$0.person]?.name }.joined(separator: "、")
        }
    }
    /// Gutenberg's cover; nil for 青空文庫, which has none.
    var coverURL: URL? {
        switch self {
        case .gutenberg(let book): book.coverURL
        case .aozora: nil
        }
    }
    /// The key a copy of this book is found by (unified library 1a, 2c).
    var sourceItemKey: SourceItemKey {
        switch self {
        case .gutenberg(let book): SourceRecord.derived(from: book).key
        case .aozora(let work, _): SourceRecord.derived(from: work).key
        }
    }
}

struct PublicLibraryBookSelection: Identifiable {
    let id = UUID()
    let books: [PublicLibraryBook]
    let selectedID: String

    init?(books: [PublicLibraryBook], selectedID: String) {
        guard books.contains(where: { $0.id == selectedID }) else { return nil }
        var seen = Set<String>()
        self.books = books.filter { seen.insert($0.id).inserted }
        self.selectedID = selectedID
    }

    var selectedBook: PublicLibraryBook? { books.first { $0.id == selectedID } }
}

struct GutenbergAuthor: Identifiable, Hashable {
    /// As the catalog lists it, 「Austen, Jane」.
    let name: String
    let url: URL
    /// The record's label for what the person did (Author, Illustrator, Commentator…); nil
    /// when the record names none.
    var role: String? = nil
    var id: String { url.absoluteString }

    /// The person wrote the book, rather than illustrating, translating or introducing it.
    var isAuthor: Bool { role == nil || role == "Author" }

    var displayName: String { Self.displayName(name) }

    /// The localization key of the role, for its row in 作品詳情's 作品資訊.
    var roleKey: String {
        switch role {
        case "Translator": "翻訳者"
        case "Editor": "編者"
        case "Illustrator": "插畫"
        case "Commentator": "評註"
        default: "貢獻者"
        }
    }

    /// 「Austen, Jane」 as it is read, 「Jane Austen」, without the full name a catalog adds in
    /// parentheses. A name of any other shape (「King, Martin Luther, Jr.」, 「Lu Xun」) as listed.
    static func displayName(_ catalogName: String) -> String {
        let name = catalogName.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let parts = name.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return name }
        return parts[1] + " " + parts[0]
    }
}

extension [GutenbergAuthor] {
    /// Who wrote the book: those the record calls Author, everyone when it gives no roles,
    /// the first when it calls no one Author.
    var mainAuthors: [GutenbergAuthor] {
        let writers = filter(\.isAuthor)
        return writers.isEmpty ? Array(prefix(1)) : writers
    }

    /// Everyone else the record credits: commentators, illustrators, translators…
    var contributors: [GutenbergAuthor] {
        let main = Set(mainAuthors.map(\.id))
        return filter { !main.contains($0.id) }
    }
}

enum PublicLibraryAuthorDestination: Hashable {
    case gutenberg(GutenbergAuthor)
    case aozora(AozoraPerson, AozoraCatalogIndex)

    private var id: String {
        switch self {
        case .gutenberg(let author): "gutenberg:" + author.id
        case .aozora(let author, _): "aozora:" + author.id
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct GutenbergBookDetail {
    let item: RemoteLibraryItem
    let authors: [GutenbergAuthor]

    var mainAuthors: [GutenbergAuthor] { authors.mainAuthors }
    var contributors: [GutenbergAuthor] { authors.contributors }

    init(feed: OPDSFeed, endpoint: GutenbergEndpoint = .current) throws {
        let editions = feed.entries.filter(\.isBook)
        guard let preferred = editions.min(by: {
            ($0.bestAcquisition?.preference ?? 99) < ($1.bestAcquisition?.preference ?? 99)
        }) else { throw OPDSError.invalidFeed }
        var combined = preferred
        var seenFormats = Set<URL>()
        combined.acquisitions = editions.flatMap(\.acquisitions)
            .filter { seenFormats.insert($0.url).inserted }
            .sorted { $0.preference < $1.preference }
        // OPDS 2 publications carry no text/html link; their identifier is the
        // book's page on gutenberg.org.
        combined.alternateURL = preferred.alternateURL ?? feed.alternateURL ?? Self.officialPage(preferred.id)
        // The XML catalog's content is the book's bibliographic record, one labelled
        // paragraph per field (Title, Credits, Summary, EBook No., Downloads, Rights…). Its
        // description is the Summary field alone; a record without one has none. OPDS 2's
        // `description` is the description itself.
        if endpoint == .xml { combined.summary = Self.recordSummary(preferred.summary) }
        item = RemoteLibraryBookRoute(entry: combined, connectionID: PublicLibraryID.gutenberg.rawValue).item
        var seenAuthors = Set<URL>()
        let credits = endpoint == .xml ? Self.recordCredits(preferred.summary) : []
        authors = editions.flatMap(\.relatedLinks).compactMap { link in
            guard endpoint.isAuthorCatalog(link.url), seenAuthors.insert(link.url).inserted else { return nil }
            let name = preferred.authorNames.first { link.title.contains($0) }
                ?? link.title.replacingOccurrences(of: "By ", with: "", options: .anchored)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            let role = credits.first { $0.value == name || $0.value.hasPrefix(name + ",") }?.label
            return GutenbergAuthor(name: name, url: link.url, role: role)
        }
    }

    /// The record's people, one field each: 「Illustrator: Thomson, Hugh, 1860-1920」. A label
    /// is one or a few words; a field such as Summary or Contents is not a credit.
    static func recordCredits(_ record: String?) -> [(label: String, value: String)] {
        guard let record else { return [] }
        let labels: Set<String> = ["Author", "Editor", "Translator", "Illustrator", "Commentator", "Contributor",
                                   "Compiler", "Annotator", "Adapter", "Photographer", "Composer", "Arranger",
                                   "Author of introduction, etc.", "Author of afterword, colophon, etc."]
        return record.split(separator: "\n").compactMap { line in
            guard let colon = line.range(of: ": ") else { return nil }
            let label = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard labels.contains(label) else { return nil }
            return (label, String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// The record's Summary field. The parser keeps one field per line. Before d7aa65ab it
    /// flattened the record to one line, and copies imported then hold that in their sidecar
    /// (`BookStore.copyIntroValues`): there the field ends where the next field's label starts.
    static func recordSummary(_ record: String?) -> String? {
        let label = "Summary:"
        guard let record else { return nil }
        let field: Substring
        if record.contains("\n") {
            guard let line = record.split(separator: "\n").first(where: { $0.hasPrefix(label) }) else { return nil }
            field = line.dropFirst(label.count)
        } else {
            guard let start = record.range(of: label) else { return nil }
            let rest = record[start.upperBound...]
            field = rest.range(of: flattenedNextField, options: .regularExpression).map { rest[..<$0.lowerBound] } ?? rest
        }
        let text = field.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The labels Gutenberg's record writes after Summary, in a flattened record.
    private static let flattenedNextField = #"\s(?:Reading Level|Author|Editor|Translator|Illustrator|Contributor|Commentator|Compiler|Language|EBook No\.|Release Date|Published|Original Publication|LoC No\.|LoCC|Subject|Category|Rights|Downloads|Copyright Status|Most Recently Updated):"#

    private static func officialPage(_ identifier: String) -> URL? {
        guard let url = URL(string: identifier), url.scheme == "https", url.host == "www.gutenberg.org",
              url.pathComponents.dropLast().last == "ebooks", url.lastPathComponent.allSatisfy(\.isNumber) else { return nil }
        return url
    }
}

/// One transport/parser for all OPDS browsing and selected-book requests.
enum PublicLibraryFeedTransport {
    @MainActor static func fetch(_ url: URL) async throws -> OPDSFeed {
        #if DEBUG
        // Explicit UI-test transport, never enabled in a normal launch or Release.
        // Fixtures exercise gestures without touching the unavailable Aozora site
        // or multiplying Gutenberg traffic during UI regression runs.
        if let directory = ProcessInfo.processInfo.environment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] {
            // By path; a test that tells two lists of one path apart (熱門 and 最新 are both
            // `ebooks/search.opds`, 5d-6a) writes `<path>@<query>.xml` for one of them.
            let folder = URL(fileURLWithPath: directory)
            let name = url.path.split(separator: "/").joined(separator: "_")
            let byQuery = url.query.map { folder.appendingPathComponent(name + "@" + $0 + ".xml") }
            let file = byQuery.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? folder.appendingPathComponent(name + ".xml")
            let data = try Data(contentsOf: file)
            return try OPDSClient.parseFeed(data: data, feedURL: url)
        }
        #endif
        let client = RemoteLibraryConnectionStore.shared.client(for: PublicLibrary.gutenberg)
        return try await client.fetchFeed(url)
    }
}

@MainActor
final class GutenbergBookPageModel: ObservableObject {
    @Published private(set) var detail: GutenbergBookDetail?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    private var attempted = false
    private let book: GutenbergBook
    private let fetch: (URL) async throws -> OPDSFeed

    /// The default fetch goes through `GutenbergProvider`, the storefront's one fetch path
    /// (unified library 2a).
    init(book: GutenbergBook, fetch: @escaping (URL) async throws -> OPDSFeed = { try await SourceProviderRegistry.shared.gutenberg.feed($0, isSearch: false) }) {
        self.book = book
        self.fetch = fetch
    }

    func load(force: Bool = false) async {
        guard !isLoading, force || !attempted else { return }
        isLoading = true
        attempted = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let feed: OPDSFeed
            if let entry = book.entry { feed = OPDSFeed(entries: [entry]) }
            else if let url = book.feedURL { feed = try await fetch(url) }
            else { throw OPDSError.invalidURL }
            try Task.checkCancellation()
            detail = try GutenbergBookDetail(feed: feed)
        } catch {
            if Task.isCancelled { attempted = false; return }
            AppLogger.network("Gutenberg book detail failed", error: SourceFailure.loggable(error), context: ["book": book.id])
            errorMessage = error.localizedDescription
        }
    }
}
