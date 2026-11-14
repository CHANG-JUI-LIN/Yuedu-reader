import Foundation
import Testing
@testable import yuedu_app

/// FB-177: 「人物抽取格式不完整」 named no rule, so a rejected batch could not be diagnosed.
/// Every rule that rejects a reply now names itself — in the thrown failure (the job's
/// `failure`, which the page shows), in the request trace and in the device log.
@Suite("AI character memory names the rule that rejected a reply (FB-177)", .serialized)
struct AIMemoryRejectionReasonTests {
    let book = UUID()
    static let text = "柳青站在門邊。蒙面人到了。柳青沒有說話。"

    func source(_ text: String = AIMemoryRejectionReasonTests.text) -> AIBookContentAdapter {
        AIBookContentAdapter(bookID: book, chapters: [.init(index: 0, title: "Fixture", content: "")]) { _ in text }
            .atReadingPosition(spine: 0, renderedOffset: text.utf16.count, renderedText: text)
    }
    func input(_ source: AIBookContentAdapter) throws -> AIMemoryExtraction.Input {
        let job = try AIMemoryPlanner.plan(source: source, boundary: source.boundary(wholeBook: true), provider: "memory-mock",
            model: "scripted-fixture", budget: .init(), language: .traditionalChinese)
        return try AIMemoryExtraction.input(unit: job.units[0], source: source, job: job, previous: [])
    }

    static func mention(_ id: String = "m1", surface: String = "柳青站在門邊", type: String = "person",
                        evidence: [String: Any] = ["segmentID": "s0"]) -> [String: Any] {
        ["id": id, "surface": surface, "type": type, "unresolved": false, "evidence": evidence]
    }
    static func fact(entities: [String] = ["m1"], text: String = "站在門邊。", evidence: [[String: Any]] = [["segmentID": "s0"]]) -> [String: Any] {
        ["entities": entities, "kind": "narration", "text": text, "evidence": evidence]
    }
    static func alias(_ first: String = "m1", _ second: String = "m2", evidence: [[String: Any]] = [["segmentID": "s0"]]) -> [String: Any] {
        ["first": first, "second": second, "evidence": evidence]
    }
    static var second: [String: Any] { mention("m2", surface: "蒙面人") }
    static func reply(complete: Bool = true, mentions: [[String: Any]] = [mention()], facts: [[String: Any]] = [],
                      aliases: [[String: Any]] = []) -> String {
        let json: [String: Any] = ["complete": complete, "mentions": mentions, "facts": facts, "aliases": aliases]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    struct Rejection {
        let failure: AIMemoryFailure?
        let events: [[String: String]]
        let export: String
        let log: [String]
    }
    /// Runs `validate` the way the service does — inside a request trace — and returns what a
    /// rejected reply left behind.
    func reject(_ content: String, changedSource: Bool = false) throws -> Rejection {
        let source = source(), input = try input(source)
        let trace = AIRequestTrace(feature: "characterMemory", bookID: book, adapter: source, boundary: source.boundary(), origin: .testFixture)
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        var failure: AIMemoryFailure?
        AIDiagnostics.$current.withValue(trace) {
            do {
                _ = try AIMemoryExtraction.validate(raw: .init(content: content, provider: "mock", model: "mock"), input: input,
                    source: changedSource ? self.source("柳青站在窗邊。蒙面人到了。柳青沒有說話。") : source)
                Issue.record("the reply was accepted")
            } catch { failure = error as? AIMemoryFailure }
        }
        let data = try trace.export(including: ["messages", "response", "evidence"])
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = (root["events"] as? [[String: Any]] ?? []).filter { $0["stage"] as? String == "memoryRejected" }
            .compactMap { $0["values"] as? [String: String] }
        let log = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains(input.unit.id) }.map(\.message)
        return .init(failure: failure, events: events, export: String(decoding: data, as: UTF8.self), log: log)
    }

