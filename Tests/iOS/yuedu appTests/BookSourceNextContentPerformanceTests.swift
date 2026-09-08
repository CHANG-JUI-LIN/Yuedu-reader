import Foundation
import Testing
@testable import yuedu_app

@Suite("Next content rule session contention", .serialized)
struct BookSourceNextContentPerformanceTests {
    @Test("an absent next-page rule completes while a sibling owns the source session")
    func absentRuleDoesNotWaitForSiblingParse() {
        let probe = NextContentSessionProbe()
        DispatchQueue.global().async { probe.holdSession() }
        let acquired = probe.acquired.wait(timeout: .now() + 2) == .success
        #expect(acquired)
        guard acquired else {
            probe.release.signal()
            return
        }

        DispatchQueue.global().async { probe.extract() }
        // Timeout is a deadlock guard, not a scheduled release: the source lock stays
        // held until extraction has had to demonstrate that it does not require it.
        let completedWhileLocked = probe.completed.wait(timeout: .now() + 2) == .success
        probe.release.signal()
        let completedAfterRelease = completedWhileLocked
            || probe.completed.wait(timeout: .now() + 2) == .success
        #expect(completedWhileLocked)
        #expect(completedAfterRelease)
        if completedAfterRelease { #expect(probe.result.isEmpty) }
    }

    @Test("a declared next-page rule still resolves its original URLs")
    func declaredRuleStillUsesParser() {
        var source = BookSource(
            bookSourceUrl: "https://next-page-\(UUID().uuidString).example",
            bookSourceName: "Next page fixture"
        )
        source.ruleContent.nextContentUrl = "a.next@href"
        let urls = BookSourceParsingPipeline().extractNextContentURLs(
            html: "<a class='next' href='/chapter/2'>Next</a>",
            baseURL: "https://fixture.example/chapter/1",
            source: source
        )
        #expect(urls == ["https://fixture.example/chapter/2"])
    }
}

private final class NextContentSessionProbe: @unchecked Sendable {
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let source = BookSource(
        bookSourceUrl: "https://empty-next-page-\(UUID().uuidString).example",
        bookSourceName: "Empty next page fixture"
    )
    // Written once by extract, read only after the completed semaphore synchronizes it.
    private(set) var result: [String] = []

    func holdSession() {
        BookSourceSession.session(for: source).withBridge { _ in
            acquired.signal()
            release.wait()
        }
    }

    func extract() {
        result = BookSourceParsingPipeline().extractNextContentURLs(
            html: "<p>Chapter content</p>",
            baseURL: "https://fixture.example/chapter/1",
            source: source
        )
        completed.signal()
    }
}
