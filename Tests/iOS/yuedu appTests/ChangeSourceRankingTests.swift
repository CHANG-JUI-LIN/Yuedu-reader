import Testing
import Foundation
@testable import yuedu_app

/// The 換源 list's order, 篩選, 👍/👎 and 分組 — Legado `ChangeBookSourceViewModel`'s
/// comparators and `SourceConfig`'s scores, as `ChangeSourceRanking` / `ChangeSourceScores` /
/// `ChangeSourceScope` implement them.
@Suite("Change source ranking")
struct ChangeSourceRankingTests {

    private static func origin(_ name: String, sourceId: UUID = UUID()) -> BookOrigin {
        BookOrigin(
            sourceId: sourceId, sourceName: name, bookUrl: "https://\(name).example/book",
            tocUrl: "", coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "",
            runtimeVariables: nil
        )
    }

    private static func candidate(
        _ name: String,
        arrival: Int,
        isFailed: Bool = false,
        bookScore: Int = 0,
        sourceScore: Int = 0,
        pin: SourcePinPosition? = nil,
        responseKey: Double = 0,
        probe: ChangeSourceProbe? = nil
    ) -> ChangeSourceRanking.Candidate {
        .init(origin: origin(name), arrival: arrival, isFailed: isFailed, bookScore: bookScore,
              sourceScore: sourceScore, pin: pin, responseKey: responseKey, probe: probe)
    }

    private static func names(_ candidates: [ChangeSourceRanking.Candidate], byWordCount: Bool = false) -> [String] {
        ChangeSourceRanking.ordered(candidates, byWordCount: byWordCount).map(\.sourceName)
    }

    @Test("a failed switch sinks below everything, even a liked source")
    func failedSinks() {
        let order = Self.names([
            Self.candidate("liked-but-failed", arrival: 0, isFailed: true, bookScore: 1),
            Self.candidate("plain", arrival: 1),
        ])
        #expect(order == ["plain", "liked-but-failed"])
    }

    @Test("the book's 👍 comes first, then the source's sum, then 置頂／置底")
    func scoresThenPins() {
        let order = Self.names([
            Self.candidate("bottom", arrival: 0, pin: .bottom),
            Self.candidate("disliked", arrival: 1, bookScore: -1),
            Self.candidate("top", arrival: 2, pin: .top),
            Self.candidate("source-liked", arrival: 3, sourceScore: 2),
            Self.candidate("book-liked", arrival: 4, bookScore: 1),
            Self.candidate("plain", arrival: 5),
        ])
        #expect(order == ["book-liked", "source-liked", "top", "plain", "bottom", "disliked"])
    }

    @Test("without 加載字數 the faster source comes first, then arrival")
    func responseThenArrival() {
        let order = Self.names([
            Self.candidate("slow", arrival: 0, responseKey: 900),
            Self.candidate("fast-late", arrival: 2, responseKey: 100),
            Self.candidate("fast-early", arrival: 1, responseKey: 100),
        ])
        #expect(order == ["fast-early", "fast-late", "slow"])
    }

    @Test("加載字數: a real chapter first, then the further chapter, then the longer one")
    func wordCountOrder() {
        func probe(index: Int, count: Int) -> ChangeSourceProbe {
            var probe = ChangeSourceProbe()
            probe.chapterIndex = index
            probe.wordCount = count
            return probe
        }
        let candidates = [
            Self.candidate("stub", arrival: 0, responseKey: 1, probe: probe(index: 900, count: 120)),
            Self.candidate("short-far", arrival: 1, responseKey: 2, probe: probe(index: 899, count: 2_400)),
            Self.candidate("long-far", arrival: 2, responseKey: 3, probe: probe(index: 899, count: 3_100)),
            Self.candidate("further", arrival: 3, responseKey: 4, probe: probe(index: 900, count: 1_500)),
            Self.candidate("failed-count", arrival: 4, responseKey: 0, probe: probe(index: 0, count: -1)),
        ]
        #expect(Self.names(candidates, byWordCount: true)
                == ["further", "long-far", "short-far", "stub", "failed-count"])
        // The word counts mean nothing with 加載字數 off: response time decides.
        #expect(Self.names(candidates, byWordCount: false)
                == ["failed-count", "stub", "short-far", "long-far", "further"])
    }

    @Test("篩選 matches the source's name or the latest chapter, ignoring case")
    func filter() {
        #expect(ChangeSourceRanking.matches(sourceName: "Biquge 筆趣閣", lastChapter: "", filter: "biquge"))
        #expect(ChangeSourceRanking.matches(sourceName: "甲", lastChapter: "第 1450 章 終章", filter: "終章"))
        #expect(!ChangeSourceRanking.matches(sourceName: "甲", lastChapter: "第 3 章", filter: "終章"))
        #expect(ChangeSourceRanking.matches(sourceName: "甲", lastChapter: "", filter: "  "))
    }
}

