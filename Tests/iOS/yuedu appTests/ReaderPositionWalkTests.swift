import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// Guards the identity space the `UIPageViewController` data source walks.
///
/// The reported bug — a slide swipe at a chapter end landing on the *second* page
/// of the next chapter — came from stepping in global page indices, which are
/// re-derived every time any chapter's layout lands. These assertions pin the
/// replacement: stepping is defined purely by `(spineIndex, charOffset)` and the
/// chapter count, so repagination cannot move a step's destination.
@Suite("Reader position walk")
struct ReaderPositionWalkTests {

    private func layout(
        spine: Int,
        text: String,
        pageStarts: [Int],
        coveredEnd: Int? = nil,
        isPartial: Bool = false,
        estimatedPageCount: Int? = nil
    ) -> CoreTextPaginator.ChapterLayout {
        let attributedString = NSAttributedString(string: text)
        // A partial layout stops short of the chapter's end; `coveredEnd` says where.
        let lastEnd = coveredEnd ?? attributedString.length
        let ranges = pageStarts.enumerated().map { index, start -> CFRange in
            let end = index + 1 < pageStarts.count ? pageStarts[index + 1] : lastEnd
            return CFRangeMake(start, max(0, end - start))
        }
        var result = CoreTextPaginator.ChapterLayout(
            spineIndex: spine,
            attributedString: attributedString,
            framesetter: CTFramesetterCreateWithAttributedString(attributedString),
            pageRanges: ranges,
            inlineAttachments: [:],
            inlineAnnotations: [:],
            blockAttachments: [:],
            blockRenderables: [:],
            pageKinds: Array(repeating: .text, count: max(ranges.count, 1)),
            pageBackgroundImage: nil,
            authoredBackgroundColor: nil,
            anchorOffsets: [:],
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            backgroundColor: .systemBackground,
            contentInsets: .zero
        )
        result.isPartial = isPartial
        result.estimatedPageCount = estimatedPageCount
        return result
    }

    /// Two chapters of three pages each, every page 10 characters.
    private var twoChapters: [Int: CoreTextPaginator.ChapterLayout] {
        [
            0: layout(spine: 0, text: String(repeating: "a", count: 30), pageStarts: [0, 10, 20]),
            1: layout(spine: 1, text: String(repeating: "b", count: 30), pageStarts: [0, 10, 20]),
        ]
    }

    private func after(_ position: CoreTextReadingPosition, chapters: Int = 2) -> CoreTextReadingPosition? {
        CoreTextReadingPositionMapper.positionAfter(position, layouts: twoChapters, chapterCount: chapters)
    }

    private func before(_ position: CoreTextReadingPosition, chapters: Int = 2) -> CoreTextReadingPosition? {
        CoreTextReadingPositionMapper.positionBefore(position, layouts: twoChapters, chapterCount: chapters)
    }

    // MARK: - Within a chapter

