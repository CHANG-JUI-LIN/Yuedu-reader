import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS", .serialized)
struct RSSStoreTests {
    @Test("RSS parser produces stable clean article records")
    func parserProducesStableCleanArticleRecords() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>BBC</title>
            <link>https://www.bbc.com/news</link>
            <image>
              <url>https://www.bbc.com/favicon.ico</url>
            </image>
            <item>
              <title><![CDATA[<b>Test &amp; Title</b>]]></title>
              <link>https://example.com/article-1</link>
              <pubDate>Thu, 07 May 2026 10:00:00 GMT</pubDate>
              <description><![CDATA[
                <main>
                  <script>bad()</script>
                  <p>Article Information</p>
                  <p>Author, BBC News</p>
                  <p>Real summary text for this article.</p>
                  <style>.ad { color: red; }</style>
                </main>
              ]]></description>
            </item>
          </channel>
        </rss>
        """

        let parser = RSSXMLParser(sourceId: "source-1")
        let items = parser.parse(data: Data(xml.utf8))

        #expect(items.count == 1)
        #expect(items[0].id == "https://example.com/article-1")
        #expect(items[0].title == "Test & Title")
        #expect(items[0].description == "Real summary text for this article.")
        #expect(items[0].contentHTML.contains("<p>Real summary text for this article.</p>"))
        #expect(items[0].contentHTML.contains("<script>bad()</script>"))
        #expect(parser.feedInfo?.title == "BBC")
        #expect(parser.feedInfo?.homepageURL == "https://www.bbc.com/news")
        #expect(parser.feedInfo?.faviconURL == "https://www.bbc.com/favicon.ico")
    }

    @Test("refresh merge preserves read and favorite state")
    func refreshMergePreservesReadAndFavoriteState() throws {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        store.addSource(source)

        let original = RSSItem(
            id: "https://example.com/article-1",
            title: "Original",
            link: "https://example.com/article-1",
            pubDate: nil,
            description: "Old summary",
            author: nil,
            sourceId: source.id
        )
        store.mergeFetchedItems([original], for: source.id)
        store.markRead(articleId: original.id, isRead: true)
        store.toggleFavorite(articleId: original.id)

        let updated = RSSItem(
            id: original.id,
            title: "Updated",
            link: original.link,
            pubDate: nil,
            description: "New summary",
            author: nil,
            sourceId: source.id
        )
        store.mergeFetchedItems([updated], for: source.id)

        let article = try #require(store.articles(for: source.id).first)
        #expect(article.title == "Updated")
        #expect(article.summary == "New summary")
        #expect(article.isRead)
        #expect(article.isFavorite)
    }

    @Test("refresh merge reports only newly inserted unread articles after initial cache")
    func refreshMergeReportsNewUnreadArticles() throws {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        store.addSource(source)

        let first = RSSItem(
            id: "https://example.com/first",
            title: "First",
            link: "https://example.com/first",
            pubDate: nil,
            description: "Initial article",
            author: nil,
            sourceId: source.id
        )
        #expect(store.mergeFetchedItems([first], for: source.id).isEmpty)

        let second = RSSItem(
            id: "https://example.com/second",
            title: "Second",
            link: "https://example.com/second",
            pubDate: nil,
            description: "New article",
            author: nil,
            sourceId: source.id
        )
        let newArticles = store.mergeFetchedItems([second, first], for: source.id)

        #expect(newArticles.map(\.id) == [second.id])
        #expect(store.totalUnreadCount() == 2)
    }

    @Test("feed discovery extracts alternate RSS URL from HTML page")
    func feedDiscoveryExtractsAlternateRSSURL() throws {
        let html = """
        <!doctype html>
        <html>
          <head>
            <title>Latest News and News Headlines</title>
            <link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml">
          </head>
        </html>
        """

        let urls = RSSFeedDiscovery.feedURLs(
            inHTML: Data(html.utf8),
            baseURL: try #require(URL(string: "https://example.com/news"))
        )

        #expect(urls.first?.absoluteString == "https://example.com/rss.xml")
    }

    @Test("removing source clears cached articles and statuses")
    func removingSourceClearsCachedArticlesAndStatuses() throws {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        store.addSource(source)

        let item = RSSItem(
            id: "https://example.com/article-1",
            title: "Article",
            link: "https://example.com/article-1",
            pubDate: nil,
            description: "Summary",
            author: nil,
            sourceId: source.id
        )
        store.mergeFetchedItems([item], for: source.id)
        store.markRead(articleId: item.id, isRead: true)
        store.toggleFavorite(articleId: item.id)

        store.removeSources(ids: [source.id])

        #expect(store.sources.isEmpty)
        #expect(store.articles(for: source.id).isEmpty)
        #expect(store.status(for: item.id) == nil)
    }

    @Test("OPML parser imports outline feeds and exporter keeps xmlUrl")
    func opmlParserImportsAndExportsSources() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="News">
              <outline text="BBC" title="BBC News" type="rss" xmlUrl="https://feedx.net/rss/bbc.xml" htmlUrl="https://bbc.com/news" />
              <outline text="Tech" type="rss" xmlUrl="https://example.com/tech.xml" />
            </outline>
          </body>
        </opml>
        """