@Suite("Change source scores")
@MainActor
struct ChangeSourceScoresTests {
    private func freshScores() -> (ChangeSourceScores, UserDefaults, String) {
        let suite = "ChangeSourceScoresTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ChangeSourceScores(defaults: defaults), defaults, suite)
    }

    @Test("a book's 👍／👎 moves its source's sum by the difference, clamped to -1…1")
    func sumFollowsBookScores() {
        let (scores, defaults, suite) = freshScores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = UUID()

        scores.setBookScore(5, sourceId: source, name: "書甲", author: "作者")
        #expect(scores.bookScore(sourceId: source, name: "書甲", author: "作者") == 1)
        scores.setBookScore(1, sourceId: source, name: "書乙", author: "作者")
        #expect(scores.sourceScore(sourceId: source) == 2)

        scores.setBookScore(-1, sourceId: source, name: "書甲", author: "作者")
        #expect(scores.sourceScore(sourceId: source) == 0)
        scores.setBookScore(0, sourceId: source, name: "書乙", author: "作者")
        #expect(scores.sourceScore(sourceId: source) == -1)
        #expect(scores.bookScore(sourceId: source, name: "書乙", author: "作者") == 0)
    }

    @Test("scores persist, and deleting a source forgets them")
    func persistAndRemove() {
        let (scores, defaults, suite) = freshScores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = UUID(), deleted = UUID()
        scores.setBookScore(1, sourceId: kept, name: "書", author: "")
        scores.setBookScore(-1, sourceId: deleted, name: "書", author: "")

        let reloaded = ChangeSourceScores(defaults: defaults)
        #expect(reloaded.bookScore(sourceId: kept, name: "書", author: "") == 1)
        #expect(reloaded.sourceScore(sourceId: deleted) == -1)

        reloaded.removeSource(deleted)
        #expect(reloaded.sourceScore(sourceId: deleted) == 0)
        #expect(reloaded.bookScore(sourceId: deleted, name: "書", author: "") == 0)
        #expect(ChangeSourceScores(defaults: defaults).sourceScore(sourceId: kept) == 1)
    }
}

@Suite("Change source group scope")
struct ChangeSourceScopeTests {
    private static func source(_ name: String, groups: String, enabled: Bool = true) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://\(name).example", bookSourceName: name)
        source.bookSourceGroup = groups
        source.enabled = enabled
        return source
    }

    @Test("groups come from enabled sources, comma-separated, in first-seen order")
    func groupsInOrder() {
        let sources = [
            Self.source("a", groups: "精品, 男頻"),
            Self.source("b", groups: "男頻,女頻"),
            Self.source("off", groups: "停用組", enabled: false),
        ]
        #expect(ChangeSourceScope.groups(of: sources) == ["精品", "男頻", "女頻"])
    }

    @Test("a group keeps its sources; the empty group is every one")
    func scope() {
        let sources = [Self.source("a", groups: "精品,男頻"), Self.source("b", groups: "女頻")]
        #expect(ChangeSourceScope.sources(sources, in: "男頻").map(\.bookSourceName) == ["a"])
        #expect(ChangeSourceScope.sources(sources, in: "").map(\.bookSourceName) == ["a", "b"])
        #expect(ChangeSourceScope.sources(sources, in: "沒有").isEmpty)
    }
}
