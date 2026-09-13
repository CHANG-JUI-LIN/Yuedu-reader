import Foundation
import Testing
@testable import yuedu_app

@Suite("AI self-assessment envelope")
struct AISelfAssessmentTests {

    private let nonce = "N0NCE"

    private func envelope(_ json: String) -> String {
        "[[SELFASSESS:\(nonce)]]\(json)[[/SELFASSESS:\(nonce)]]"
    }

    @Test("the verdict is read and the envelope never reaches the reader")
    func parsesVerdictAndHidesEnvelope() {
        var parser = AISelfAssessmentStreamParser(nonce: nonce)
        var visible = parser.consume("張若塵在第三章離開。")
        visible += parser.consume(envelope(#"{"sufficient":"full"}"#))
        let (tail, assessment) = parser.finish()
        #expect(visible + tail == "張若塵在第三章離開。")
        #expect(assessment == AISelfAssessment(state: .full))
    }

    /// The failure this design exists to prevent: an SSE stream can split the marker between
    /// two deltas, and a naive parser flashes `[[SELFASS` on screen before the rest arrives.
    @Test("a marker split across deltas never flashes on screen")
    func markerSplitAcrossDeltasNeverLeaks() {
        let full = "答案。" + envelope(#"{"sufficient":"partial","missing":"結局"}"#)
        for splitIndex in 1..<full.count {
            var parser = AISelfAssessmentStreamParser(nonce: nonce)
            let cut = full.index(full.startIndex, offsetBy: splitIndex)
            var visible = parser.consume(String(full[..<cut]))
            visible += parser.consume(String(full[cut...]))
            let (tail, assessment) = parser.finish()
            let body = visible + tail
            #expect(body == "答案。", "split at \(splitIndex) produced \(body)")
            #expect(!body.contains("SELFASS"), "split at \(splitIndex) leaked a sentinel")
            #expect(assessment == AISelfAssessment(state: .partial, missing: "結局"))
        }
    }

    @Test("one character at a time is still clean")
    func characterByCharacterIsClean() {
        let full = "很久很久以前。" + envelope(#"{"sufficient":"insufficient"}"#)
        var parser = AISelfAssessmentStreamParser(nonce: nonce)
        var visible = ""
        for character in full { visible += parser.consume(String(character)) }
        let (tail, assessment) = parser.finish()
        #expect(visible + tail == "很久很久以前。")
        #expect(assessment.state == .insufficient)
    }

    @Test("an answer with no envelope is passed through whole")
    func absentEnvelopePassesThrough() {
        var parser = AISelfAssessmentStreamParser(nonce: nonce)
        let visible = parser.consume("完整的答案沒有信封。")
        let (tail, assessment) = parser.finish()
        #expect(visible + tail == "完整的答案沒有信封。")
        #expect(assessment.state == .absent)
    }

    /// A model that opens the envelope and stops must not be read as "the evidence was
    /// enough" — that would skip the agentic upgrade exactly when it is needed.
    @Test("a truncated envelope is malformed, never a passing verdict")
    func truncatedEnvelopeIsMalformed() {
        var parser = AISelfAssessmentStreamParser(nonce: nonce)
        _ = parser.consume("答案。[[SELFASSESS:\(nonce)]]{\"sufficient\":\"fu")
        let (_, assessment) = parser.finish()
        #expect(assessment.state == .malformed)
    }

    @Test("a control block with the wrong nonce is hidden and rejected")
    func foreignNonceIsHiddenAndRejected() {
        var parser = AISelfAssessmentStreamParser(nonce: nonce)
        let visible = parser.consume("答案。[[SELFASSESS:OTHER]]{\"sufficient\":\"full\"}[[/SELFASSESS:OTHER]]")
        let (tail, assessment) = parser.finish()
        #expect(!(visible + tail).contains("SELFASS"))
        #expect(visible + tail == "答案。")
        #expect(assessment.state == .malformed)
    }

    @Test("a payload that is too large, unknown, or oddly shaped is malformed")
    func rejectsBadPayloads() {
        let cases = [
            #"{"sufficient":"full","unexpected":1}"#,
            #"{"sufficient":"nonsense"}"#,
            #"{"sufficient":"malformed"}"#,
            #"{"sufficient":"absent"}"#,
            #"{"sufficient":"full","missing":123}"#,
            "{\"sufficient\":\"full\",\"missing\":\"\(String(repeating: "字", count: 41))\"}",
            "not json at all",
        ]
        for payload in cases {
            var parser = AISelfAssessmentStreamParser(nonce: nonce)
            _ = parser.consume("答案。" + envelope(payload))
            let (_, assessment) = parser.finish()
            #expect(assessment.state == .malformed, "payload \(payload) should be malformed")
        }
    }

    @Test("text after the closing marker is not smuggled back into the answer")
    func rejectsTrailingContent() {
        var parser = AISelfAssessmentStreamParser(nonce: nonce)
        let visible = parser.consume("答案。" + envelope(#"{"sufficient":"full"}"#) + "偷渡的內容")
        let (tail, assessment) = parser.finish()
        #expect(!(visible + tail).contains("偷渡"))
        #expect(assessment.state == .malformed)
    }

    /// Non-streaming paths share the same display boundary.
    @Test("the non-streaming cut is the same boundary")
    func nonStreamingCut() {
        #expect(
            AISelfAssessment.userVisibleText("答案。[[SELFASSESS:X]]{}[[/SELFASSESS:X]]") == "答案。"
        )
        #expect(AISelfAssessment.userVisibleText("沒有信封") == "沒有信封")
    }
}
