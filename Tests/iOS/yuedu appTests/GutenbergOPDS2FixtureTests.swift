import Foundation
import Testing
@testable import yuedu_app

/// Responses recorded from Gutenberg's OPDS 2 development endpoint by
/// `scripts/fetch_gutenberg_opds2_fixtures.sh` (decision 18 of plan
/// 2026-10-07-public-domain-libraries). `sources.json` keeps each response's
/// URL and Content-Type, so relative links and parser selection are the real ones.
/// The app never requests this endpoint.
@Suite("Gutenberg OPDS 2 recorded fixtures")
struct GutenbergOPDS2FixtureTests {

    private struct Source: Decodable { let url: URL; let contentType: String }

    private let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/GutenbergOPDS2")

    private func load(_ name: String) throws -> OPDSFeed {
        let sources = try JSONDecoder().decode([String: Source].self,
            from: Data(contentsOf: directory.appendingPathComponent("sources.json")))
        let source = try #require(sources[name], "sources.json has no entry for \(name)")
        #expect(OPDS2FeedParser.handles(contentType: source.contentType), "\(name) was served as \(source.contentType)")
        return try SourcePerfTrace.span("gutenberg.opds2.fixture.parse", name, thresholdMs: 0) {
            try OPDSClient.parseFeed(data: Data(contentsOf: directory.appendingPathComponent(name)),
                                     feedURL: source.url, contentType: source.contentType)
        }
    }

    @Test func root() async throws {
        let feed = try load("root.json")
        #expect(!feed.title.isEmpty)
        #expect(!feed.entries.isEmpty)
        #expect(feed.entries.allSatisfy { !$0.title.isEmpty && !$0.id.isEmpty })
        #expect(feed.entries.contains(where: \.isNavigation))
        let search = try #require(feed.search)
        let url = try #require(try await OPDSClient().searchFeedURL(search: search, query: "austen & co"))
        #expect(url.host == "opds-test.pglaf.org")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "query" }?.value == "austen & co")
    }

    @Test func groupPage() throws {
        let feed = try load("group.json")
        let books = feed.entries.filter(\.isBook)
        #expect(!books.isEmpty)
        #expect(books.allSatisfy { !$0.title.isEmpty && !$0.id.isEmpty })
        #expect(books.contains { $0.bestAcquisition?.importExtension == "epub" })
        #expect(feed.nextPageURL != nil)
    }

    @Test func search() throws {
        let feed = try load("search.json")
        let books = feed.entries.filter(\.isBook)
        #expect(!books.isEmpty)
        #expect(books.contains { $0.authorNames.contains { $0.localizedCaseInsensitiveContains("Austen") } })
    }

    @Test func publication() throws {
        let feed = try load("publication.json")
        let book = try #require(feed.entries.first)
        #expect(feed.entries.count == 1)
        #expect(!book.title.isEmpty)
        #expect(book.author != nil)
        #expect(book.bestAcquisition?.importExtension == "epub")
        #expect(book.displayCoverURL != nil)
    }
}
