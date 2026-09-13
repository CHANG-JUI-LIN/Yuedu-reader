import Foundation
import Testing
@testable import yuedu_app

@Suite("Playback highlight positioning")
struct ReaderPlaybackHighlightTests {

    /// The whole point of the type: a chapter that says 「嗯。」 twice used to wash the
    /// first one no matter which the listener was hearing.
    @Test("a repeated line washes the occurrence the reader expects")
    func picksOccurrenceNearestTheHint() throws {
        let chapter = "「嗯。」他點頭。走了很久很久之後，她也說「嗯。」" as NSString
        let second = chapter.range(of: "「嗯。」", options: .backwards)
        let highlight = try #require(
            ReaderPlaybackHighlight(text: "「嗯。」", expectedChapterOffset: second.location)
        )
        let found = highlight.occurrence(
            in: chapter,
            searchRange: NSRange(location: 0, length: chapter.length)
        )
        #expect(found == second)
    }

    @Test("a hint near the first occurrence still picks the first")
    func picksFirstWhenTheHintIsThere() throws {
        let chapter = "「嗯。」他點頭。走了很久很久之後，她也說「嗯。」" as NSString
        let highlight = try #require(
            ReaderPlaybackHighlight(text: "「嗯。」", expectedChapterOffset: 0)
        )
        #expect(
            highlight.occurrence(
                in: chapter,
                searchRange: NSRange(location: 0, length: chapter.length)
            ) == NSRange(location: 0, length: 4)
        )
    }

    /// Media overlays and the non-CoreText narration paths have no mapping to give, and
    /// must keep behaving exactly as they did.
    @Test("without a hint the first occurrence wins, as before")
    func fallsBackToFirstMatch() throws {
        let chapter = "「嗯。」他點頭。她也說「嗯。」" as NSString
        let highlight = try #require(ReaderPlaybackHighlight(text: "「嗯。」"))
        #expect(
            highlight.occurrence(
                in: chapter,
                searchRange: NSRange(location: 0, length: chapter.length)
            ) == NSRange(location: 0, length: 4)
        )
    }

    /// A hint derived while chapter 4 was being read must not steer a page of chapter 7.
    @Test("a hint from another chapter is ignored")
    func ignoresHintFromAnotherChapter() throws {
        let chapter = "「嗯。」他點頭。走了很久很久之後，她也說「嗯。」" as NSString
        let second = chapter.range(of: "「嗯。」", options: .backwards)
        let highlight = try #require(
            ReaderPlaybackHighlight(
                text: "「嗯。」",
                expectedChapterOffset: second.location,
                chapterIndex: 4
            )
        )
        #expect(
            highlight.occurrence(
                in: chapter,
                searchRange: NSRange(location: 0, length: chapter.length),
                chapterIndex: 7
            ) == NSRange(location: 0, length: 4)
        )
    }

    /// Paged and scroll rendering both search one page/chunk of the chapter, and the
    /// returned range has to be usable in the chapter's own coordinates.
    @Test("the search stays inside the page and answers in chapter coordinates")
    func honoursTheSearchRange() throws {
        let chapter = "「嗯。」他點頭。走了很久很久之後，她也說「嗯。」" as NSString
        let second = chapter.range(of: "「嗯。」", options: .backwards)
        let pageTwo = NSRange(location: 8, length: chapter.length - 8)
        let highlight = try #require(
            ReaderPlaybackHighlight(text: "「嗯。」", expectedChapterOffset: 0)
        )
        // The hint points at page one, but page two can only draw its own text.
        #expect(highlight.occurrence(in: chapter, searchRange: pageTwo) == second)
        #expect(
            highlight.occurrence(in: chapter, searchRange: NSRange(location: 0, length: 8)) != nil
        )
    }

    @Test("an out-of-range search window is refused rather than trapping")
    func refusesImpossibleSearchRange() throws {
        let chapter = "「嗯。」" as NSString
        let highlight = try #require(ReaderPlaybackHighlight(text: "「嗯。」"))
        #expect(highlight.occurrence(in: chapter, searchRange: NSRange(location: 0, length: 99)) == nil)
        #expect(highlight.occurrence(in: chapter, searchRange: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("blank text produces no highlight at all")
    func rejectsBlankText() {
        #expect(ReaderPlaybackHighlight(text: nil) == nil)
        #expect(ReaderPlaybackHighlight(text: "   \n ") == nil)
        #expect(ReaderPlaybackHighlight(text: " 你好 ")?.text == "你好")
    }
}
