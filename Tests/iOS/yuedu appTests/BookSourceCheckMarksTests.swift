import Combine
import Foundation
import Testing

@testable import yuedu_app

/// What a 書源驗證 writes onto the source, as Legado's `CheckSourceService` does: every check
/// first drops the invalid groups (`removeInvalidGroups`) and the `// Error:` line
/// (`removeErrorComment`) an earlier check left, then adds the groups naming what failed now
/// and, for a failed source, a fresh `// Error:` line.
@MainActor
@Suite("Book source check: groups and error comment")
struct BookSourceCheckMarksTests {

    // MARK: - Applying marks to a source

    @Test("an earlier check's invalid groups go, the source's own groups stay")
    func invalidGroupsReplaced() {
        var source = Self.source(group: "玄幻；搜索失效,校验超时，女频")
        let changed = source.applyCheckMarks(.init(addGroups: ["发现正文失效"]))
        #expect(changed)
        #expect(source.bookSourceGroup == "玄幻,女频,发现正文失效")
    }

    @Test("a rule tag is cleared once the rule is there")
    func ruleTagCleared() {
        var source = Self.source(group: "搜索链接规则为空,男频")
        source.applyCheckMarks(.init(removeGroups: [BookSourceCheckMarks.Group.searchURLEmpty]))
        #expect(source.bookSourceGroup == "男频")
    }

    @Test("a failed check puts its reason above the author's comment; a passing one removes it")
    func errorCommentWrittenThenRemoved() {
        var source = Self.source(comment: "作者說明\n\n第二段")
        source.applyCheckMarks(.init(addGroups: ["搜索失效"], errorReason: "搜索失效"))
        #expect(source.bookSourceComment == "// Error: 搜索失效\n\n作者說明\n\n第二段")

        // The next failure replaces the line rather than stacking a second one.
        source.applyCheckMarks(.init(addGroups: ["网站失效"], errorReason: "HTTP 503"))
        #expect(source.bookSourceComment == "// Error: HTTP 503\n\n作者說明\n\n第二段")
        #expect(source.bookSourceGroup == "网站失效")

        source.applyCheckMarks(.init())
        #expect(source.bookSourceComment == "作者說明\n\n第二段")
        #expect(source.bookSourceGroup.isEmpty)
    }

    @Test("an empty comment becomes the error line alone")
    func errorCommentOnEmptyComment() {
        var source = Self.source()
        source.applyCheckMarks(.init(errorReason: "校验超时"))
        #expect(source.bookSourceComment == "// Error: 校验超时")
    }

    @Test("with 失敗原因寫入源註釋 off the comment is left as it was")
    func commentUntouchedWhenOff() {
        var source = Self.source(comment: "// Error: 舊的\n\n作者說明")
        source.applyCheckMarks(.init(errorReason: "新的", writesComment: false))
        #expect(source.bookSourceComment == "// Error: 舊的\n\n作者說明")
    }

    @Test("a check that changes nothing reports no change")
    func unchangedSourceReportsNoChange() {
        var source = Self.source(group: "玄幻", comment: "作者說明")
        let changed = source.applyCheckMarks(.init())
        #expect(!changed)
        #expect(source.bookSourceGroup == "玄幻")
    }

    // MARK: - Deriving marks from a finished item

    @Test("each track names its own failure, and the comment lists them")
    func perTrackGroups() {
        var item = BookSourceCheckItem(source: Self.source())
        item.stages[ValidationStage.toc.rawValue].status = .fail
        item.trackFailures = [.search: .tocEmpty, .discovery: .contentEmpty]
        item.presentRuleTracks = [.search, .discovery]

        let marks = BookSourceHealthChecker.checkMarks(for: item, policy: BookSourceCheckPolicy())

        #expect(marks.addGroups == ["搜索目录失效", "发现正文失效"])
        #expect(marks.removeGroups == ["搜索链接规则为空", "发现规则为空"])
        #expect(marks.errorReason == "搜索目录失效, 发现正文失效")
    }

    @Test("a failure that ends the check is named for the source, with its message")
    func abortGroup() {
        var item = BookSourceCheckItem(source: Self.source())
        item.stages[ValidationStage.search.rawValue].status = .fail
        item.trackFailures = [.search: .timeout]
        item.abortCategory = .timeout
        item.failureMessage = localized("校驗超時")

        let marks = BookSourceHealthChecker.checkMarks(for: item, policy: BookSourceCheckPolicy())

        #expect(marks.addGroups == ["校验超时"])
        #expect(marks.errorReason == localized("校驗超時"))
    }

