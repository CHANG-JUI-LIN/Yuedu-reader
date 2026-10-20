import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

/// Feeds write relative article links (`/2026/10/post.html`). Every parser stores them
/// absolute, resolved against the feed's homepage, else the feed URL — while an article's id
/// stays what earlier builds computed, because read/favorite state is keyed by it.
@Suite("RSS article links", .serialized)
@MainActor
struct RSSArticleLinkResolutionTests {
    private static let feedURL = "https://site.example/feeds/main.xml"

    // MARK: RSS 2.0

    @Test("RSS 2.0 resolves a relative link without a channel link against the feed URL")
    func rssResolvesAgainstFeedURLWhenChannelLinkIsMissing() throws {
        let item = try parsedItem(titled: "Post", in: Self.rssWithoutChannelLink)

        // An RSS 2.0 <link> is the external URL; `url` is the permalink guid.
        #expect(item.externalURL == "https://site.example/2026/10/post.html")
        // As before: the link exactly as an earlier build stored it.
        #expect(item.uniqueID == "/2026/10/post.html")
    }

    @Test("RSS 2.0 resolves against a relative channel link made absolute by the feed URL")
    func rssResolvesAgainstRelativeChannelLink() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Relative homepage</title>
            <link>/blog/</link>
            <item>
              <title>Post</title>
              <link>post.html</link>
              <description>A post whose link is relative to a relative homepage.</description>
            </item>
          </channel>
        </rss>
        """
        let item = try parsedItem(titled: "Post", in: xml)

        #expect(item.externalURL == "https://site.example/blog/post.html")
        #expect(item.uniqueID == "/blog/post.html")
    }

    @Test("RSS 2.0 resolves a relative permalink guid and keeps the guid as id")
    func rssResolvesRelativePermalinkGuid() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Guid only</title>
            <item>
              <title>Guid post</title>
              <guid>/p/7</guid>
              <description>An item that only has a permalink guid.</description>
            </item>
          </channel>
        </rss>
        """
        let item = try parsedItem(titled: "Guid post", in: xml)

        #expect(item.url == "https://site.example/p/7")
        #expect(item.uniqueID == "/p/7")
    }

    // MARK: JSON Feed

    @Test("JSON Feed resolves relative url and external_url against home_page_url")
    func jsonFeedResolvesRelativeLinks() throws {
        let json = """
        {"version": "https://jsonfeed.org/version/1.1", "title": "JSON blog",
         "home_page_url": "https://site.example/blog/",
         "items": [{"id": "42", "title": "JSON post", "url": "posts/42.html",
                    "external_url": "/elsewhere", "content_text": "Body"}]}
        """
        let item = try parsedItem(titled: "JSON post", in: json)

        #expect(item.url == "https://site.example/blog/posts/42.html")
        #expect(item.externalURL == "https://site.example/elsewhere")
        #expect(item.uniqueID == "42")
    }

    // MARK: RSS-in-JSON

    @Test("RSS-in-JSON resolves a relative link and still hashes the link as written")
    func rssInJSONResolvesRelativeLink() throws {
        let json = """
        {"rss": {"channel": {"title": "RSS in JSON", "link": "https://site.example/",
         "item": [{"title": "Hello", "link": "/a.html", "description": "A plain text body"}]}}}
        """
        let item = try parsedItem(titled: "Hello", in: json)

        #expect(item.externalURL == "https://site.example/a.html")
        // The guid-less id hashes title + link as an earlier build did, with the raw link.
        let digest = Insecure.MD5.hash(data: Data("Hello/a.html".utf8))
        #expect(item.uniqueID == digest.map { String(format: "%02hhx", $0) }.joined())
    }

    // MARK: Legacy parser

    @Test("legacy parser resolves a relative link and keeps it as written for the id")
    func legacyParserResolvesRelativeLink() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Legacy</title>
            <link>/news/</link>
            <item>
              <title>Legacy post</title>
              <link>/x.html</link>
            </item>
            <item>
              <title>Sibling post</title>
              <link>y.html</link>
            </item>
          </channel>
        </rss>
        """
        let items = RSSXMLParser(sourceId: "legacy", feedURL: Self.feedURL).parse(data: Data(xml.utf8))

        let legacy = try #require(items.first { $0.title == "Legacy post" })
        #expect(legacy.id == "/x.html")
        #expect(legacy.link == "https://site.example/x.html")
        let sibling = try #require(items.first { $0.title == "Sibling post" })
        #expect(sibling.id == "y.html")
        #expect(sibling.link == "https://site.example/news/y.html")
    }

    // MARK: Stored state

    @Test("a stored relative-link article keeps its id and state across a refresh")
    func storedArticleKeepsIDAndStateAcrossRefresh() throws {
        let (store, source) = try storeWithStoredRelativeArticle(id: "/2026/10/post.html")

        let parsed = try #require(RSSFeedParser.parse(data: Data(Self.rssWithoutChannelLink.utf8), url: Self.feedURL))
        let items = parsed.items.map { RSSItem(from: $0, sourceId: source.id) }
        let newArticles = store.mergeFetchedItems(items, for: source.id)

        try expectKeptState(in: store, sourceID: source.id, id: "/2026/10/post.html",
                            link: "https://site.example/2026/10/post.html", newArticles: newArticles)
    }

    @Test("a stored legacy-parser article keeps its id and state across a refresh")
    func storedLegacyArticleKeepsIDAndStateAcrossRefresh() throws {
        let (store, source) = try storeWithStoredRelativeArticle(id: "/2026/10/post.html")

        let items = RSSXMLParser(sourceId: source.id, feedURL: Self.feedURL)
            .parse(data: Data(Self.rssWithoutChannelLink.utf8))
        let newArticles = store.mergeFetchedItems(items, for: source.id)

        try expectKeptState(in: store, sourceID: source.id, id: "/2026/10/post.html",
                            link: "https://site.example/2026/10/post.html", newArticles: newArticles)
    }

    // MARK: Helpers

    private static let rssWithoutChannelLink = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>No homepage</title>
        <item>
          <title>Post</title>
          <link>/2026/10/post.html</link>
          <description>A post whose feed names no homepage.</description>
        </item>
      </channel>
    </rss>
    """

    private func parsedItem(titled title: String, in feed: String) throws -> ParsedFeedItem {
        let parsed = try #require(RSSFeedParser.parse(data: Data(feed.utf8), url: Self.feedURL))
        return try #require(parsed.items.first { $0.title == title })
    }

    /// What an earlier build left behind: a guid-less article keyed and linked by its
    /// relative link, read and favorited.
    private func storeWithStoredRelativeArticle(id: String) throws -> (RSSStore, RSSSource) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = RSSStore(storageDirectory: directory)
        let source = RSSSource(id: "relative-feed", name: "No homepage", url: Self.feedURL)
        store.addSource(source)

        let stored = RSSItem(id: id, title: "Post", link: id, sourceId: source.id)
        store.mergeFetchedItems([stored], for: source.id)
        store.markRead(articleId: id, isRead: true)
        store.toggleFavorite(articleId: id)
        return (store, source)
    }

    private func expectKeptState(in store: RSSStore, sourceID: String, id: String, link: String,
                                 newArticles: [RSSArticleRecord]) throws {
        let articles = store.articles(for: sourceID)
        #expect(articles.count == 1)
        #expect(newArticles.isEmpty)
        let article = try #require(articles.first)
        #expect(article.id == id)
        #expect(article.link == link)
        #expect(article.isRead)
        #expect(article.isFavorite)
    }
}
