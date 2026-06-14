import Foundation
import Testing
@testable import yuedu_app

@Suite("Aggregate search streaming", .serialized)
struct AggregateSearchStreamingTests {
    @Test("gysearch all sources split into streamed subsource batches")
    func gysearchAllSourcesStreamsSubsourceBatches() async throws {
        AggregateSearchStreamingURLProtocol.reset()
        URLProtocol.registerClass(AggregateSearchStreamingURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(AggregateSearchStreamingURLProtocol.self)
            AggregateSearchStreamingURLProtocol.reset()
        }

        var source = BookSource()
        source.bookSourceName = "Streaming Aggregate"
        source.bookSourceUrl = "aggregate-streaming-\(UUID().uuidString)"
        source.jsLib = """
        function BaseUrl() { return 'https://aggregate-streaming.test'; }
        function request(url) { return java.ajax(BaseUrl() + url + ',{"method":"GET"}'); }
        """
        source.searchUrl = """
        <js>
        let payload = java.base64Encode(JSON.stringify({
            key: key,
            tab: '小说',
            sourcesKey: '全部',
            page: page,
            disabled_sources: '0'
        }));
        `data:;base64,${payload},{"type":"gysearch"}`;
        </js>
        """
        source.ruleSearch.bookList = """
        <js>
        const res = JSON.parse(java.hexDecodeToString(result));
        let url = `/search?title=${res.key}&tab=${res.tab}&source=${res.sourcesKey}&page=${res.page}&disabled_sources=${res.disabled_sources}`;
        request(url);
        </js>
        $.data
        """
        source.ruleSearch.name = "$.book_name"
        source.ruleSearch.author = "$.author"
        source.ruleSearch.bookUrl = "$.book_url"
        source.ruleSearch.coverUrl = "$.thumb_url"
        source.ruleSearch.intro = "$.abstract"
        source.ruleSearch.lastChapter = "$.source"

        BookSourceRuntimeStateStore.shared.setSourceVariableJSON(
            #"{"云端配置":{"小说":["Alpha","Beta"]}}"#,
            for: source.bookSourceUrl
        )
        defer {
            BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: source.bookSourceUrl)
        }

        let recorder = StreamBatchRecorder()
        let outcome = try await ModernParserBridge(source: source)
            .searchBooksStreaming(keyword: "斗罗", page: 1) { books in
                await recorder.append(books)
            }

        let streamedNames = await recorder.names
        let requestedSources = AggregateSearchStreamingURLProtocol.requestedSources

        #expect(outcome.streamed)
        #expect(Set(streamedNames) == ["Alpha Book", "Beta Book"])
        #expect(Set(outcome.books.map(\.name)) == ["Alpha Book", "Beta Book"])
        #expect(Set(requestedSources) == ["Alpha", "Beta"])
    }
}

private actor StreamBatchRecorder {
    private var batches: [[OnlineBook]] = []

    func append(_ books: [OnlineBook]) {
        batches.append(books)
    }

    var names: [String] {
        batches.flatMap { $0.map(\.name) }
    }
}

private final class AggregateSearchStreamingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var sources: [String] = []

    static var requestedSources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }

    static func reset() {
        lock.lock()
        sources.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "aggregate-streaming.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let source = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "source" })?
            .value ?? "unknown"

        Self.lock.lock()
        Self.sources.append(source)
        Self.lock.unlock()

        let payload = """
        {
          "data": [
            {
              "book_name": "\(source) Book",
              "author": "Author",
              "book_url": "https://books.test/\(source)",
              "thumb_url": "",
              "abstract": "",
              "source": "\(source)"
            }
          ]
        }
        """
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
