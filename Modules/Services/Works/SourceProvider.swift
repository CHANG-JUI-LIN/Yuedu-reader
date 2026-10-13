import Foundation

// Unified library 2a: what every content source offers, whatever its protocol (design §5,
// §9). A provider wraps the client that already talks to the source; the existing browse
// models fetch through it, so there is one browse path per kind.

/// Whether a provider is listed, and why not.
enum ProviderAvailability: Hashable, Sendable {
    case available
    /// The China-region gate (`PublicLibraryAvailability`).
    case hiddenInRegion
    case needsSetup
    /// A bundled catalog not read yet (Aozora).
    case catalogNotReady
}

@MainActor
protocol SourceProvider: AnyObject {
    var instance: SourceInstanceKey { get }
    var displayName: String { get }
    var availability: ProviderAvailability { get }
}

/// How a source can be searched (design §5, `CatalogSearching.searchPolicy`).
enum CollectionSearchSupport: Hashable, Sendable {
    /// Not known until the source has answered once (an OPDS feed advertises its search).
    case unknown
    case none
    /// Filtered locally as the reader types: the shelf, Aozora.
    case asYouType
    /// Sent to the server when submitted: OPDS, Calibre.
    case onSubmit
    /// Only on the reader's explicit request (Gutenberg's terms, audit §9).
    case explicitRequestOnly
}

struct CollectionCapabilities: Hashable, Sendable {
    var search: CollectionSearchSupport
    var paginates: Bool
}

/// A place inside a source: a folder, a navigation feed, a shelf group, an author. `id` is the
/// provider's own (a URL, a group name, an index path) and means nothing to anyone else.
struct CollectionLocation: Hashable, Codable, Sendable {
    var id: String
    var title: String
}

/// Where the next page starts: an OPDS `rel=next` URL, an offset.
struct CollectionCursor: Hashable, Codable, Sendable {
    var value: String
}

enum CollectionEntry: Hashable, Sendable {
    case location(CollectionLocation)
    case item(SourceRecord, WorkSummary, ItemOpening)
    /// An RSS article (訂閱的最新文章, unified library 5g): not a work, so it has no record,
    /// no summary and no 作品詳情 (design §13.8: articles are never made `Book`s).
    case article(SubscriptionArticle)
}

/// What opening an item needs, frozen when the entry is made, so a destination never
/// re-reads a list that may have changed (CLAUDE.md, "Freeze data at search navigation
/// boundaries"). Each case is the snapshot today's route for that kind is built from
/// (unified library 5b; the home maps them in 5c).
enum ItemOpening: Hashable, Sendable {
    /// A copy on the shelf.
    case copy(UUID)
    /// An OPDS or Calibre entry; 作品詳情 reads it as `RemoteLibraryBookRoute(entry:connectionID:).item`.
    case opdsEntry(OPDSEntry, connectionID: String)
    /// A WebDAV file; 作品詳情 reads it as `RemoteLibraryBookRoute(entry:connectionID:).item`.
    case webDAVFile(WebDAVBrowseClient.Entry, connectionID: String)
    case gutenberg(GutenbergBook)
    case aozora(AozoraWork)
    /// A book-source result: `ExploreNavigationRoute.book`.
    case onlineBook(FrozenOnlineBook)
}

/// An `OnlineBook` in a `Hashable` value, compared by its id as `ExploreNavigationRoute.book` is.
struct FrozenOnlineBook: Hashable, Sendable {
    let book: OnlineBook

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.book.id == rhs.book.id }
    func hash(into hasher: inout Hasher) { hasher.combine(book.id) }
}

struct CollectionPage: Hashable, Sendable {
    var entries: [CollectionEntry]
    var next: CollectionCursor?
}

/// A cover, wherever it lives.
enum CoverReference: Hashable, Codable, Sendable {
    /// A file the app keeps, by absolute path: a copy's saved cover, the WebDAV index's
    /// cover. Never persisted, so the path is the running container's.
    case copyFile(String)
    case remote(URL, headers: [String: String])
    /// No cover: `GeneratedBookCover` draws one from this seed (design §13.9).
    case generated(seed: String)
}

/// What a row, card or result shows of an item. Bounded and plain when built (design §5;
/// audit §11.5), so nothing a source sends can make layout expensive.
struct WorkSummary: Hashable, Sendable {
    var title: String
    var authors: [String]
    var cover: CoverReference?
    var blurb: String?
    var language: String?
    var contentKind: ContentKind
    /// The source's own category, when it names one (decision 37: never made up).
    var category: String?

