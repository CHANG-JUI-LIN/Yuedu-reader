import Foundation

enum PublicLibraryID: String, Sendable {
    case gutenberg = "builtin.gutenberg"
    case aozora = "builtin.aozora"
}

/// Where the built-in Gutenberg connection reads its catalog. Every Gutenberg
/// URL the app builds comes from here, so a switch changes one value.
enum GutenbergEndpoint: Sendable {
    /// The XML OPDS feeds on www.gutenberg.org, to be retired in 2027.
    case xml
    /// Gutenberg's OPDS 2 development service (plan decisions 18 and 20).
    case opds2Development

    /// Debug builds launched with `-gutenberg-opds2-dev` (the shared scheme's
    /// Run action passes it) use the OPDS 2 development service; tests,
    /// Release and TestFlight builds use the XML feeds. Delete this switch and
    /// `opds2Development` when `builtin.gutenberg` moves to Gutenberg's
    /// production OPDS 2 URL: the development service must never ship.
    static let current: Self = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-gutenberg-opds2-dev") { return .opds2Development }
        #endif
        return .xml
    }()

    var rootURL: URL {
        switch self {
        case .xml: URL(string: "https://www.gutenberg.org/ebooks.opds/")!
        case .opds2Development: URL(string: "https://opds-test.pglaf.org/opds/")!
        }
    }

    func searchURL(query: String, sortByDownloads: Bool = false) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved)!
        switch self {
        case .xml:
            return listURL("query=" + encoded + (sortByDownloads ? "&sort_order=downloads" : ""))
        case .opds2Development:
            return listURL("query=" + encoded + (sortByDownloads ? "&sort=downloads&sort_order=desc" : ""))
        }
    }

    var popularURL: URL {
        switch self {
        case .xml: listURL("sort_order=downloads")
        case .opds2Development: listURL("sort=downloads&sort_order=desc")
        }
    }

    var latestURL: URL {
        switch self {
        case .xml: listURL("sort_order=release_date")
        case .opds2Development: listURL("sort=release_date&sort_order=desc")
        }
    }

    /// Most downloaded books in one language (ISO 639-1 code).
    func languageURL(_ code: String) -> URL {
        switch self {
        case .xml: searchURL(query: "l." + code, sortByDownloads: true)
        case .opds2Development: listURL("lang=" + code + "&sort=downloads&sort_order=desc")
        }
    }

    func bookFeedURL(id: Int) -> URL {
        switch self {
        case .xml: URL(string: "https://www.gutenberg.org/ebooks/\(id).opds")!
        case .opds2Development: URL(string: "https://opds-test.pglaf.org/opds/publications?id=\(id)")!
        }
    }

    /// Whether a link is one book's full OPDS 2 publication document.
    func isPublication(_ url: URL) -> Bool {
        switch self {
        case .xml: return false
        case .opds2Development:
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return url.host == rootURL.host && url.path == "/opds/publications" && items.contains { $0.name == "id" }
        }
    }

    /// Whether a link is an author's catalog: `related` Atom links in the XML
    /// feeds, the contributor's links in OPDS 2.
    func isAuthorCatalog(_ url: URL) -> Bool {
        switch self {
        case .xml:
            return url.host == "www.gutenberg.org" && url.path.hasPrefix("/ebooks/author/")
        case .opds2Development:
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return url.host == rootURL.host && url.path == "/opds/search" && items.contains { $0.name == "author_id" }
        }
    }

    private func listURL(_ query: String) -> URL {
        var components: URLComponents
        switch self {
        case .xml: components = URLComponents(string: "https://www.gutenberg.org/ebooks/search.opds/")!
        case .opds2Development: components = URLComponents(string: "https://opds-test.pglaf.org/opds/search")!
        }
        components.percentEncodedQuery = query
        return components.url!
    }
}

enum PublicLibrary {
    static var gutenberg: OPDSCatalog { gutenbergConnection(.current) }

    static func gutenbergConnection(_ endpoint: GutenbergEndpoint) -> OPDSCatalog {
        OPDSCatalog(id: PublicLibraryID.gutenberg.rawValue, name: "Project Gutenberg", url: endpoint.rootURL.absoluteString)
    }

    static func connection(id: String) -> OPDSCatalog? {
        id == gutenberg.id ? gutenberg : nil
    }

    /// Gutenberg lists show only the entry's thumbnail, never its full cover:
    /// embedded data in the XML feeds, the small `cover.small.jpg` in OPDS 2
    /// (decision 19). The full cover loads only on the book's detail.
    static func listCoverURL(for entry: OPDSEntry, connectionID: String) -> URL? {
        guard connectionID == PublicLibraryID.gutenberg.rawValue else { return entry.displayCoverURL }
        return entry.thumbnailURL
    }

    static func gutenbergSearchURL(query: String, sortByDownloads: Bool = false,
                                   endpoint: GutenbergEndpoint = .current) -> URL {
        endpoint.searchURL(query: query, sortByDownloads: sortByDownloads)
    }
}

struct GutenbergShelf: Identifiable {
    let id: String
    let titleKey: String
    let symbol: String
    let url: URL

    static func shelves(language: String, endpoint: GutenbergEndpoint = .current) -> [Self] {
        var shelves = [
            Self(id: "popular", titleKey: "熱門", symbol: "chart.bar", url: endpoint.popularURL),
            Self(id: "latest", titleKey: "最新", symbol: "clock", url: endpoint.latestURL),
        ]
        let code = language.split(separator: "-").first.map(String.init) ?? language
        let names = ["zh": "中文", "ja": "日本語", "ko": "한국어"]
        if let name = names[code] {
            shelves.append(Self(id: code, titleKey: name, symbol: "character.book.closed", url: endpoint.languageURL(code)))
        }
        shelves.append(Self(id: "en", titleKey: "English", symbol: "character.book.closed", url: endpoint.languageURL("en")))
        return shelves
    }
}
