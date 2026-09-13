import Foundation
import Testing
@testable import yuedu_app

@Suite("AI speaker roster")
struct AISpeakerRosterTests {

    /// The failure this exists for. The dialogue heuristic strips a speech verb off the end
    /// of the narration, so 試探道 leaves 試探, 一邊道 leaves 一邊, and 劉癩子苦笑道 leaves
    /// 劉癩子苦. No blocklist of characters fixes this in Chinese; the model decides.
    @Test("non-people are dropped and mangled names are repaired")
    func filtersAndCanonicalises() {
        let answer = """
        {"names":{"試探":"","一邊":"","劉癩子苦":"劉癩子","張若塵":"張若塵","若塵":"張若塵"}}
        """
        let roster = AISpeakerRoster.parse(
            answer,
            candidates: ["試探", "一邊", "劉癩子苦", "張若塵", "若塵"]
        )
        #expect(roster["試探"] == nil)
        #expect(roster["一邊"] == nil)
        #expect(roster["劉癩子苦"] == "劉癩子")
        #expect(roster["張若塵"] == "張若塵")
        #expect(roster["若塵"] == "張若塵")
    }

    @Test("a fenced answer parses")
    func parsesFencedAnswer() {
        let roster = AISpeakerRoster.parse(
            "```json\n{\"names\":{\"哭\":\"\",\"池瑤\":\"池瑤\"}}\n```",
            candidates: ["哭", "池瑤"]
        )
        #expect(roster["哭"] == nil)
        #expect(roster["池瑤"] == "池瑤")
    }

    /// A truncated or lazy answer must not silently delete characters the reader may have
    /// already cast a voice for — an unmentioned candidate keeps itself.
    @Test("a candidate the model skipped survives as itself")
    func unmentionedCandidatesSurvive() {
        let roster = AISpeakerRoster.parse(
            #"{"names":{"試探":""}}"#,
            candidates: ["試探", "張若塵", "池瑤"]
        )
        #expect(roster["試探"] == nil)
        #expect(roster["張若塵"] == "張若塵")
        #expect(roster["池瑤"] == "池瑤")
    }

    @Test("an unparseable answer changes nothing")
    func unparseableAnswerIsInert() {
        let roster = AISpeakerRoster.parse("模型今天不想講話", candidates: ["張若塵", "試探"])
        #expect(roster == ["張若塵": "張若塵", "試探": "試探"])
    }

    /// 一邊 on its own could be a name; `他一邊道：「…」` obviously is not. The context is
    /// what makes the judgement possible.
    @Test("each candidate is sent with the prose it came from")
    func requestCarriesContext() {
        let request = AISpeakerRoster.request(candidates: [
            AISpeakerRoster.Candidate(name: "一邊", lineCount: 2, sample: "他一邊道：「快走。」"),
        ])
        #expect(request.messages.map(\.role) == [.system, .user])
        #expect(request.messages[1].content.contains("他一邊道"))
        #expect(request.messages[1].content.contains("一邊"))
        // Book text stays out of the system role.
        #expect(!request.messages[0].content.contains("他一邊道"))
    }

    // MARK: - Book-wide scan

    /// Character cards are a book-level thing — who someone is does not change between
    /// chapters — so the list must not be scoped to whichever chapter is playing.
    @Test("the scan covers every chapter and ranks by how much each speaks")
    func scanIsBookWideAndRanked() {
        let sections = [
            AIChunkableSection(id: "0", text: """
            張若塵道：「我知道了。」
            張若塵又道：「不急。」
            """),
            AIChunkableSection(id: "1", text: "池瑤道：「走吧。」"),
        ]
        let speakers = AIBookSpeakerScan.scan(sections: sections)
        #expect(speakers.first?.name == "張若塵")
        #expect(speakers.first?.lineCount == 2)
        #expect(speakers.contains { $0.name == "池瑤" })
    }

    @Test("the scan carries an excerpt for each speaker")
    func scanCarriesSamples() throws {
        let sections = [AIChunkableSection(id: "0", text: "張若塵道：「我知道了。」")]
        let speaker = try #require(AIBookSpeakerScan.scan(sections: sections).first)
        #expect(!speaker.sample.isEmpty)
        #expect(speaker.sample.contains("張若塵"))
    }

    @Test("aliases fold a character's names into one count")
    func scanFoldsAliases() {
        let sections = [
            AIChunkableSection(id: "0", text: """
            張若塵道：「一。」
            若塵道：「二。」
            """),
        ]
        let speakers = AIBookSpeakerScan.scan(sections: sections, aliases: ["若塵": "張若塵"])
        #expect(speakers.count == 1)
        #expect(speakers.first?.lineCount == 2)
    }
}
