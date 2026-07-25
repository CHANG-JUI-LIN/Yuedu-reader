import Foundation
import Testing
@testable import yuedu_app

// Sources routinely repeat the chapter title as the first line of the content, so a reader that
// renders its own title heading shows it twice (番茄酱 emits `<h1 class="chapterTitle1">第1章 …</h1>`
// ahead of the prose). These pin Legado's 去除重复标题 rule — strip exactly one leading copy, never
// eat prose, never empty a chapter.
@Suite("Duplicate chapter title removal")
struct DuplicateChapterTitleTests {

    private let title = "第1章 她成了婆婆级人物"

    // MARK: Plain-text branch

    @Test("strips the repeated title line")
    func stripsTitleLine() {
        let content = "\(title)\n“大山，娘、娘好像没气了….”\n第二段"
        #expect(
            ReaderHTMLUtilities.stripLeadingDuplicateTitle(content, title: title)
                == "“大山，娘、娘好像没气了….”\n第二段"
        )
    }

    @Test("strips a bracket-decorated title without leaving the closing bracket")
    func stripsDecoratedTitle() {
        #expect(
            ReaderHTMLUtilities.stripLeadingDuplicateTitle("《\(title)》\n正文開始", title: title)
                == "正文開始"
        )
    }

    @Test("tolerates leading blank lines and whitespace differences")
    func toleratesWhitespace() {
        #expect(
            ReaderHTMLUtilities.stripLeadingDuplicateTitle("\n\n  \(title)  \n正文", title: title)
                == "正文"
        )
        // The title as spelled in the TOC may use different spacing than the content copy.
        #expect(
            ReaderHTMLUtilities.stripLeadingDuplicateTitle("第1章 天资妖孽\n正文", title: "第1章  天资妖孽")
                == "正文"
        )
    }

    @Test("keeps dialogue that follows the title")
    func keepsFollowingDialogue() {
        #expect(
            ReaderHTMLUtilities.stripLeadingDuplicateTitle("\(title)\n“大山，娘…”\n下一段", title: title)
                == "“大山，娘…”\n下一段"
        )
    }

    @Test("never empties a chapter that is only the title")
    func neverEmptiesChapter() {
        #expect(ReaderHTMLUtilities.stripLeadingDuplicateTitle(title, title: title) == title)
    }

    @Test("leaves unrelated content and empty titles alone")
    func leavesUnrelatedContent() {
        let content = "“大山，娘…”\n第二段"
        #expect(ReaderHTMLUtilities.stripLeadingDuplicateTitle(content, title: title) == content)
        #expect(ReaderHTMLUtilities.stripLeadingDuplicateTitle("正文", title: "   ") == "正文")
    }

    // MARK: HTML branch (element text comparison)

    @Test("recognises the title inside a heading element")
    func recognisesHeadingText() {
        #expect(ReaderHTMLUtilities.isDuplicateChapterTitle(title, title: title))
        #expect(ReaderHTMLUtilities.isDuplicateChapterTitle(" 第1章  她成了婆婆级人物 ", title: title))
        #expect(ReaderHTMLUtilities.isDuplicateChapterTitle("《\(title)》", title: title))
    }

    @Test("a paragraph that merely starts with the title is not a duplicate")
    func paragraphStartingWithTitleIsNotDuplicate() {
        #expect(!ReaderHTMLUtilities.isDuplicateChapterTitle("\(title)，她愣住了。", title: title))
        #expect(!ReaderHTMLUtilities.isDuplicateChapterTitle("“大山，娘…”", title: title))
        #expect(!ReaderHTMLUtilities.isDuplicateChapterTitle(title, title: ""))
    }
}
