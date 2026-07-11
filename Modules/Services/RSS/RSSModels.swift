import Foundation

// MARK: - Feed Type

enum FeedType: String, Sendable {
    case rss
    case atom
    case jsonFeed
    case rssInJSON
    case unknown
    case notAFeed
}

// MARK: - Parsed Author

struct ParsedAuthor: Hashable, Codable, Sendable {
    var name: String?
    var url: String?
    var avatarURL: String?
    var emailAddress: String?

    var isEmpty: Bool { name == nil && url == nil && avatarURL == nil && emailAddress == nil }
}

// MARK: - Parsed Attachment

struct ParsedAttachment: Hashable, Codable, Sendable {
    var url: String
    var mimeType: String?
    var title: String?
    var sizeInBytes: Int?
    var durationInSeconds: Int?

    init?(url: String, mimeType: String?, title: String?, sizeInBytes: Int?, durationInSeconds: Int?) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.url = trimmed
        self.mimeType = mimeType
        self.title = title
        self.sizeInBytes = sizeInBytes
        self.durationInSeconds = durationInSeconds
    }
}

// MARK: - Parsed Hub (WebSub)

struct ParsedHub: Hashable, Codable, Sendable {
    var type: String
    var url: String
}

// MARK: - Parsed Feed Item (unified intermediate representation)

struct ParsedFeedItem: Hashable, Sendable {
    var uniqueID: String
    var feedURL: String
    var url: String?
    var externalURL: String?
    var title: String?
    var language: String?
    var contentHTML: String?
    var contentText: String?
    var summary: String?
    var imageURL: String?
    var bannerImageURL: String?
    var datePublished: Date?
    var dateModified: Date?
    var authors: Set<ParsedAuthor>?
    var tags: Set<String>?
    var attachments: Set<ParsedAttachment>?

    func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueID)
        hasher.combine(feedURL)
    }
}

// MARK: - Parsed Feed Info (feed-level metadata)

struct ParsedFeedInfo: Sendable {
    var type: FeedType
    var title: String?
    var homePageURL: String?
    var feedURL: String?
    var language: String?
    var feedDescription: String?
    var nextURL: String?
    var iconURL: String?
    var faviconURL: String?
    var authors: Set<ParsedAuthor>?
    var expired: Bool = false
    var hubs: Set<ParsedHub>?
    var items: Set<ParsedFeedItem>

    var bestIconURL: String? { iconURL ?? faviconURL }
}

// MARK: - RSS Source

struct RSSSource: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var homepageURL: String?
    var faviconURL: String?
    var customRule: String?
    var sortOrder: Int = 0
    var enabled: Bool = true
    var newArticleNotificationsEnabled: Bool = true

    // Legado-compatible fields
    var sourceGroup: String?
    var sourceIcon: String?
    var ruleArticles: String?
    var ruleTitle: String?
    var ruleLink: String?
    var ruleDescription: String?
    var ruleContent: String?
    var rulePubDate: String?
    var ruleImage: String?
    var header: String?
    var sortUrl: String?
    var articleStyle: Int = 0
    var customOrder: Int = 0
    var enableJs: Bool = true
    var enabledCookieJar: Bool = false
    var lastUpdateTime: Double = 0
    var loadWithBaseUrl: Bool = true
    var singleUrl: Bool = false

    // Extra Legado fields kept for lossless round-trip and future use.
    // All optional so JSON saved by older app versions still decodes.
    var ruleNextPage: String?
    var sourceComment: String?
    var variableComment: String?
    var concurrentRate: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var jsLib: String?
    var style: String?
    var injectJs: String?
    var contentWhitelist: String?
    var contentBlacklist: String?
    var shouldOverrideUrlLoading: String?
    /// Set at Legado JSON import time; nil for hand-added feeds and legacy storage.
    var importedFromLegado: Bool?

    var isLegadoRuleBased: Bool { ruleArticles != nil && !(ruleArticles?.isEmpty ?? true) }
    var displayFaviconURL: String? { faviconURL ?? sourceIcon }

    /// Non-empty sortUrl means the source has Legado category tabs.
    var hasSortCategories: Bool {
        guard let sortUrl else { return false }
        return !sortUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fields only a Legado import would populate — hand-added feeds never set these.
    var hasLegadoSignature: Bool {
        if importedFromLegado == true { return true }
        if sourceIcon?.isEmpty == false { return true }
        if header?.isEmpty == false { return true }
        if lastUpdateTime > 0 { return true }
        if ruleTitle != nil || ruleLink != nil || ruleDescription != nil
            || ruleContent != nil || rulePubDate != nil || ruleImage != nil { return true }
        return false
    }

    /// Legado semantics: singleUrl sources open sourceUrl directly as a web page
    /// (no feed fetch, no article list). Restricted to Legado-flavored sources so
    /// hand-added feeds whose stored singleUrl was polluted by the old default
    /// (true) keep their normal feed behavior.
    var opensAsWebPage: Bool {
        singleUrl && !isLegadoRuleBased && !hasSortCategories && hasLegadoSignature
    }

    /// Best-effort URL for opening this source as a web page.
    var webPageURL: URL? {
        RSSSource.normalizedWebURL(from: url)
    }

    /// Normalize a Legado sourceUrl into an openable http(s) URL:
    /// strips `,{json options}` suffixes and `#comment` fragments Legado allows,
    /// adds a missing scheme, and percent-encodes non-ASCII characters.
    static func normalizedWebURL(from raw: String) -> URL? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Strip Legado URL option suffix: "https://x.com,{'method':'POST'}"
        if let range = cleaned.range(of: #"\s*,\s*\{"#, options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound])
        }

        if !cleaned.lowercased().hasPrefix("http://") && !cleaned.lowercased().hasPrefix("https://") {
            // Only treat host-like strings as URLs (e.g. "shuyuan.nyasama.net").
            guard cleaned.contains("."), !cleaned.contains(" ") else { return nil }
            cleaned = "https://" + cleaned
        }

        if let url = URL(string: cleaned) {
            guard url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
            return url.upgradedToHTTPS()
        }

        // Retry with percent-encoding for URLs containing CJK or other non-ASCII characters.
        guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))),
              let url = URL(string: encoded),
              url.scheme == "http" || url.scheme == "https", url.host != nil else {
            return nil
        }
        return url.upgradedToHTTPS()
    }
}

