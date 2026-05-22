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
    var singleUrl: Bool = true

    var isLegadoRuleBased: Bool { ruleArticles != nil && !(ruleArticles?.isEmpty ?? true) }
    var displayFaviconURL: String? { faviconURL ?? sourceIcon }
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