    static let fixtures: [(reason: String, content: String)] = [
        ("replyIncomplete", reply(complete: false)),
        ("mentionType", reply(mentions: [mention(type: "place")])),
        ("mentionID", reply(mentions: [mention("")])),
        ("mentionID", reply(mentions: [mention(String(repeating: "m", count: 81))])),
        ("mentionIDReused", reply(mentions: [mention(), mention(surface: "蒙面人")])),
        ("mentionSurface", reply(mentions: [mention(surface: " \n")])),
        ("mentionSurface", reply(mentions: [mention(surface: String(repeating: "柳", count: 101))])),
        ("factEntities", reply(facts: [fact(entities: [])])),
        ("factEntities", reply(facts: [fact(entities: ["m1", "nobody"])])),
        ("factText", reply(facts: [fact(text: " ")])),
        ("factText", reply(facts: [fact(text: String(repeating: "字", count: 2_001))])),
        ("factNoEvidence", reply(facts: [fact(evidence: [])])),
        ("aliasReference", reply(mentions: [mention(), second], aliases: [alias("m1", "k9")])),
        ("aliasSelf", reply(mentions: [mention(), second], aliases: [alias("m1", "m1")])),
        ("aliasNoEvidence", reply(mentions: [mention(), second], aliases: [alias(evidence: [])])),
        ("evidenceSegment", reply(mentions: [mention(evidence: ["segmentID": "s999"])])),
        ("evidenceQuote", reply(mentions: [mention(surface: "柳青", evidence: ["segmentID": "s0", "quote": "柳青"])])),
        ("evidenceQuote", reply(mentions: [mention(evidence: ["segmentID": "s0", "quote": "柳青說了原文沒有的話"])])),
        ("surfaceNotInEvidence", reply(mentions: [mention(surface: "未出現的人")])),
    ]

    @Test(arguments: fixtures.indices)
    func eachRuleNamesItself(index: Int) throws {
        let fixture = Self.fixtures[index]
        let result = try reject(fixture.content)
        #expect(result.failure?.rawValue == fixture.reason)
        #expect(result.events.count == 1)
        #expect(result.events.first?["reason"] == fixture.reason)
        #expect(result.events.first?["unitID"]?.isEmpty == false)
        #expect(result.log.contains { $0.contains(fixture.reason) })
        // The page shows the same sentence as before, with the rule after it.
        #expect(result.failure?.localizedDescription.contains(fixture.reason) == true)
    }

    @Test func aQuoteTheBookNoLongerHoldsNamesItself() throws {
        let result = try reject(Self.reply(mentions: [Self.mention(evidence: ["segmentID": "s0", "quote": "柳青站在門邊"])]), changedSource: true)
        #expect(result.failure?.rawValue == "evidenceSource")
        #expect(result.events.first?["reason"] == "evidenceSource")
    }

    @Test func aReplyThatIsNotJSONKeepsTheDecodingError() throws {
        let result = try reject("好的，以下是人物：柳青、蒙面人")
        #expect(result.failure?.rawValue == "replyUndecodable")
        let values = try #require(result.events.first)
        #expect(values["reason"] == "replyUndecodable")
        #expect(values["decoding"]?.contains("dataCorrupted") == true)
        #expect(values["characters"] == "15" && values["startsWithBrace"] == "false")
        #expect(result.log.contains { $0.contains("replyUndecodable") && $0.contains("dataCorrupted") })
    }

    @Test func aMissingFieldIsNamedWithItsPath() throws {
        let missingKey = try reject(#"{"complete":true,"mentions":[],"facts":[]}"#)
        #expect(missingKey.failure?.rawValue == "replyUndecodable")
        #expect(missingKey.events.first?["decoding"]?.contains("keyNotFound") == true)
        #expect(missingKey.events.first?["decoding"]?.contains("aliases") == true)

        // DeepSeek-style drift is the kind of thing this has to show: a field of the wrong
        // type, three levels down.
        let wrongType = try reject(Self.reply(mentions: [Self.mention(evidence: ["segmentID": 0])]))
        let decoding = try #require(wrongType.events.first?["decoding"])
        #expect(decoding.contains("typeMismatch") && decoding.contains("mentions[0].evidence.segmentID"))
    }

    @Test func whatWasRejectedIsDescribedByShapeNeverByItsText() throws {
        for fixture in Self.fixtures + [("replyUndecodable", "好的，以下是人物：柳青、蒙面人")] {
            let result = try reject(fixture.content)
            for text in ["柳青", "蒙面人", "未出現的人", "門邊"] {
                #expect(!result.export.contains(text), "\(fixture.reason) kept \(text) in the trace")
                #expect(!result.log.contains { $0.contains(text) }, "\(fixture.reason) kept \(text) in the log")
            }
        }
    }

    @Test func savedJobsStillReadTheirOldFailure() {
        #expect(AIMemoryFailure(rawValue: "invalidSchema") == .invalidSchema)
        #expect(AIMemoryFailure(rawValue: "invalidEvidence") == .invalidEvidence)
    }
}
