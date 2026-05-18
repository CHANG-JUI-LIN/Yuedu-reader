import Foundation

struct RSSSource: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var homepageURL: String?
    var faviconURL: String?
    var customRule: String?
    var sortOrder: Int = 0
    var enabled: Bool = true

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

struct RSSItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var link: String
    var pubDate: Date?
    var description: String
    var contentHTML: String = ""
    var author: String?
    var sourceId: String
}

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
        author = item.author
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