        let sources = try RSSOPMLParser.parse(data: Data(opml.utf8))
        #expect(sources.map(\.name) == ["BBC News", "Tech"])
        #expect(sources.map(\.url) == ["https://feedx.net/rss/bbc.xml", "https://example.com/tech.xml"])

        let exported = RSSOPMLExporter.export(sources: sources)
        #expect(exported.contains(#"xmlUrl="https://feedx.net/rss/bbc.xml""#))
        #expect(exported.contains(#"text="BBC News""#))
    }

    @Test("OPML parser imports Plenary country lists with category wrapper")
    func opmlParserImportsPlenaryCountryList() throws {
        let opml = """
        <?xml version='1.0' encoding='UTF-8' ?>
        <opml version="1.0">
          <head>
            <title>Export from Plenary</title>
            <url>https://play.google.com/store/apps/details?id=com.spians.plenary</url>
          </head>
          <body>
            <outline text="Australia" title="Australia">
              <outline text="ABC News" title="ABC News" description="" xmlUrl="https://www.abc.net.au/news/feed/1948/rss.xml" type="rss" />
              <outline text="Sydney Morning Herald - Latest News" title="Sydney Morning Herald - Latest News" xmlUrl="https://www.smh.com.au/rss/feed.xml" type="rss" />
            </outline>
          </body>
        </opml>
        """

        let sources = try RSSOPMLParser.parse(data: Data(opml.utf8))
        #expect(sources.map(\.name) == ["ABC News", "Sydney Morning Herald - Latest News"])
        #expect(sources.map(\.url) == [
            "https://www.abc.net.au/news/feed/1948/rss.xml",
            "https://www.smh.com.au/rss/feed.xml"
        ])
        #expect(sources.allSatisfy { $0.sourceGroup == "Australia" })
    }

    @Test("favicon resolver uses feed host and source favicon override")
    func faviconResolverUsesSourceOverrideAndHostFallback() throws {
        let withIcon = RSSSource(
            id: "source-1",
            name: "BBC",
            url: "https://feedx.net/rss/bbc.xml",
            faviconURL: "https://static.example/icon.png"
        )
        #expect(RSSFaviconResolver.faviconURL(for: withIcon)?.absoluteString == "https://static.example/icon.png")

        let fallback = RSSSource(id: "source-2", name: "Tech", url: "https://example.com/rss.xml")
        #expect(RSSFaviconResolver.faviconURL(for: fallback)?.absoluteString == "https://example.com/favicon.ico")

        let proxied = RSSSource(
            id: "source-3",
            name: "纽约时报",
            url: "https://feedx.net/rss/nytimes.xml",
            homepageURL: "https://nytimes.com"
        )
        #expect(RSSFaviconResolver.faviconURL(for: proxied)?.absoluteString == "https://nytimes.com/favicon.ico")

        let articleFallback = RSSSource(id: "source-4", name: "Fallback", url: "https://feedx.net/rss/bbc.xml")
        #expect(RSSFaviconResolver.faviconURL(
            for: articleFallback,
            fallbackURL: URL(string: "https://www.bbc.com/news/articles/one")
        )?.absoluteString == "https://www.bbc.com/favicon.ico")
    }

    @Test("favicon resolver reads homepage icon metadata before default favicon")
    func faviconResolverReadsHomepageIconMetadata() throws {
        let html = """
        <html>
          <head>
            <link rel="icon" type="image/svg+xml" href="/ignored.svg">
            <link rel="shortcut icon" href="/graphics/favicon.ico?v=1">
            <link rel="apple-touch-icon" sizes="120x120" href="/touch-120.png">
          </head>
          <body></body>
        </html>
        """

        let urls = RSSFaviconResolver.htmlIconURLs(
            in: html,
            pageURL: try #require(URL(string: "https://example.com/articles/latest"))
        )

        #expect(urls.map(\.absoluteString) == [
            "https://example.com/graphics/favicon.ico?v=1",
            "https://example.com/touch-120.png"
        ])
    }

    @Test("article renderer emits favicon fallbacks instead of a single breakable image")
    func articleRendererEmitsFaviconFallbacks() throws {
        let source = RSSSource(
            id: "source-1",
            name: "News",
            url: "https://feed.example/rss",
            homepageURL: "https://news.example"
        )
        let article = RSSArticleRecord(item: RSSItem(
            id: "https://news.example/article",
            title: "Article",
            link: "https://news.example/article",
            pubDate: nil,
            description: "Summary",
            author: nil,
            sourceId: source.id
        ))

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: source,
            mode: .feed,
            bodyHTML: "<p>Summary</p>",
            fallbackText: "Summary",
            sourceFaviconURLs: [
                try #require(URL(string: "https://cdn.example/icon.png")),
                try #require(URL(string: "https://news.example/favicon.ico"))
            ],
            isLoading: false,
            errorMessage: nil
        )

        #expect(document.html.contains(#"src="https://cdn.example/icon.png""#))
        #expect(document.html.contains("data-fallback-srcs"))
        #expect(document.html.contains("https://news.example/favicon.ico"))
        #expect(document.html.contains("window.yueduFallbackImage(this)"))
    }

    @Test("feed response updates source homepage and icon metadata")
    func feedResponseUpdatesSourceHomepageAndIconMetadata() throws {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        let source = RSSSource(id: "source-1", name: "https://feedx.net/rss/nytimes.xml", url: "https://feedx.net/rss/nytimes.xml")
        store.addSource(source)

        let item = RSSItem(
            id: "https://cn.nytimes.com/business/20260424/china-renminbi-us-sanctions/",
            title: "战争与美国制裁加速人民币国际化",
            link: "https://cn.nytimes.com/business/20260424/china-renminbi-us-sanctions/",
            pubDate: nil,
            description: "Summary",
            author: nil,
            sourceId: source.id
        )
        store.applyFeedResponse(
            .updated(
                items: [item],
                metadata: RSSFeedFetchMetadata(lastFetchedAt: Date()),
                feedInfo: RSSFeedInfo(
                    title: "纽约时报",
                    homepageURL: "https://nytimes.com",
                    faviconURL: "/vi-assets/static-assets/favicon-4bf96cb6a1093748bf5b3c429accb9b4.ico"
                )
            ),
            for: source.id
        )

        let updatedSource = try #require(store.sources.first)
        #expect(updatedSource.name == "纽约时报")
        #expect(updatedSource.homepageURL == "https://nytimes.com")
        #expect(updatedSource.faviconURL == "https://nytimes.com/vi-assets/static-assets/favicon-4bf96cb6a1093748bf5b3c429accb9b4.ico")
        #expect(store.articles(for: source.id).map(\.id) == [item.id])
    }

    @Test("store search matches title summary and source name")
    func searchMatchesArticleAndSourceText() throws {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        let source = RSSSource(id: "source-1", name: "BBC World", url: "https://feed.example/rss")
        store.addSource(source)
        store.mergeFetchedItems([
            RSSItem(
                id: "https://example.com/one",
                title: "Apple releases new chip",
                link: "https://example.com/one",
                pubDate: nil,
                description: "Hardware update summary",
                author: nil,
                sourceId: source.id
            ),
            RSSItem(
                id: "https://example.com/two",
                title: "Sports results",
                link: "https://example.com/two",
                pubDate: nil,
                description: "Football summary",
                author: nil,
                sourceId: source.id
            )
        ], for: source.id)

        #expect(store.searchArticles(query: "chip").map(\.id) == ["https://example.com/one"])
        #expect(store.searchArticles(query: "BBC").count == 2)
    }

    @Test("timeline filter applies read favorite and search state")
    func timelineFilterAppliesReadFavoriteAndSearchState() {
        let unread = RSSArticleRecord(item: RSSItem(
            id: "unread",
            title: "Unread Apple story",
            link: "https://example.com/unread",
            pubDate: nil,
            description: "Hardware update",
            author: nil,
            sourceId: "source-1"
        ))
        let read = RSSArticleRecord(
            item: RSSItem(
                id: "read",
                title: "Read sports story",
                link: "https://example.com/read",
                pubDate: nil,
                description: "Football update",
                author: "Sports Desk",
                sourceId: "source-1"
            ),
            status: RSSArticleStatus(articleId: "read", isRead: true)
        )
        let favorite = RSSArticleRecord(
            item: RSSItem(
                id: "favorite",
                title: "Favorite design story",
                link: "https://example.com/favorite",
                pubDate: nil,
                description: "Interface notes",
                author: nil,
                sourceId: "source-1"
            ),
            status: RSSArticleStatus(articleId: "favorite", isFavorite: true)
        )
        let records = [unread, read, favorite]

        #expect(RSSArticleTimelineFilter.all.apply(to: records).map(\.id) == ["unread", "read", "favorite"])
        #expect(RSSArticleTimelineFilter.unread.apply(to: records).map(\.id) == ["unread", "favorite"])
        #expect(RSSArticleTimelineFilter.read.apply(to: records).map(\.id) == ["read"])
        #expect(RSSArticleTimelineFilter.favorite.apply(to: records).map(\.id) == ["favorite"])
        #expect(RSSArticleTimelineFilter.all.apply(to: records, query: "sports").map(\.id) == ["read"])
        #expect(RSSArticleTimelineFilter.all.apply(to: records, query: "interface").map(\.id) == ["favorite"])
    }

    @Test("conditional feed request uses etag and last modified validators")
    func conditionalFeedRequestUsesValidators() throws {
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        let metadata = RSSFeedFetchMetadata(etag: "\"abc\"", lastModified: "Thu, 07 May 2026 10:00:00 GMT")
        let request = try #require(RSSRequestFactory.feedRequest(for: source, metadata: metadata))

        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Thu, 07 May 2026 10:00:00 GMT")
    }

    @Test("304 response keeps cached articles")
    func notModifiedResponseKeepsCachedArticles() throws {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        store.addSource(source)
        let item = RSSItem(
            id: "https://example.com/one",
            title: "Cached",
            link: "https://example.com/one",
            pubDate: nil,
            description: "Summary",
            author: nil,
            sourceId: source.id
        )
        store.mergeFetchedItems([item], for: source.id)
        store.applyFeedResponse(.notModified, for: source.id)

        #expect(store.articles(for: source.id).map(\.title) == ["Cached"])
    }

    @Test("article extractor removes noisy HTML and keeps readable paragraphs")
    func articleExtractorKeepsReadableParagraphs() throws {
        let html = """
        <html>
          <head><title>Article Title</title><style>.bad{}</style></head>
          <body>
            <nav>Navigation</nav>
            <article>
              <h1>Article Title</h1>
              <p>First useful paragraph with enough text.</p>
              <script>bad()</script>
              <p>Second useful paragraph.</p>
            </article>
          </body>
        </html>
        """

        let article = RSSArticleExtractor.extract(from: Data(html.utf8), baseURL: URL(string: "https://example.com/article")!)
        #expect(article.title == "Article Title")
        #expect(article.html.contains("<p>First useful paragraph with enough text.</p>"))
        #expect(article.html.contains("<p>Second useful paragraph.</p>"))
        #expect(article.text.contains("First useful paragraph"))
        #expect(article.text.contains("Second useful paragraph"))
        #expect(!article.text.contains("Navigation"))
        #expect(!article.text.contains("bad()"))
        #expect(!article.html.contains("<script>bad"))
    }

    @Test("article extractor preserves article footer credits and translation links")
    func articleExtractorPreservesArticleFooterCreditsAndTranslationLinks() throws {
        let html = """
        <html>
          <head><title>Article Title</title></head>
          <body>
            <footer>Site footer should stay outside the selected article root.</footer>
            <article>
              <h1>Article Title</h1>
              <p>Useful body paragraph with enough text to be kept.</p>
              <footer>
                <p>Berry Wang自香港对本文有报道贡献。</p>
                <p>翻译：纽约时报中文网</p>
                <p><a href="/english/article">点击查看本文英文版。</a></p>
              </footer>
            </article>
          </body>
        </html>
        """

        let article = RSSArticleExtractor.extract(from: Data(html.utf8), baseURL: URL(string: "https://example.com/news/article")!)

        #expect(article.html.contains("Berry Wang自香港对本文有报道贡献。"))
        #expect(article.html.contains("翻译：纽约时报中文网"))
        #expect(article.html.contains(#"href="https://example.com/english/article""#))
        #expect(article.text.contains("Berry Wang自香港对本文有报道贡献。"))
        #expect(article.text.contains("翻译：纽约时报中文网"))
    }

    @Test("store persists article reader scroll position")
    func storePersistsArticleReaderScrollPosition() throws {
        let directory = try temporaryDirectory()
        let store = RSSStore(storageDirectory: directory)
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        let item = RSSItem(
            id: "https://example.com/article",
            title: "Article",
            link: "https://example.com/article",
            pubDate: nil,
            description: "Summary",
            author: nil,
            sourceId: source.id
        )

        store.addSource(source)
        store.mergeFetchedItems([item], for: source.id)
        store.updateReaderScrollY(articleId: item.id, scrollY: 480.5)

        let reloaded = RSSStore(storageDirectory: directory)
        let article = try #require(reloaded.article(id: item.id))
        #expect(article.readerScrollY == 480.5)
        #expect(reloaded.status(for: item.id)?.readerScrollY == 480.5)
    }

    @Test("store persists article reader html and full text html")
    func storePersistsArticleReaderHTMLAndFullTextHTML() throws {
        let directory = try temporaryDirectory()
        let store = RSSStore(storageDirectory: directory)
        let source = RSSSource(id: "source-1", name: "BBC", url: "https://feed.example/rss")
        let item = RSSItem(
            id: "https://example.com/article-html",
            title: "Article",
            link: "https://example.com/article-html",
            pubDate: nil,
            description: "Summary with link.",
            contentHTML: #"<p>Summary with <a href="https://example.com/topic">link</a>.</p>"#,
            author: nil,
            sourceId: source.id
        )

        store.addSource(source)
        store.mergeFetchedItems([item], for: source.id)
        store.updateFullText(
            articleId: item.id,
            text: "Full text with link.",
            html: #"<p>Full text with <a href="https://example.com/full">link</a>.</p>"#
        )

        let reloaded = RSSStore(storageDirectory: directory)
        let article = try #require(reloaded.article(id: item.id))
        #expect(article.contentHTML.contains(#"<a href="https://example.com/topic">link</a>"#))
        #expect(article.fullText == "Full text with link.")
        #expect(article.fullTextHTML?.contains(#"<a href="https://example.com/full">link</a>"#) == true)
    }

    @Test("article html renderer keeps links images and removes unsafe html")
    func articleHTMLRendererKeepsLinksImagesAndRemovesUnsafeHTML() throws {
        let article = RSSArticleRecord(item: RSSItem(
            id: "https://example.com/article",
            title: #"Bad <script>alert("x")</script> Title"#,
            link: "https://example.com/article",
            pubDate: nil,
            description: "First paragraph.\n\nSecond <b>paragraph</b> & more.",
            contentHTML: """
            <p>First paragraph.</p>
            <p>Second <a href="https://example.com/topic" onclick="bad()">linked paragraph</a>.</p>
            <figure><img src="https://example.com/image.jpg" onerror="bad()" alt="Image"><figcaption>Caption</figcaption></figure>
            <script>bad()</script>
            <iframe src="https://example.com/embed"></iframe>
            """,
            author: "Author <bad>",
            sourceId: "source-1"
        ))
        let source = RSSSource(id: "source-1", name: "BBC <News>", url: "https://feed.example/rss")

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: source,
            mode: .feed,
            bodyHTML: article.contentHTML,
            fallbackText: article.summary,
            isLoading: false,
            errorMessage: nil
        )

        #expect(document.title.contains("Bad <script>"))
        #expect(document.html.contains("rss-reader-body"))
        #expect(document.html.contains("Bad &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; Title"))
        #expect(document.html.contains("BBC &lt;News&gt;"))
        #expect(document.html.contains("Author &lt;bad&gt;"))
        #expect(document.html.contains(#"<p>First paragraph.</p>"#))
        #expect(document.html.contains(#"href="https://example.com/topic""#))
        #expect(document.html.contains(#"src="https://example.com/image.jpg""#))
        #expect(!document.html.contains("<script>alert"))
        #expect(!document.html.contains("onclick"))
        #expect(!document.html.contains(#"onerror="bad()""#))
        #expect(document.html.contains("window.yueduFallbackImage(this)"))
        #expect(!document.html.contains("<iframe"))
    }

    @Test("article html renderer reparagraphs plain reader text and uses NetNewsWire sizing")
    func articleHTMLRendererReparagraphsPlainReaderTextAndUsesNetNewsWireSizing() throws {
        let longText = """
        AARON KROLIK2026年4月24日在香港历史博物馆的国家安全展厅中心，玻璃柜后整齐地陈列着一叠叠人民币纸币，旁边还有战斗机模型、武装直升机以及装有稀土金属的小瓶。这组集战争工具与贸易手段于一体的展品凸显了一个核心理念：人民币的国际化被视为中国国家安全的重要支柱。尽管中国已崛起为经济超级大国，但仍依赖于以美元为锚的全球金融体系。将人民币转变为全球公认的货币将使北京能够按照自己的条件开展更多贸易，并削弱美国长期以来的杠杆。乌克兰和伊朗的战争进一步推动了这一进程，制裁正迫使美国的对手转而使用人民币，以绕过西方金融体系。事实上，中国为建立全球认可货币所需的国际金融纽带和技术基础设施而进行的这项计划已耗时20年，如今正在产生回报。
        """
        let article = RSSArticleRecord(item: RSSItem(
            id: "https://example.com/article",
            title: "战争与美国制裁加速人民币国际化",
            link: "https://example.com/article",
            pubDate: nil,
            description: longText,
            contentHTML: longText,
            author: "AARON KROLIK",
            sourceId: "source-1"
        ))

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: RSSSource(id: "source-1", name: "纽约时报", url: "https://example.com/feed"),
            mode: .feed,
            bodyHTML: article.contentHTML,
            fallbackText: article.summary,
            isLoading: false,
            errorMessage: nil
        )

        let paragraphCount = document.html.components(separatedBy: "<p>").count - 1
        #expect(paragraphCount >= 3)
        #expect(document.html.contains("font-size: 17px;"))
        #expect(document.html.contains("font-size: 1.5rem;"))
        #expect(document.html.contains("line-height: 1.6em;"))
    }

    @Test("article html renderer keeps media while reparagraphing loose text")
    func articleHTMLRendererKeepsMediaWhileReparagraphingLooseText() throws {
        let looseHTML = """
        AARON KROLIK2026年4月24日在香港历史博物馆的国家安全展厅中心，玻璃柜后整齐地陈列着一叠叠人民币纸币，旁边还有战斗机模型。
        <img src="https://example.com/photo.jpg" alt="Museum">
        这组集战争工具与贸易手段于一体的展品凸显了一个核心理念：人民币的国际化被视为中国国家安全的重要支柱。尽管中国已崛起为经济超级大国，但仍依赖于以美元为锚的全球金融体系。将人民币转变为全球公认的货币将使北京能够按照自己的条件开展更多贸易，并削弱美国长期以来的杠杆。
        <a href="https://example.com/topic">人民币的国际化</a>仍是文章中的可点击链接。
        """
        let article = RSSArticleRecord(item: RSSItem(
            id: "https://example.com/article-with-image",
            title: "战争与美国制裁加速人民币国际化",
            link: "https://example.com/article-with-image",
            pubDate: nil,
            description: looseHTML,
            contentHTML: looseHTML,
            author: "AARON KROLIK",
            sourceId: "source-1"
        ))

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: RSSSource(id: "source-1", name: "纽约时报", url: "https://example.com/feed"),
            mode: .feed,
            bodyHTML: article.contentHTML,
            fallbackText: article.summary,
            isLoading: false,
            errorMessage: nil
        )

        let paragraphCount = document.html.components(separatedBy: "<p>").count - 1
        #expect(paragraphCount >= 2)
        #expect(document.html.contains(#"src="https://example.com/photo.jpg""#))
        #expect(document.html.contains(#"href="https://example.com/topic""#))
    }

    @Test("article html renderer preserves structured paragraphs and removes ad markers")
    func articleHTMLRendererPreservesStructuredParagraphsAndRemovesAdMarkers() throws {
        let longParagraph = """
        大西洋理事会地缘经济中心的数据显示，从2月到3月，平均日支付额从860亿美元增至超过1310亿美元，平均交易规模增长了8%以上。中国国有的《上海证券报》将这一增长归因于持续震荡的中东局势。这种回升势头必然源于亚洲其他国家当前正在转向使用人民币来购买受限石油，大西洋理事会地缘经济中心主任表示。广告康奈尔大学经济学教授表示，人民币要挑战美元的主导地位仍面临重大障碍。要使人民币发挥更大的全球作用，它必须在境外更容易被使用，这需要北京放宽严格的资本流动管制。
        """
        let mixedHTML = """
        <figure>
          <img src="https://example.com/tanker.jpg" alt="Oil tanker">
          <figcaption>本月，多艘油轮在霍尔木兹海峡抛锚停泊。</figcaption>
        </figure>
        <p>\(longParagraph)</p>
        <footer>
          <p>Berry Wang自香港对本文有报道贡献。</p>
          <p>翻译：纽约时报中文网</p>
          <p><a href="https://example.com/english">点击查看本文英文版。</a></p>
        </footer>
        """
        let article = RSSArticleRecord(item: RSSItem(
            id: "https://example.com/mixed-media",
            title: "战争与美国制裁加速人民币国际化",
            link: "https://example.com/mixed-media",
            pubDate: nil,
            description: mixedHTML,
            contentHTML: mixedHTML,
            author: "AARON KROLIK",
            sourceId: "source-1"
        ))

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: RSSSource(id: "source-1", name: "纽约时报", url: "https://example.com/feed"),
            mode: .feed,
            bodyHTML: article.contentHTML,
            fallbackText: article.summary,
            isLoading: false,
            errorMessage: nil
        )

        let paragraphCount = document.html.components(separatedBy: "<p>").count - 1
        #expect(paragraphCount == 4)
        #expect(document.html.contains(#"src="https://example.com/tanker.jpg""#))
        #expect(document.html.contains("本月，多艘油轮在霍尔木兹海峡抛锚停泊。"))
        #expect(document.html.contains("主任表示。康奈尔大学经济学教授表示"))
        #expect(!document.html.contains("广告康奈尔"))
        #expect(document.html.contains("Berry Wang自香港对本文有报道贡献。"))
        #expect(document.html.contains("翻译：纽约时报中文网"))
        #expect(document.html.contains(#"href="https://example.com/english""#))
    }

    @Test("article html renderer keeps inline links inside original paragraph")
    func articleHTMLRendererKeepsInlineLinksInsideOriginalParagraph() throws {
        let html = """
        <p>特朗普还面临着如何处理伊朗<a href="https://example.com/uranium">约440公斤高浓铀</a>的困境，这些铀足以制造约12枚核弹。</p>
        <p>伊朗也面临艰难抉择。</p>
        """
        let article = RSSArticleRecord(item: RSSItem(
            id: "https://example.com/inline-link",
            title: "Inline Link",
            link: "https://example.com/inline-link",
            pubDate: nil,
            description: html,
            contentHTML: html,
            author: nil,
            sourceId: "source-1"
        ))

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: RSSSource(id: "source-1", name: "纽约时报", url: "https://example.com/feed"),
            mode: .feed,
            bodyHTML: article.contentHTML,
            fallbackText: article.summary,
            isLoading: false,
            errorMessage: nil
        )

        #expect(document.html.contains(#"处理伊朗<a href="https://example.com/uranium">约440公斤高浓铀</a>的困境"#))
        #expect(!document.html.contains(#"</p><p><a href="https://example.com/uranium">"#))
    }

    @Test("feedx nytimes full rss keeps paragraphs images and footer")
    func feedxNYTimesFullRSSKeepsParagraphsImagesAndFooter() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>纽约时报</title>
            <item>
              <title>战争与美国制裁加速人民币国际化</title>
              <link>https://cn.nytimes.com/business/20260424/china-currency-iran/</link>
              <description>&lt;address&gt;AARON KROLIK&lt;/address&gt;&lt;time datetime=&quot;2026-04-24 02:33:04&quot;&gt;2026年4月24日&lt;/time&gt;&lt;section&gt;&lt;p&gt;在香港历史博物馆的国家安全展厅中心，玻璃柜后整齐地陈列着一叠叠人民币纸币。&lt;/p&gt;&lt;p&gt;这组集战争工具与贸易手段于一体的展品凸显了一个核心理念：&lt;a href=&quot;https://cn.nytimes.com/business/20250619/china-dollar-renminbi/&quot;&gt;人民币的国际化&lt;/a&gt;被视为中国国家安全的重要支柱。&lt;/p&gt;&lt;p&gt;&lt;img src=&quot;https://images.weserv.nl/?url=static01.nyt.com/image.jpg&quot;&gt;&lt;small&gt;香港历史博物馆展出的中国纸币。&lt;/small&gt;&lt;/p&gt;&lt;p&gt;大西洋理事会地缘经济中心的数据显示，从2月到3月，平均日支付额从860亿美元增至超过1310亿美元。&lt;/p&gt;&lt;/section&gt;&lt;footer&gt;&lt;p&gt;Berry Wang自香港对本文有报道贡献。&lt;/p&gt;&lt;p&gt;翻译：纽约时报中文网&lt;/p&gt;&lt;p&gt;&lt;a href=&quot;https://www.nytimes.com/2026/04/24/business/china-currency-iran.html&quot;&gt;点击查看本文英文版。&lt;/a&gt;&lt;/p&gt;&lt;/footer&gt;</description>
              <pubDate>Fri, 24 Apr 2026 06:37:02 +0000</pubDate>
            </item>
          </channel>
        </rss>
        """

        let item = try #require(RSSXMLParser(sourceId: "nytimes").parse(data: Data(xml.utf8)).first)
        let article = RSSArticleRecord(item: item)

        #expect(article.author == "AARON KROLIK")
        #expect(article.pubDate != nil)
        #expect(RSSArticleHTMLSanitizer.hasSubstantialStructuredContent(article.contentHTML, fallbackText: article.summary))

        let document = RSSArticleHTMLRenderer.render(
            article: article,
            source: RSSSource(id: "nytimes", name: "纽约时报", url: "https://feedx.net/rss/nytimes.xml"),
            mode: .reader,
            bodyHTML: article.contentHTML,
            fallbackText: article.summary,
            isLoading: false,
            errorMessage: nil
        )

        let paragraphCount = document.html.components(separatedBy: "<p>").count - 1
        #expect(paragraphCount == 7)
        #expect(document.html.contains(#"src="https://images.weserv.nl/?url=static01.nyt.com/image.jpg""#))
        #expect(document.html.contains("AARON KROLIK"))
        #expect(document.html.contains(#"理念：<a href="https://cn.nytimes.com/business/20250619/china-dollar-renminbi/">人民币的国际化</a>被视为"#))
        #expect(document.html.contains("Berry Wang自香港对本文有报道贡献。"))
        #expect(document.html.contains("翻译：纽约时报中文网"))
        #expect(document.html.contains("点击查看本文英文版。"))
    }

    @Test("reader paragraph helper splits single line chapters consistently")
    func readerParagraphHelperSplitsSingleLineChaptersConsistently() {
        let singleLine = String(repeating: "这是一个很长的章节句子，用来模拟来源没有保留段落换行的情况。", count: 18)
        let paragraphs = ReaderHTMLUtilities.paragraphs(fromPlainText: singleLine)

        #expect(paragraphs.count > 1)
        #expect(paragraphs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
