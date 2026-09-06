import Foundation
import Testing
@testable import yuedu_app

/// Paragraph reviews, 本章说 and 神评论 are drawn by the source as SVG and reach the
/// layout as image attachments, so in the chapter string they are `U+FFFC` — not words.
/// They were never stripped before narration, so they ate into the 300-character chunk
/// budget and were sent to the provider as literal `%EF%BF%BC`.
@Suite("TTS narratable text")
struct TTSNarratableTextTests {

    private func narratable(_ raw: String) -> String {
        ReaderView.narratableText(from: raw)
    }

    @Test("attachment markers are removed")
    func attachmentMarkersRemoved() {
        #expect(!narratable("他说\u{FFFC}了一句话").contains("\u{FFFC}"))
        #expect(narratable("他说\u{FFFC}了一句话") == "他说了一句话")
    }

    /// The case that produced a request with nothing to say: a paragraph whose entire
    /// content was review anchors.
    @Test("a run of nothing but markers narrates as empty")
    func markerOnlyParagraphIsEmpty() {
        #expect(narratable("\u{FFFC}\u{FFFC}\u{FFFC}").isEmpty)
        #expect(narratable("  \u{FFFC} \u{FFFC}  ").isEmpty)
    }

    /// Removing a marker leaves the spaces that surrounded it behind.
    @Test("whitespace stranded by a removed marker is collapsed")
    func strandedWhitespaceCollapses() {
        #expect(narratable("第一句 \u{FFFC} 第二句") == "第一句 第二句")
    }

    @Test("blank lines left behind collapse to one break")
    func blankLinesCollapse() {
        #expect(narratable("第一段\n\u{FFFC}\n\n\u{FFFC}\n第二段") == "第一段\n\n第二段")
    }

    /// Paragraph structure is what the chunker splits on, so real breaks must survive.
    @Test("real paragraph breaks survive")
    func paragraphBreaksSurvive() {
        #expect(narratable("第一段\n\n第二段") == "第一段\n\n第二段")
    }

    @Test("ordinary prose is untouched")
    func ordinaryProseUntouched() {
        let text = "第一章 医院\n\n夜晚时分，他走进了那扇门。"
        #expect(narratable(text) == text)
    }

    /// The chunk budget is what this is really about: 300 characters of markers used to
    /// displace 300 characters of speech.
    @Test("markers no longer consume the chunk budget")
    func markersDoNotConsumeBudget() {
        let noisy = String(repeating: "字\u{FFFC}", count: 200)
        #expect(narratable(noisy).count == 200)
    }
}
