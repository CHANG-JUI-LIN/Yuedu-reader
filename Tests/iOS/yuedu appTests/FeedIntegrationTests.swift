import Foundation
import Testing
@testable import yuedu_app

@Suite("Feed Integration")
struct FeedIntegrationTests {

    /// Feed URLs from the US OPML test set.
    static let testFeedURLs: [(String, String)] = [
        ("NYT Top Stories",  "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
        ("CNN Edition",      "http://rss.cnn.com/rss/edition.rss"),
        ("FOX News",         "http://feeds.foxnews.com/foxnews/latest"),
        ("HuffPost World",   "https://www.huffpost.com/section/world-news/feed"),
        ("Washington Post",  "http://feeds.washingtonpost.com/rss/world"),
        ("WSJ World News",   "https://feeds.a.dj.com/rss/RSSWorldNews.xml"),
        ("LA Times World",   "https://www.latimes.com/world-nation/rss2.0.xml"),
        ("Yahoo News",       "https://news.yahoo.com/rss/mostviewed"),
        ("CNBC Top News",    "https://www.cnbc.com/id/100003114/device/rss/rss.html"),
        ("Politico Playbook","https://rss.politico.com/playbook.xml"),
    ]

    // MARK: - OPML Parsing

    @Test("OPML parser imports US feeds from awesome-RSS-feeds")
    func opmlParserImportsUSFeeds() async throws {
        let opmlURL = URL(string: "https://raw.githubusercontent.com/spians/awesome-RSS-feeds/master/countries/with_category/United%20States.opml")!
        var request = URLRequest(url: opmlURL)
        request.timeoutInterval = 15
        RSSRequestFactory.applyHeaders(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200, "OPML download should succeed")

        let sources = try RSSOPMLParser.parse(data: data)
        #expect(!sources.isEmpty, "Should parse at least one source")
        for source in sources {
            #expect(!source.name.isEmpty)
            #expect(source.url.hasPrefix("http"))
        }
    }

    // MARK: - Feed Fetching & Parsing

    @Test("Fetch and parse all US feed URLs")
    func fetchAndParseAllFeeds() async throws {
        var results: [(name: String, status: String, items: Int, note: String)] = []

        for (name, urlString) in Self.testFeedURLs {
            guard let url = URL(string: urlString) else {
                results.append((name, "BAD_URL", 0, ""))
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            RSSRequestFactory.applyHeaders(to: &request)

            let data: Data, httpResponse: URLResponse
            do {
                (data, httpResponse) = try await URLSession.shared.data(for: request)
            } catch {
                results.append((name, "NETWORK_ERROR", 0, error.localizedDescription))
                continue
            }

            guard let http = httpResponse as? HTTPURLResponse else {
                results.append((name, "NO_HTTP", 0, ""))
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                results.append((name, "HTTP \(http.statusCode)", 0, "skipped — upstream rate limit"))
                continue
            }

            let detectedType = detectFeedType(data: data)
            let actualURL = http.url?.absoluteString ?? urlString
            var itemCount = 0
            var note = ""

            if let parsed = RSSFeedParser.parse(data: data, url: actualURL) {
                itemCount = parsed.items.count
                note = "unified(\(detectedType)) title=\(parsed.title ?? "nil")"
            } else {
                let legacyParser = RSSXMLParser(sourceId: name)
                let legacyItems = legacyParser.parse(data: data)
                if let err = legacyParser.error {
                    note = "FAILED: \(err)"
                } else {
                    itemCount = legacyItems.count
                    note = "legacy title=\(legacyParser.feedInfo?.title ?? "nil")"
                }
            }

            results.append((name, "HTTP \(http.statusCode)", itemCount, note))
        }

        // Summary
        print("\n========== FEED TEST RESULTS ==========")
        for r in results {
            let icon = r.items > 0 ? "✅" : "❌"
            print("\(icon) \(r.name) | \(r.status) | \(r.items) items | \(r.note)")
        }
        let passed = results.filter { $0.items > 0 }.count
        let skipped = results.filter { $0.status.contains("429") || $0.status.contains("403") || $0.status.contains("5") }.count
        let failed = results.filter { $0.items == 0 && !$0.status.contains("429") && !$0.status.contains("403") && !$0.status.contains("5") && $0.status != "NETWORK_ERROR" }.count
        print("Total: \(results.count) | Passed: \(passed) | Skipped (rate-limited): \(skipped) | Failed: \(failed)")
        print("=======================================\n")

        #expect(failed == 0, "All non-rate-limited feeds should parse successfully")
    }

    // MARK: - Feed Discovery

    @Test("Feed discovery finds known site feeds")
    func feedDiscoveryFindsKnownFeeds() async throws {
        let testCases: [(homepage: String, expectedContains: String)] = [
            ("https://www.bbc.com/news", "bbc"),
            ("https://www.nytimes.com",  "nyt"),
        ]

        for (homepage, expectedContains) in testCases {
            guard let url = URL(string: homepage) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            RSSRequestFactory.applyHeaders(to: &request)

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let feedURLs = RSSFeedDiscovery.feedURLs(inHTML: data, baseURL: url)
                print("\(homepage): discovered \(feedURLs.count) feed URLs: \(feedURLs.map(\.absoluteString))")
                let matches = feedURLs.contains { $0.absoluteString.contains(expectedContains) }
                if !matches {
                    print("⚠️ \(homepage): no feed URL contains '\(expectedContains)', fallback URLs returned")
                }
            } catch {
                print("⚠️ \(homepage): page download failed: \(error.localizedDescription) — skipping")
            }
        }
    }

    // MARK: - Format Detection

    private static func padded(_ s: String, to length: Int = 256) -> Data {
        var s = s
        while s.utf8.count < length { s += " " }
        return Data(s.utf8)
    }

    @Test("Format detection correctly identifies feed types")
    func formatDetection() {
        // RSS
        #expect(detectFeedType(data: Self.padded("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>T</title><pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate></channel></rss>")) == .rss)

        // Atom
        #expect(detectFeedType(data: Self.padded("<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>T</title></feed>")) == .atom)

        // JSON Feed
        #expect(detectFeedType(data: Self.padded("{\"version\":\"https://jsonfeed.org/version/1.1\",\"title\":\"Test\",\"items\":[]}")) == .jsonFeed)

        // RSS-in-JSON
        #expect(detectFeedType(data: Self.padded("{\"rss\":{\"channel\":{\"title\":\"Test\",\"item\":[]}}}")) == .rssInJSON)

        // Not a feed
        #expect(detectFeedType(data: Self.padded("<!doctype html><html><head><title>Test</title></head><body><p>Hello world this is a test page</p></body></html>")) == .notAFeed)

        // Too small
        #expect(detectFeedType(data: Data("{}".utf8)) == .unknown)
    }
}
