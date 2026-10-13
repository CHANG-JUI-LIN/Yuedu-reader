import Foundation
import Testing
@testable import yuedu_app

// Discovery Phase 7a-3: 為你推薦's order, made on the device from what the inputs offered.

@MainActor
@Suite("For You ranker")
struct ForYouRankerTests {
    private let sources = ["a", "b", "c", "d"].map { BookSource(bookSourceUrl: "https://\($0).test", bookSourceName: $0) }

    private func candidate(_ title: String, author: String = "作者", source: Int, position: Int,
                           kind: String = "", language: String? = nil) -> ForYouCandidate {
        let book = OnlineBook(name: title, author: author, intro: "", coverUrl: "", bookUrl: "https://x.test/\(title)",
                              tocUrl: "", wordCount: "", lastChapter: "", kind: kind,
                              sourceId: sources[source].id, sourceName: sources[source].bookSourceName)
        var entry = CollectionEntry.onlineBook(book, source: sources[source])
        if let language, case .item(let record, var summary, let opening) = entry {
            summary.language = language
            entry = .item(record, summary, opening)
        }
        return ForYouCandidate(entry: entry, source: sources[source].bookSourceUrl, position: position,
                               tags: ReadingGenreProfile.tags(fromSourceKind: kind))
    }

    private func titles(_ entries: [CollectionEntry]) -> [String] {
        entries.compactMap { if case .item(_, let summary, _) = $0 { summary.title } else { nil } }
    }

    private func rank(_ candidates: [ForYouCandidate], shelf: [ReadingBook] = [], weights: [String: Double] = [:],
                      recent: ForYouRanker.Recent = .init(), shown: Set<String> = [],
                      languages: ReadingLanguagePreferences = .init(languages: ["zh"], scope: .any),
                      seed: UInt64 = 1, limit: Int = 12) -> [String] {
        titles(ForYouRanker.rank(candidates: candidates, shelf: ForYouRanker.shelfWorks(shelf), weights: weights,
                                 recent: recent, recentlyShown: shown, languages: languages, seed: seed, limit: limit))
    }

    @Test("a work offered by two sources shows once, from the first")
    func dedupe() throws {
        let result = ForYouRanker.rank(
            candidates: [candidate("三體", author: "劉慈欣", source: 0, position: 0),
                         candidate("三体", author: "刘慈欣", source: 1, position: 0),
                         candidate("球狀閃電", author: "劉慈欣", source: 1, position: 1)],
            shelf: [], weights: [:], recent: .init(), recentlyShown: [],
            languages: .init(languages: ["zh"], scope: .any), seed: 1, limit: 12)
        #expect(titles(result).sorted() == ["三體", "球狀閃電"])
        guard case .item(let record, _, _) = result.first(where: { titles([$0]) == ["三體"] }) else {
            Issue.record("expected the work"); return
        }
        #expect(record.key.instance.id == sources[0].bookSourceUrl)
    }

    @Test("books on the shelf are left out, online copies included")
    func shelf() {
        var online = ReadingBook(title: "詭秘之主", author: "愛潛水的烏賊", source: "https://a.test/b", contentFilename: "")
        online.isOnline = true
        let local = ReadingBook(title: "Dune", author: "Frank Herbert", source: "dune.epub", contentFilename: "dune.epub")
        let result = rank([candidate("诡秘之主", author: "爱潜水的乌贼", source: 0, position: 0),
                           candidate("Dune", author: "Frank Herbert", source: 1, position: 0),
                           candidate("Dune", author: "Someone Else", source: 2, position: 0)],
                          shelf: [online, local])
        #expect(result == ["Dune"], "a namesake by another author stays")
    }

    @Test("no source holds more than a third of the section")
    func cap() {
        let many = (0..<20).map { candidate("甲\($0)", source: 0, position: $0, kind: "玄幻") }
        let few = (0..<3).map { candidate("乙\($0)", source: 1, position: $0) } + (0..<3).map { candidate("丙\($0)", source: 2, position: $0) }
        let result = rank(many + few, weights: ["玄幻": 1], limit: 12)
        #expect(result.filter { $0.hasPrefix("甲") }.count == 4)
        #expect(result.count == 10)
    }

    @Test("a new reader gets the sources' own order, taken in turns")
    func newReader() {
        let candidates = (0..<3).flatMap { source in (0..<3).map { candidate("\(source)-\($0)", source: source, position: $0) } }
        let result = rank(candidates, limit: 8)
        #expect(Array(result.prefix(3)) == ["0-0", "1-0", "2-0"])
        #expect(result.count == 8)
    }

    @Test("the reader's genres and 繼續閱讀 come first")
    func preferences() {
        let candidates = [candidate("平", source: 0, position: 0, kind: "都市"),
                          candidate("類型", source: 1, position: 5, kind: "科幻"),
                          candidate("作者", author: "辰東", source: 2, position: 5)]
        let result = rank(candidates, weights: ["科幻": 1], recent: .init(authors: ["辰东"], tags: []), limit: 4)
        #expect(Array(result.prefix(2)).sorted() == ["作者", "類型"])
        #expect(result.last == "平")
    }

    @Test("a quarter of the section is books not shown this week, the same for a seed")
    func exploration() {
        let candidates = (0..<4).flatMap { source in (0..<6).map { candidate("\(source)-\($0)", source: source, position: $0) } }
        let shown = Set(candidates.prefix(12).map { ForYouRanker.workKey(of: $0.entry)! })
        let first = rank(candidates, shown: shown, seed: 7, limit: 8)
        let unseen = Set(candidates.dropFirst(12).map { titles([$0.entry])[0] })
        let ranked = rank(candidates, shown: [], seed: 7, limit: 8)
        #expect(first.count == 8)
        #expect(first.filter(unseen.contains).count >= 2)
        #expect(first == rank(candidates, shown: shown, seed: 7, limit: 8))
        #expect(Array(first.prefix(3)) == Array(ranked.prefix(3)), "explored books fill every fourth place")
    }

    @Test("only the preferred languages, when the reader asks for only those")
    func languages() {
        let candidates = [candidate("英", source: 0, position: 0, language: "en"),
                          candidate("中", source: 1, position: 0, language: "zh"),
                          candidate("未知", source: 2, position: 0)]
        #expect(rank(candidates, languages: .init(languages: ["zh"], scope: .only)) == ["中", "未知"])
        #expect(rank(candidates, languages: .init(languages: ["zh"], scope: .prefer)).first == "中")
    }
}

@Suite("For You exposure log")
struct ForYouExposureLogTests {
    @Test("a work counts as shown for 7 days")
    func week() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var log = ForYouExposureLog()
        log.record(["甲"], at: start)
        #expect(log.recentlyShown(at: start.addingTimeInterval(6 * 86_400)) == ["甲"])
        #expect(log.recentlyShown(at: start.addingTimeInterval(7 * 86_400 + 1)).isEmpty)
        log.record(["乙"], at: start.addingTimeInterval(8 * 86_400))
        #expect(log.recentlyShown(at: start.addingTimeInterval(8 * 86_400)) == ["乙"], "old entries are dropped")
    }
}