    @Test func steppingForwardInsideAChapterLandsOnTheNextPageStart() {
        #expect(after(CoreTextReadingPosition(spineIndex: 0, charOffset: 0))
            == CoreTextReadingPosition(spineIndex: 0, charOffset: 10))
    }

    @Test func steppingForwardFromMidPageStillLandsOnTheNextPageStart() {
        #expect(after(CoreTextReadingPosition(spineIndex: 0, charOffset: 4))
            == CoreTextReadingPosition(spineIndex: 0, charOffset: 10))
    }

    @Test func steppingBackwardInsideAChapterLandsOnThePreviousPageStart() {
        #expect(before(CoreTextReadingPosition(spineIndex: 0, charOffset: 20))
            == CoreTextReadingPosition(spineIndex: 0, charOffset: 10))
    }

    // MARK: - Chapter boundaries (the reported bug)

    /// The exact repro: the last page of a chapter must step to the *first* page of
    /// the next one, never past it.
    @Test func lastPageOfAChapterStepsToTheNextChaptersFirstPage() {
        #expect(after(CoreTextReadingPosition(spineIndex: 0, charOffset: 20))
            == .chapterStart(1))
    }

    @Test func chapterEndSentinelStepsToTheNextChaptersFirstPage() {
        #expect(after(.chapterEnd(0)) == .chapterStart(1))
    }

    @Test func firstPageOfAChapterStepsBackToThePreviousChaptersEnd() {
        #expect(before(.chapterStart(1)) == .chapterEnd(0))
    }

    // MARK: - Book boundaries

    @Test func lastPageOfTheLastChapterHasNoNextPage() {
        #expect(after(CoreTextReadingPosition(spineIndex: 1, charOffset: 20)) == nil)
    }

    @Test func firstPageOfTheBookHasNoPreviousPage() {
        #expect(before(.chapterStart(0)) == nil)
    }

    // MARK: - Unmeasured content

    /// The step is defined only where a layout exists. Guessing would walk to a page
    /// the reader never asked for.
    @Test func aChapterWithNoLayoutCannotBeSteppedFrom() {
        #expect(after(CoreTextReadingPosition(spineIndex: 5, charOffset: 0), chapters: 8) == nil)
        #expect(before(CoreTextReadingPosition(spineIndex: 5, charOffset: 0), chapters: 8) == nil)
    }

    /// A partially paginated chapter continues past what has been measured, so the
    /// step stays inside it and anchors on the first unmeasured character — not on
    /// the next chapter, and not on a page index that the full pass will renumber.
    @Test func partialLayoutStepsToTheFirstUnmeasuredCharacterNotTheNextChapter() {
        // 100 characters, only the leading 10 measured so far.
        let layouts: [Int: CoreTextPaginator.ChapterLayout] = [
            0: layout(
                spine: 0,
                text: String(repeating: "a", count: 100),
                pageStarts: [0],
                coveredEnd: 10,
                isPartial: true,
                estimatedPageCount: 10
            ),
            1: layout(spine: 1, text: "next", pageStarts: [0]),
        ]
        let stepped = CoreTextReadingPositionMapper.positionAfter(
            .chapterStart(0),
            layouts: layouts,
            chapterCount: 2
        )
        #expect(stepped == CoreTextReadingPosition(spineIndex: 0, charOffset: 10))
    }

    /// A partial layout that happens to cover the whole chapter still crosses the
    /// boundary normally.
    @Test func partialLayoutCoveringEverythingStillCrossesTheBoundary() {
        let layouts: [Int: CoreTextPaginator.ChapterLayout] = [
            0: layout(spine: 0, text: "abc", pageStarts: [0], coveredEnd: 3, isPartial: true, estimatedPageCount: 1),
            1: layout(spine: 1, text: "next", pageStarts: [0]),
        ]
        let stepped = CoreTextReadingPositionMapper.positionAfter(
            .chapterStart(0),
            layouts: layouts,
            chapterCount: 2
        )
        #expect(stepped == .chapterStart(1))
    }

    // MARK: - The invariant the bug violated

    /// Chapter 0 growing from 3 pages to 5 renumbers every global page after it. The
    /// step's destination must not move: that renumbering is exactly what used to
    /// push a chapter-boundary turn one page too far.
    @Test func repaginatingAnEarlierChapterDoesNotMoveAStepsDestination() {
        let before3 = twoChapters
        var after5 = twoChapters
        after5[0] = layout(
            spine: 0,
            text: String(repeating: "a", count: 30),
            pageStarts: [0, 6, 12, 18, 24]
        )

        let source = CoreTextReadingPosition(spineIndex: 1, charOffset: 0)
        let steppedBefore = CoreTextReadingPositionMapper.positionAfter(
            source, layouts: before3, chapterCount: 2
        )
        let steppedAfter = CoreTextReadingPositionMapper.positionAfter(
            source, layouts: after5, chapterCount: 2
        )

        #expect(steppedBefore == CoreTextReadingPosition(spineIndex: 1, charOffset: 10))
        #expect(steppedBefore == steppedAfter)

        // The global page index for the same content did move — which is precisely
        // why the data source must not be indexed by it.
        let pageBefore = CoreTextReadingPositionMapper.pageIndex(
            for: source, layouts: before3, spinePageOffsets: [0, 3]
        )
        let pageAfter = CoreTextReadingPositionMapper.pageIndex(
            for: source, layouts: after5, spinePageOffsets: [0, 5]
        )
        #expect(pageBefore == 3)
        #expect(pageAfter == 5)
    }
}