// MARK: - Legado sortUrl entries

/// One Legado RSS category tab: `名称::URL` from sortUrl.
struct RSSSortEntry: Equatable, Identifiable {
    var name: String
    var url: String
    var id: String { "\(name)::\(url)" }
}

enum LegadoSortURLParser {
    /// Split a (already JS-evaluated, if needed) sortUrl string into entries.
    /// Matches Legado `RssSource.sortUrls()`: split on `(&&|\n)+`, each entry `name::url`,
    /// entries without `::` are ignored; empty result falls back to the source URL.
    static func entries(from sortUrl: String?, fallbackURL: String) -> [RSSSortEntry] {
        var result: [RSSSortEntry] = []
        if let sortUrl, !sortUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Legado splits on the regex (&&|\n)+
            let segments = sortUrl
                .replacingOccurrences(of: "&&", with: "\n")
                .components(separatedBy: "\n")
            for segment in segments {
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let range = trimmed.range(of: "::") else { continue }
                let name = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                result.append(RSSSortEntry(name: name, url: url))
            }
        }
        if result.isEmpty {
            result.append(RSSSortEntry(name: "", url: fallbackURL))
        }
        return result
    }

    /// Whether the sortUrl needs JavaScript evaluation before splitting.
    static func needsJSEvaluation(_ sortUrl: String) -> Bool {
        let trimmed = sortUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<js>") || trimmed.lowercased().hasPrefix("@js:")
    }

    /// Extract the JS body from a `<js>…</js>` or `@js:…` sortUrl.
    static func jsBody(_ sortUrl: String) -> String? {
        let trimmed = sortUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("<js>") {
            guard let end = trimmed.range(of: "</js>", options: [.backwards, .caseInsensitive]) else {
                return String(trimmed.dropFirst(4))
            }
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<end.lowerBound])
        }
        return nil
    }
}

struct RSSFolder: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var sortOrder: Int = 0
}

enum RSSSmartFeedKind: String, CaseIterable, Identifiable, Codable {
    case today
    case allUnread
    case starred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            return localized("今天")
        case .allUnread:
            return localized("所有未讀")
        case .starred:
            return localized("已加星號")
        }
    }

    var systemImage: String {
        switch self {
        case .today:
            return "calendar"
        case .allUnread:
            return "tray.full"
        case .starred:
            return "star.fill"
        }
    }
}

// MARK: - RSS Item (parser output)

