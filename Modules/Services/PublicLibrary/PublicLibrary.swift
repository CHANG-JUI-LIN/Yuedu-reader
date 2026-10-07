import Foundation

enum PublicLibraryID: String, Sendable {
    case gutenberg = "builtin.gutenberg"
    case aozora = "builtin.aozora"
}

enum PublicLibrary {
    static let gutenberg = OPDSCatalog(id: PublicLibraryID.gutenberg.rawValue,
        name: "Project Gutenberg", url: "https://www.gutenberg.org/ebooks.opds/")

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

    static func gutenbergSearchURL(query: String, sortByDownloads: Bool = false) -> URL {
        var components = URLComponents(string: "https://www.gutenberg.org/ebooks/search.opds/")!
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved)!
        components.percentEncodedQuery = "query=" + encoded + (sortByDownloads ? "&sort_order=downloads" : "")
        return components.url!
    }
}

struct GutenbergShelf: Identifiable {
    let id: String
    let titleKey: String
    let symbol: String
    let url: URL

    static func shelves(language: String) -> [Self] {
        var shelves = [
            Self(id: "popular", titleKey: "熱門", symbol: "chart.bar", url: URL(string: "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads")!),
            Self(id: "latest", titleKey: "最新", symbol: "clock", url: URL(string: "https://www.gutenberg.org/ebooks/search.opds/?sort_order=release_date")!),
        ]
        let code = language.split(separator: "-").first.map(String.init) ?? language
        let names = ["zh": "中文", "ja": "日本語", "ko": "한국어"]
        if let name = names[code] {
            shelves.append(Self(id: code, titleKey: name, symbol: "character.book.closed",
                                url: PublicLibrary.gutenbergSearchURL(query: "l." + code, sortByDownloads: true)))
        }
        shelves.append(Self(id: "en", titleKey: "English", symbol: "character.book.closed",
                            url: PublicLibrary.gutenbergSearchURL(query: "l.en", sortByDownloads: true)))
        return shelves
    }
}
