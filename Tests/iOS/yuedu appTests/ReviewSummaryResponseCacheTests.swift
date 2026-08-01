import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter review summary cache")
struct ReviewSummaryResponseCacheTests {
    @Test("isolates cached responses by source identity")
    func isolatesBySource() {
        let cache = ReviewSummaryResponseCache(lifetime: 30, maximumEntryCount: 4)
        let url = "https://m.qidian.com/majax/chapterReview/reviewSummary?bookId=1&chapterId=2"
        cache.insert("source-a", sourceKey: "source-a", requestURL: url)

        #expect(cache.value(sourceKey: "source-a", requestURL: url) == "source-a")
        #expect(cache.value(sourceKey: "source-b", requestURL: url) == nil)
    }

    @Test("evicts the entry with the shortest remaining lifetime at capacity")
    func evictsOldestEntryAtCapacity() {
        let cache = ReviewSummaryResponseCache(lifetime: 30, maximumEntryCount: 1)
        cache.insert("first", sourceKey: "source", requestURL: "https://example.com/1")
        cache.insert("second", sourceKey: "source", requestURL: "https://example.com/2")

        #expect(cache.value(sourceKey: "source", requestURL: "https://example.com/1") == nil)
        #expect(cache.value(sourceKey: "source", requestURL: "https://example.com/2") == "second")
    }

    @Test("joins an in-flight request and releases waiters on completion")
    func joinsInFlightRequest() async {
        let cache = ReviewSummaryResponseCache(lifetime: 30, maximumEntryCount: 4)
        let url = "https://example.com/review-summary"
        #expect(cache.beginRequest(sourceKey: "source", requestURL: url) == .owner)

        let waiter = Task.detached {
            cache.waitForRequest(sourceKey: "source", requestURL: url, timeout: 1)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        cache.finishRequest("summary", sourceKey: "source", requestURL: url)

        #expect(await waiter.value == "summary")
        #expect(cache.beginRequest(sourceKey: "source", requestURL: url) == .cached("summary"))
    }
}