struct RSSItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var link: String
    var pubDate: Date?
    var dateModified: Date?
    var description: String
    var contentHTML: String = ""
    var author: String?
    var imageURL: String?
    var bannerImageURL: String?
    var sourceId: String
    var language: String?
    var tags: [String] = []

    init(id: String = UUID().uuidString,
         title: String,
         link: String,
         pubDate: Date? = nil,
         dateModified: Date? = nil,
         description: String = "",
         contentHTML: String = "",
         author: String? = nil,
         imageURL: String? = nil,
         bannerImageURL: String? = nil,
         sourceId: String = "",
         language: String? = nil,
         tags: [String] = []) {
        self.id = id
        self.title = title
        self.link = link
        self.pubDate = pubDate
        self.dateModified = dateModified
        self.description = description
        self.contentHTML = contentHTML
        self.author = author
        self.imageURL = imageURL
        self.bannerImageURL = bannerImageURL
        self.sourceId = sourceId
        self.language = language
        self.tags = tags
    }

    /// Convert from unified ParsedFeedItem and source ID.
    /// The caller is responsible for generating a plain-text summary from `contentHTML`.
    init(from parsed: ParsedFeedItem, sourceId: String, summary: String = "") {
        self.id = parsed.uniqueID
        self.title = parsed.title ?? ""
        self.link = parsed.url ?? parsed.externalURL ?? ""
        self.pubDate = parsed.datePublished
        self.dateModified = parsed.dateModified
        self.contentHTML = parsed.contentHTML ?? ""
        self.author = parsed.authors?.first?.name
        self.imageURL = parsed.imageURL
        self.bannerImageURL = parsed.bannerImageURL
        self.sourceId = sourceId
        self.language = parsed.language
        self.tags = parsed.tags.map { Array($0) } ?? []
        self.description = summary
    }
}

// MARK: - Article Status & Record

struct RSSArticleStatus: Codable, Equatable {
    var articleId: String
    var isRead: Bool = false
    var isFavorite: Bool = false
    var lastOpenedAt: Date?
    var readerScrollY: Double = 0
}

struct RSSArticleRecord: Codable, Identifiable, Equatable {
    var id: String
    var sourceId: String
    var title: String
    var link: String
    var summary: String
    var contentHTML: String
    var pubDate: Date?
    var dateModified: Date?
    var author: String?
    var imageURL: String?
    var fetchedAt: Date
    var fullText: String?
    var fullTextHTML: String?
    var fullTextFetchedAt: Date?
    var isRead: Bool = false
    var isFavorite: Bool = false
    var lastOpenedAt: Date?
    var readerScrollY: Double = 0

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceId
        case title
        case link
        case summary
        case contentHTML
        case pubDate
        case dateModified
        case author
        case imageURL
        case fetchedAt
        case fullText
        case fullTextHTML
        case fullTextFetchedAt
        case isRead
        case isFavorite
        case lastOpenedAt
        case readerScrollY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceId = try container.decode(String.self, forKey: .sourceId)
        title = try container.decode(String.self, forKey: .title)
        link = try container.decode(String.self, forKey: .link)
        summary = try container.decode(String.self, forKey: .summary)
        contentHTML = try container.decodeIfPresent(String.self, forKey: .contentHTML) ?? ""
        pubDate = try container.decodeIfPresent(Date.self, forKey: .pubDate)
        dateModified = try container.decodeIfPresent(Date.self, forKey: .dateModified)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        fullText = try container.decodeIfPresent(String.self, forKey: .fullText)
        fullTextHTML = try container.decodeIfPresent(String.self, forKey: .fullTextHTML)
        fullTextFetchedAt = try container.decodeIfPresent(Date.self, forKey: .fullTextFetchedAt)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        readerScrollY = try container.decodeIfPresent(Double.self, forKey: .readerScrollY) ?? 0
    }

    init(item: RSSItem, fetchedAt: Date = Date(), status: RSSArticleStatus? = nil) {
        id = item.id
        sourceId = item.sourceId
        title = item.title
        link = item.link
        summary = item.description
        contentHTML = item.contentHTML
        pubDate = item.pubDate
        dateModified = item.dateModified
        author = item.author
        imageURL = item.imageURL
        self.fetchedAt = fetchedAt
        fullText = nil
        fullTextHTML = nil
        fullTextFetchedAt = nil
        isRead = status?.isRead ?? false
        isFavorite = status?.isFavorite ?? false
        lastOpenedAt = status?.lastOpenedAt
        readerScrollY = status?.readerScrollY ?? 0
    }

    func applying(status: RSSArticleStatus?) -> RSSArticleRecord {
        guard let status else { return self }
        var copy = self
        copy.isRead = status.isRead
        copy.isFavorite = status.isFavorite
        copy.lastOpenedAt = status.lastOpenedAt
        copy.readerScrollY = status.readerScrollY
        return copy
    }
}