    @Test("an empty rule is tagged; a passing source gets no error line")
    func emptyRuleTagOnPass() {
        var item = BookSourceCheckItem(source: Self.source())
        for stage in ValidationStage.allCases {
            item.stages[stage.rawValue].status = stage == .search ? .skipped : .pass
        }
        item.emptyRuleTracks = [.search]
        item.presentRuleTracks = [.discovery]

        var policy = BookSourceCheckPolicy()
        policy.writesErrorComment = false
        let marks = BookSourceHealthChecker.checkMarks(for: item, policy: policy)

        #expect(marks.addGroups == ["搜索链接规则为空"])
        #expect(marks.removeGroups == ["发现规则为空"])
        #expect(marks.errorReason == nil)
        #expect(!marks.writesComment)
    }

    // MARK: - 檢查域名

    @Test("a source URL that is not http fails the domain check without a connection")
    func domainProbeNotHTTP() async {
        #expect(await BookSourceDomainProbe.check("@js:'https://example.test'") == .notHTTP)
        #expect(await BookSourceDomainProbe.check("ftp://example.test") == .notHTTP)
    }

    @Test("a refused connection is 域名失效")
    func domainProbeRefused() async {
        // Port 9 (discard) has no listener on the test host, so the connect is refused at once.
        #expect(await BookSourceDomainProbe.check("http://127.0.0.1:9#備註") == .unreachable)
    }

    // MARK: - 停止, and the background time running out

    @Test("a run stopped mid-way writes the sources it finished and nothing of the rest")
    func stoppedRunWritesOnlyFinishedSources() async throws {
        var fast = BookSource(bookSourceUrl: "https://fast.yuedu.test", bookSourceName: "fast")
        fast.searchUrl = fast.bookSourceUrl + "/search?q={{key}}"
        var slow = BookSource(bookSourceUrl: "https://slow.yuedu.test", bookSourceName: "slow")
        slow.searchUrl = slow.bookSourceUrl + "/search?q={{key}}"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceCheckMarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync([fast, slow])
        let fetcher = StoppedRunFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher, store: store)
        checker.prepare(sources: [fast, slow])

        let run = Task { await checker.runAll() }
        await fetcher.waitForSlowSearch()
        await Self.waitUntil(checker) { checker.finishedCount >= 1 }
        // What the background expiry does: stop, keeping what was found.
        checker.cancel()
        // The slow request fails only now, as one does when the app is suspended under it.
        await fetcher.releaseSlowSearch()
        await run.value
        checker.flushRespondTimes()
        store.waitForQueuedWrites()

        // The row of the source still in flight stops spinning, and the run says why it ended.
        #expect(checker.stopReason == .user)
        let slowRow = try #require(checker.items.first { $0.source.id == slow.id })
        #expect(!slowRow.stages.contains { $0.status == .running })
        #expect(!slowRow.isFinished)

        let storedFast = try #require(store.source(id: fast.id))
        let storedSlow = try #require(store.source(id: slow.id))
        #expect(BookSourceCheckMarks.groups(in: storedFast.bookSourceGroup).contains("搜索失效"))
        #expect(storedFast.bookSourceComment.hasPrefix("// Error: "))
        #expect(storedSlow.bookSourceGroup.isEmpty)
        #expect(storedSlow.bookSourceComment.isEmpty)
    }

    /// Waits on the checker's own publications: checked first, then on every one after.
    private static func waitUntil(
        _ checker: BookSourceHealthChecker,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }
        var subscription: AnyCancellable?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            subscription = checker.didPublish.sink {
                guard condition(), subscription != nil else { return }
                subscription?.cancel()
                subscription = nil
                continuation.resume()
            }
        }
    }

    private static func source(group: String = "", comment: String = "") -> BookSource {
        var source = BookSource(bookSourceUrl: "https://marks.yuedu.test", bookSourceName: "分組")
        source.bookSourceGroup = group
        source.bookSourceComment = comment
        return source
    }
}

/// "fast" finds nothing at once; "slow" holds its search until the test lets it fail.
private actor StoppedRunFetcher: BookSourceHealthCheckFetching {
    private var slowStarted = false
    private var slowStartedWaiter: CheckedContinuation<Void, Never>?
    private var slowRelease: CheckedContinuation<Void, Never>?

    func waitForSlowSearch() async {
        guard !slowStarted else { return }
        await withCheckedContinuation { slowStartedWaiter = $0 }
    }

    func releaseSlowSearch() {
        slowRelease?.resume()
        slowRelease = nil
    }

    private func holdSlowSearch() async {
        slowStarted = true
        slowStartedWaiter?.resume()
        slowStartedWaiter = nil
        await withCheckedContinuation { slowRelease = $0 }
    }

    nonisolated func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        guard source.bookSourceName == "slow" else { return [] }
        await holdSlowSearch()
        throw URLError(.networkConnectionLost)
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] {
        []
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        []
    }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook {
        throw URLError(.badServerResponse)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        []
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        ""
    }
}
