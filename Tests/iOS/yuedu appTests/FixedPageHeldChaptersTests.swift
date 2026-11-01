import Foundation
import Testing
@testable import yuedu_app

/// 條漫一條長列表裡同時放著好幾章。容器原本只記一個 chapterIndex：接上下一章時就往前移，
/// 使用者捲回這章開頭時「上一章」算成畫面上這章本身，同一章被插進兩次，
/// 標題和存下的位置也跑到下一章。
@Suite("Fixed page held chapters")
struct FixedPageHeldChaptersTests {

    @Test("appending the next chapter leaves the chapter to prepend alone")
    func appendingKeepsTheTopEnd() {
        var held = FixedPageHeldChapters()
        held.reset(to: 3, pageCount: 5)
        #expect(held.nextToAppend == 4)
        #expect(held.previousToPrepend == 2)

        held.append(4, pageCount: 3)
        #expect(held.nextToAppend == 5)
        // The chapter above the strip is still 2 — not 3, which is already held.
        #expect(held.previousToPrepend == 2)

        held.prepend(2, pageCount: 4)
        #expect(held.previousToPrepend == 1)
        #expect(held.nextToAppend == 5)
        #expect(held.chapters.map(\.index) == [2, 3, 4])
    }

    @Test("a strip page maps to its own chapter and the page within it")
    func stripPagesMapToChapters() {
        var held = FixedPageHeldChapters()
        held.reset(to: 3, pageCount: 5)
        held.append(4, pageCount: 3)
        held.prepend(2, pageCount: 4)

        #expect(held.position(ofHeldPage: 0) == .init(chapter: 2, page: 0, chapterPageCount: 4))
        #expect(held.position(ofHeldPage: 3) == .init(chapter: 2, page: 3, chapterPageCount: 4))
        #expect(held.position(ofHeldPage: 4) == .init(chapter: 3, page: 0, chapterPageCount: 5))
        #expect(held.position(ofHeldPage: 9) == .init(chapter: 4, page: 0, chapterPageCount: 3))
        #expect(held.position(ofHeldPage: 11) == .init(chapter: 4, page: 2, chapterPageCount: 3))
        #expect(held.position(ofHeldPage: 12) == nil)
        #expect(held.position(ofHeldPage: -1) == nil)
    }

    @Test("a page of a held chapter maps back to its place in the strip")
    func chapterPagesMapToTheStrip() {
        var held = FixedPageHeldChapters()
        held.reset(to: 3, pageCount: 5)
        held.append(4, pageCount: 3)
        held.prepend(2, pageCount: 4)

        #expect(held.heldPage(forPage: 1, inChapter: 3) == 5)
        #expect(held.heldPage(forPage: 0, inChapter: 4) == 9)
        #expect(held.heldPage(forPage: 2, inChapter: 2) == 2)
        #expect(held.heldPage(forPage: 0, inChapter: 7) == nil)
    }

    @Test("past three chapters the strip can let go of the one at either end")
    func surplusChapterIsAtTheFarEnd() {
        var held = FixedPageHeldChapters()
        held.reset(to: 3, pageCount: 5)
        held.append(4, pageCount: 3)
        held.prepend(2, pageCount: 4)
        #expect(held.surplusChapter(atStart: true) == nil)
        #expect(held.surplusChapter(atStart: false) == nil)

        held.append(5, pageCount: 6)
        #expect(held.surplusChapter(atStart: true) == .init(index: 2, pageCount: 4))
        #expect(held.surplusChapter(atStart: false) == .init(index: 5, pageCount: 6))

        held.drop(atStart: true)
        #expect(held.chapters.map(\.index) == [3, 4, 5])
        #expect(held.surplusChapter(atStart: true) == nil)
        // Pages count from the first chapter still held.
        #expect(held.position(ofHeldPage: 0) == .init(chapter: 3, page: 0, chapterPageCount: 5))
        #expect(held.previousToPrepend == 2)

        held.prepend(2, pageCount: 4)
        held.drop(atStart: false)
        #expect(held.chapters.map(\.index) == [2, 3, 4])
        #expect(held.nextToAppend == 5)
    }

    @Test("a single held chapter counts its pages as they are")
    func singleChapterIsItself() {
        var held = FixedPageHeldChapters()
        #expect(held.position(ofHeldPage: 0) == nil)
        #expect(held.nextToAppend == nil)

        held.reset(to: 0, pageCount: 3)
        #expect(held.position(ofHeldPage: 2) == .init(chapter: 0, page: 2, chapterPageCount: 3))
        #expect(held.heldPage(forPage: 2, inChapter: 0) == 2)
        // Nothing above the first chapter; the container checks the book's bounds.
        #expect(held.previousToPrepend == -1)
    }
}
