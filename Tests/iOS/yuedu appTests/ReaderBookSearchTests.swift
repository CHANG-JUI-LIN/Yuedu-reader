import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 全書搜尋: matching a chapter, the snippet a row shows, finding a hit again in the laid-out
/// text, and the session that runs a search over the book.
@MainActor
@Suite("Reader book search", .serialized)
struct ReaderBookSearchTests {

    // MARK: - Matching

    @Test("plain words match ignoring case, in order, without overlapping")
    func plainMatchesIgnoreCaseWithoutOverlap() throws {
        let query = ReaderBookSearchQuery(text: "aa", isRegex: false)
        let ranges = try ReaderBookSearchMatcher.ranges(of: query, in: "AAA aa")
        #expect(ranges == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
    }

    @Test("a regular expression matches, and drops the empty matches it can produce")
    func regexMatchesAndDropsEmptyMatches() throws {
        let words = try ReaderBookSearchMatcher.ranges(of: .init(text: "第.章", isRegex: true), in: "第一章，第二章")
        #expect(words == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
        let empty = try ReaderBookSearchMatcher.ranges(of: .init(text: "x*", isRegex: true), in: "abxxc")
        #expect(empty == [NSRange(location: 2, length: 2)])
    }

    @Test("a pattern that does not compile is reported, not searched")
    func invalidPatternThrows() {
        #expect(throws: ReaderBookSearchError.invalidPattern) {
            try ReaderBookSearchMatcher.ranges(of: .init(text: "([", isRegex: true), in: "text")
        }
    }

    @Test("a pattern that backtracks without end stops at the deadline")
    func catastrophicPatternTimesOut() {
        let text = String(repeating: "a", count: 40) + "c"
        let started = ContinuousClock.now
        #expect(throws: ReaderBookSearchError.timedOut) {
            try ReaderBookSearchMatcher.ranges(of: .init(text: "(a+)+b", isRegex: true), in: text)
        }
        #expect(ContinuousClock.now - started < ReaderBookSearchMatcher.regexDeadline + .seconds(2))
    }

    @Test("hits number their matches and search the converted text with converted words")
    func hitsConvertBothSides() async throws {
        let hits = try await ReaderBookSearchMatcher.hits(
            of: .init(text: "說話".converted(to: .toTraditional), isRegex: false),
            chapterIndex: 3, text: "他说话，她也说话。", conversion: .toTraditional, limit: 10)
        #expect(hits.map(\.ordinal) == [0, 1])
        #expect(hits.map(\.chapterIndex) == [3, 3])
        #expect(hits.map(\.matchedText) == ["說話", "說話"])
        #expect(hits.map(\.range) == [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)])
    }

    // MARK: - Snippet

    @Test("the snippet keeps 20 characters each side, on one line, and says it was cut")
    func snippetCutsContextOnOneLine() throws {
        let before = String(repeating: "前", count: 30)
        let after = "後\n" + String(repeating: "後", count: 30)
        let text = before + "關鍵" + after
        let range = NSRange(location: 30, length: 2)
        let snippet = try #require(ReaderBookSearchMatcher.snippet(for: range, in: text))
        #expect(snippet.leading == String(repeating: "前", count: 20))
        #expect(snippet.match == "關鍵")
        #expect(snippet.trailing == "後 " + String(repeating: "後", count: 18))
        #expect(snippet.continuesBefore)
        #expect(snippet.continuesAfter)
    }

    @Test("the snippet never splits an emoji")
    func snippetKeepsGraphemesWhole() throws {
        let text = "👨‍👩‍👧" + "找到"
        let range = NSRange(location: ("👨‍👩‍👧" as NSString).length, length: 2)
        let snippet = try #require(ReaderBookSearchMatcher.snippet(for: range, in: text))
        #expect(snippet.leading == "👨‍👩‍👧")
        #expect(!snippet.continuesBefore)
        #expect(!snippet.continuesAfter)
    }

    // MARK: - Locating a hit on the page

    @Test("a hit lands on its place in laid-out text that adds a title and reflows whitespace")
    func locateAlignsAcrossTitleAndWhitespace() async throws {
        let source = "甲說了一句話。\n乙也說了一句話。"
        let laidOut = "第一章\n\n甲說了一句話。\n\n乙也說了一句話。"
        let query = ReaderBookSearchQuery(text: "一句話", isRegex: false)
        let hits = try await ReaderBookSearchMatcher.hits(of: query, chapterIndex: 0, text: source,
                                                          conversion: .original, limit: 10)
        let second = try #require(hits.last)
        let located = await ReaderBookSearchMatcher.locate(second, query: query, sourceText: source,
                                                           laidOutText: laidOut, conversion: .original)
        let expected = (laidOut as NSString).range(of: "一句話", options: .backwards)
        #expect(located == expected)
    }

    @Test("when the texts cannot be aligned, the hit's ordinal finds it")
    func locateFallsBackToOrdinal() async throws {
        let source = "圖前一句話。圖後一句話。"
        // An image placeholder the plain text has not: no alignment exists.
        let laidOut = "圖前一句話。\u{FFFC}圖後一句話。"
        let query = ReaderBookSearchQuery(text: "一句話", isRegex: false)
        let hits = try await ReaderBookSearchMatcher.hits(of: query, chapterIndex: 0, text: source,
                                                          conversion: .original, limit: 10)
        let second = try #require(hits.last)
        let located = await ReaderBookSearchMatcher.locate(second, query: query, sourceText: source,
                                                           laidOutText: laidOut, conversion: .original)
        #expect(located == (laidOut as NSString).range(of: "一句話", options: .backwards))
    }

    @Test("when the page holds a different number of matches, the ordinal is not trusted")
    func locateRefusesOrdinalWhenCountsDiffer() async throws {
        let source = "甲字乙字丙字"
        // A rule removed the middle one on the page: the page's second match is 丙's.
        let laidOut = "\u{FFFC}甲字乙丙字"
        let query = ReaderBookSearchQuery(text: "字", isRegex: false)
        let hits = try await ReaderBookSearchMatcher.hits(of: query, chapterIndex: 0, text: source,
                                                          conversion: .original, limit: 10)
        let located = await ReaderBookSearchMatcher.locate(hits[1], query: query, sourceText: source,
                                                           laidOutText: laidOut, conversion: .original)
        #expect(located == nil)
    }

    @Test("the session places a hit with the words drawn there, read as it was searched")
    func sessionLocatesHitWithDrawnWords() async throws {
        let session = ReaderBookSearchSession()
        session.options.appliesReplaceRules = false
        let source = "甲說了一句话。"
        let task = try #require(session.search("一句話", chapterTitles: ["一"],
            signature: .init(source: signature().source, conversion: .toTraditional, rulesRevision: 0)) { _, _ in
            .init(text: source, status: .available)
        })
        await task.value
        let hit = try #require(session.hits.first)
        var askedRules: [Bool] = []
        // The page keeps the source's own script, as a browser-laid-out EPUB chapter does.
        let located = await session.locate(hit, loadSource: { _, rules in
            askedRules.append(rules)
            return .init(text: source, status: .available)
        }, loadLaidOut: { _ in "第一章\n" + source })
        #expect(askedRules == [false])
        #expect(located?.range == NSRange(location: 7, length: 3))
        #expect(located?.drawnText == "一句话")
    }

    @Test("a search hit is washed with 朗讀高亮 off; narration is not")
    func searchHitIgnoresNarrationHighlightSetting() throws {
        let settings = GlobalSettings.shared
        let saved = settings.ttsHighlightEnabled
        settings.ttsHighlightEnabled = false
        defer { settings.ttsHighlightEnabled = saved }
        let text = NSAttributedString(string: "風起了，風停了。又起風了。\n",
                                      attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
        let chunk = try #require(CoreTextChunkSlicer.slice(attributedString: text, chapterIndex: 0,
                                                           contentWidth: 220, heightCap: 2000).chunks.first)
        let cell = CoreTextChunkCollectionCell(frame: CGRect(x: 0, y: 0, width: 260, height: 400))
        cell.bind(chunk: chunk, axis: .vertical, horizontalInset: 20, verticalInset: 0, leadingSpacing: 0,
                  viewportSize: CGSize(width: 260, height: 400))
        cell.applyPlaybackHighlight(ReaderPlaybackHighlight(text: "風停", expectedChapterOffset: 4, chapterIndex: 0))
        #expect(cell.playbackHighlightBounds(in: cell) == nil)
        cell.applyPlaybackHighlight(ReaderPlaybackHighlight(text: "風停", expectedChapterOffset: 4, chapterIndex: 0,
                                                            isSearchHit: true))
        #expect(cell.playbackHighlightBounds(in: cell) != nil)
    }

    @Test("a search hit keeps its kind when its offset moves to another space")
    func searchHitSurvivesOffsetMove() throws {
        let hit = try #require(ReaderPlaybackHighlight(text: "話", expectedChapterOffset: 10, chapterIndex: 2,
                                                       isSearchHit: true))
        let moved = hit.withExpectedChapterOffset(4)
        #expect(moved.isSearchHit)
        #expect(moved.expectedChapterOffset == 4)
        #expect(moved.chapterIndex == 2)
    }

    // MARK: - Session

    private func signature(revision: Int = 0) -> ReaderBookSearchSession.ContentSignature {
        .init(source: ReaderAISourceIdentity(bookID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                             sourceID: nil, source: "test", chapters: []),
              conversion: .original, rulesRevision: revision)
    }

    @Test("a search skips chapters not on the device, counts them, and groups hits by chapter")
    func sessionSearchesAvailableChaptersOnly() async throws {
        let session = ReaderBookSearchSession()
        let texts: [AILocalChapterText] = [
            .init(text: "風起了，風停了。", status: .available),
            .init(text: nil, status: .notDownloaded),
            .init(text: nil, status: .extractionFailed),
            .init(text: "又起風了。", status: .available),
        ]
        let task = try #require(session.search("風", chapterTitles: ["一", "二", "三", "四"],
                                               signature: signature()) { index, _ in texts[index] })
        await task.value
        #expect(session.phase == .finished)
        #expect(session.hits.map(\.chapterIndex) == [0, 0, 3])
        #expect(session.sections.map(\.title) == ["一", "四"])
        #expect(session.sections.map { $0.rows.map(\.index) } == [[0, 1], [2]])
        #expect(session.sections.flatMap(\.rows).map(\.hit) == session.hits)
        #expect(session.notDownloadedChapterCount == 1)
        #expect(session.searchedChapterCount == 4)
    }

    /// TestFlight 3.0.0 (140) "搜索后app闪退": the results list still lays out rows from the
    /// sections it last read while a new search or the field's clear button empties the hits.
    @Test("rows from sections read before a new search still resolve after it")
    func sessionSectionsOutliveNewSearch() async throws {
        let session = ReaderBookSearchSession()
        let first = try #require(session.search("風", chapterTitles: ["一", "二"], signature: signature()) { index, _ in
            .init(text: ["風起了，風停了。", "又起風了。"][index], status: .available)
        })
        await first.value
        let shown = session.sections
        let hits = session.hits

        session.clear()
        let second = try #require(session.search("停", chapterTitles: ["一", "二"], signature: signature()) { index, _ in
            .init(text: ["風起了，風停了。", "又起風了。"][index], status: .available)
        })
        await second.value

        #expect(session.hits.count == 1)
        let rows = shown.flatMap(\.rows)
        #expect(rows.map(\.hit) == hits)
        #expect(rows.map(\.index) == Array(hits.indices))
    }

    @Test("the replace-rule switch reaches the chapter loader")
    func sessionPassesReplaceRuleSwitch() async throws {
        let session = ReaderBookSearchSession()
        session.options.appliesReplaceRules = false
        var asked: [Bool] = []
        let task = try #require(session.search("字", chapterTitles: ["一"], signature: signature()) { _, rules in
            asked.append(rules)
            return .init(text: "字", status: .available)
        })
        await task.value
        #expect(asked == [false])
        #expect(session.searched?.appliesReplaceRules == false)
    }

    @Test("a bad pattern ends the search with that error and no results")
    func sessionReportsInvalidPattern() async throws {
        let session = ReaderBookSearchSession()
        session.options.isRegex = true
        let task = try #require(session.search("([", chapterTitles: ["一"], signature: signature()) { _, _ in
            .init(text: "text", status: .available)
        })
        await task.value
        #expect(session.phase == .failed(.invalidPattern))
        #expect(session.hits.isEmpty)
    }

    @Test("a book with nothing searchable says so instead of reporting no results")
    func sessionReportsUnsupportedBook() async throws {
        let session = ReaderBookSearchSession()
        let task = try #require(session.search("字", chapterTitles: ["一", "二"], signature: signature()) { _, _ in
            .init(text: nil, status: .unsupported)
        })
        await task.value
        #expect(session.phase == .failed(.unsupported))
    }

    @Test("the results stop at the limit and say so")
    func sessionStopsAtHitLimit() async throws {
        let session = ReaderBookSearchSession()
        let text = String(repeating: "字", count: ReaderBookSearchSession.hitLimit + 10)
        let task = try #require(session.search("字", chapterTitles: ["一", "二"], signature: signature()) { _, _ in
            .init(text: text, status: .available)
        })
        await task.value
        #expect(session.hits.count == ReaderBookSearchSession.hitLimit)
        #expect(session.reachedHitLimit)
    }

    @Test("results found in other text are stale")
    func sessionDetectsStaleResults() async throws {
        let session = ReaderBookSearchSession()
        let task = try #require(session.search("字", chapterTitles: ["一"], signature: signature()) { _, _ in
            .init(text: "字", status: .available)
        })
        await task.value
        #expect(!session.isStale(for: signature()))
        #expect(session.isStale(for: signature(revision: 1)))
    }

    @Test("stepping remembers where the reader began, across a new search, until it ends")
    func sessionNavigationKeepsOrigin() async throws {
        let session = ReaderBookSearchSession()
        let load: @MainActor (Int, Bool) async -> AILocalChapterText = { _, _ in .init(text: "字字字", status: .available) }
        await session.search("字", chapterTitles: ["一"], signature: signature(), load: load)?.value
        let start = CoreTextReadingPosition(spineIndex: 5, charOffset: 42)
        session.select(0, from: start)
        session.select(1, from: CoreTextReadingPosition(spineIndex: 0, charOffset: 1))
        #expect(session.hitIndex(offsetBy: 1) == 2)
        #expect(session.hitIndex(offsetBy: 2) == nil)
        await session.search("字", chapterTitles: ["一"], signature: signature(), load: load)?.value
        #expect(!session.isNavigating)
        session.select(2, from: nil)
        #expect(session.hitIndex(offsetBy: -2) == 0)
        #expect(session.hitIndex(offsetBy: -3) == nil)
        #expect(session.endNavigation() == start)
        #expect(session.origin == nil)
        #expect(!session.isNavigating)
    }

    /// The cost of one whole-book search on a web-novel-sized TXT (2000 chapters, ~2.9M
    /// characters), read through the builder the reader uses, rules applied. Prints the time.
    @Test("a long TXT is searched end to end through its builder")
    func searchesALongTXT() async throws {
        let paragraph = "他抬頭看了看天色，風從山那邊吹過來，帶著一點雨的味道。\n"
        var text = "", indexes: [TXTChapterIndex] = [], location = 0
        for chapter in 0..<2000 {
            let body = String(repeating: paragraph, count: 52) + (chapter % 10 == 0 ? "他們找到了山洞。\n" : "")
            let length = body.utf16.count
            indexes.append(TXTChapterIndex(index: chapter, title: "第\(chapter + 1)章",
                                           contentRange: NSRange(location: location, length: length)))
            text += body
            location += length
        }
        let builder = TXTLazyAttributedStringBuilder(text: text, chapterIndexes: indexes)
        let session = ReaderBookSearchSession()
        let started = ContinuousClock.now
        let task = try #require(session.search("山洞", chapterTitles: indexes.map(\.title), signature: signature()) {
            index, rules in await builder.localChapterText(at: index, applyingReplaceRules: rules)
        })
        await task.value
        let elapsed = ContinuousClock.now - started
        print("ReaderSearch long TXT: \(elapsed) for \(text.utf16.count) UTF-16 units, \(session.hits.count) hits")
        #expect(session.phase == .finished)
        #expect(session.hits.count == 200)
        #expect(session.sections.count == 200)
    }

    // MARK: - Recent searches

    @Test("a swipe removes one recent search and keeps the order of the rest")
    func recentSearchesRemoveAtOffsets() {
        let recents = RecentSearchQueries(queries: ["甲", "乙", "丙"])
        #expect(recents.removing(atOffsets: IndexSet(integer: 1)).queries == ["甲", "丙"])
    }
}