    static let titleLimit = 500
    static let authorLimit = 20
    static let authorLengthLimit = 200
    static let blurbLimit = 300
    static let categoryLimit = 40

    /// `blurb` and `category` must already be plain text; `OPDSClient.plainMetadata` turns HTML
    /// into it.
    init(title: String, authors: [String], cover: CoverReference?, blurb: String?, language: String?, contentKind: ContentKind,
         category: String? = nil) {
        self.title = String(title.prefix(Self.titleLimit))
        self.authors = authors.prefix(Self.authorLimit).map { String($0.prefix(Self.authorLengthLimit)) }
        self.cover = cover
        self.blurb = blurb.map { String($0.prefix(Self.blurbLimit)) }.flatMap { $0.isEmpty ? nil : $0 }
        self.language = language
        self.contentKind = contentKind
        self.category = category.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.categoryLimit)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A book source's `kind` mixes its tags: genre, status, a date, a word count. The first one
    /// with no digit in it, which is the genre the sources put first. A plain split: a search
    /// route builds this where its destination is made (Technotes/iOS17SearchWatchdogPostmortem.md,
    /// guardrail 5).
    nonisolated static func category(fromSourceKind kind: String) -> String? {
        let separators = CharacterSet(charactersIn: ",，、|/;；").union(.whitespacesAndNewlines)
        return kind.prefix(1_000).components(separatedBy: separators)
            .first { tag in !tag.isEmpty && !tag.contains { ("0"..."9").contains($0) || ("０"..."９").contains($0) } }
            .map { String($0.prefix(categoryLimit)) }
    }
}

@MainActor
protocol CollectionBrowsing: SourceProvider {
    /// Answers from what the provider already knows; it never sends a request of its own.
    func capabilities() async -> CollectionCapabilities
    /// One page of `location` (the root when nil). Throws `SourceFailure`; an empty page is
    /// not a failure.
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage
}

// MARK: - Failures

/// Why a source could not answer (design §5's `SourceFailure`), typed so empty and failed can
/// be told apart. The text is the underlying error's own, so nothing on screen changes, and
/// the underlying error is what gets logged.
struct SourceFailure: Error, LocalizedError {
    enum Kind: String, Codable, Hashable, Sendable {
        case authentication, network, timeout, parse, rejected, invalidAddress, connectionRemoved, unavailable, other
    }

    let kind: Kind
    /// The HTTP status of a `rejected` answer.
    let status: Int?
    let underlying: any Error

    var errorDescription: String? { underlying.localizedDescription }

    init(kind: Kind, status: Int? = nil, underlying: any Error) {
        self.kind = kind
        self.status = status
        self.underlying = underlying
    }

    /// A connection the reader has removed.
    static var connectionRemoved: SourceFailure {
        SourceFailure(kind: .connectionRemoved, underlying: Message(text: localized("書庫連線已移除，請重新加入伺服器。")))
    }

    /// Classifies `error`. Cancellation is rethrown as it is: callers' cancellation guards
    /// depend on it.
    static func classify(_ error: any Error) throws -> SourceFailure {
        if error is CancellationError { throw error }
        if let failure = error as? SourceFailure { return failure }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: throw error
            case .timedOut: return SourceFailure(kind: .timeout, underlying: error)
            case .userAuthenticationRequired, .userCancelledAuthentication: return SourceFailure(kind: .authentication, underlying: error)
            case .badURL, .unsupportedURL: return SourceFailure(kind: .invalidAddress, underlying: error)
            default: return SourceFailure(kind: .network, underlying: error)
            }
        }
        if let opds = error as? OPDSError {
            switch opds {
            case .authenticationFailed, .loginPage: return SourceFailure(kind: .authentication, underlying: error)
            case .http(let status): return SourceFailure(kind: .rejected, status: status, underlying: error)
            case .noData, .invalidFeed: return SourceFailure(kind: .parse, underlying: error)
            case .invalidURL, .unsupportedScheme: return SourceFailure(kind: .invalidAddress, underlying: error)
            }
        }
        if error is DecodingError { return SourceFailure(kind: .parse, underlying: error) }
        return SourceFailure(kind: .other, underlying: error)
    }

    /// The underlying error to log: diagnostics keep its domain and code.
    static func loggable(_ error: any Error) -> any Error {
        (error as? SourceFailure)?.underlying ?? error
    }

    struct Message: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
}
