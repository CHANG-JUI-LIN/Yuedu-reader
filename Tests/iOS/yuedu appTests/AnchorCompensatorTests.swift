import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// Invariant 3 of `Technotes/ViewportScrollArchitecture.md` §9 — **anchor conservation**:
///
/// > 任何高度變更後，錨點 charOffset 的螢幕 y 不變（誤差 < 1pt）
///
/// The technote calls this "防跳動的唯一機器驗證". It has to hold before an estimated height is
/// ever allowed on screen, because every fragment re-measured *above* the viewport shifts
/// everything below it, and that shift is what the reader perceives as a jump.
@Suite("Anchor compensation", .serialized)
@MainActor
struct AnchorCompensatorTests {

    private static let font = UIFont.systemFont(ofSize: 18)

    /// Fragments with deliberately uneven, non-round heights, so an arithmetic slip cannot be
    /// masked by everything being a multiple of the same number.
    private static func outline(
        chapterIndex: Int,
        heights: [CGFloat],
        charsPerFragment: Int = 50
    ) -> ChapterOutline {
        var fragments: [FragmentDescriptor] = []
        var location = 0
        for height in heights {
            fragments.append(
                FragmentDescriptor(
                    charRange: CFRange(location: location, length: charsPerFragment),
                    estimatedHeight: height
                )
            )
            location += charsPerFragment
        }
        return ChapterOutline(chapterIndex: chapterIndex, fragments: fragments, cjkFraction: 1)
    }

    private static func store(_ outlines: [ChapterOutline]) -> FragmentGeometryStore {
        let store = FragmentGeometryStore()
        outlines.forEach { store.setOutline($0) }
        return store
    }

    // MARK: - The invariant

    @Test("re-measuring fragments above the viewport keeps the anchored text still")
    func remeasuringAboveViewportKeepsAnchorStill() throws {
        let store = Self.store([
            Self.outline(chapterIndex: 1, heights: [211.5, 97, 340.25, 180, 402.75])
        ])

        // Reader is looking partway into the fourth fragment.
        let originalOffset: CGFloat = 211.5 + 97 + 340.25 + 63
        let anchor = try #require(
            AnchorCompensator.anchor(atScrollOffset: originalOffset, in: store)
        )
        #expect(anchor.chapterIndex == 1)
        #expect(anchor.charOffset == 150)
        #expect(anchor.distanceIntoFragment == 63)

        // Real layout comes back with different heights for two fragments above the viewport —
        // one taller, one shorter, so the net is not a happy coincidence.
        let grew: CGFloat = 44.75
        let shrank: CGFloat = 12.5
        store.recordActualHeight(211.5 + grew, chapter: 1, fragment: 0)
        store.recordActualHeight(97 - shrank, chapter: 1, fragment: 1)

        let compensation = try #require(
            AnchorCompensator.compensation(for: anchor, from: originalOffset, in: store)
        )
        // Typed operands, not a bare `44.75 - 12.5`: an all-literal arithmetic expression inside
        // `#expect` has nothing to infer CGFloat from, so the macro evaluates it as `Double` and
        // the comparison fails against a numerically equal CGFloat.
        #expect(compensation == grew - shrank)

        // Applying it puts the anchored character back at the same screen position.
        let corrected = originalOffset + compensation
        let reanchored = try #require(
            AnchorCompensator.anchor(atScrollOffset: corrected, in: store)
        )
        #expect(reanchored == anchor)
    }

    @Test("re-measuring fragments below the viewport moves nothing")
    func remeasuringBelowViewportNeedsNoCompensation() throws {
        let store = Self.store([Self.outline(chapterIndex: 0, heights: [100, 200, 300, 400])])
        let originalOffset: CGFloat = 150
        let anchor = try #require(
            AnchorCompensator.anchor(atScrollOffset: originalOffset, in: store)
        )

        // Everything after the anchored fragment grows; none of it is on screen above the reader.
        store.recordActualHeight(999, chapter: 0, fragment: 2)
        store.recordActualHeight(1, chapter: 0, fragment: 3)

        #expect(AnchorCompensator.compensation(for: anchor, from: originalOffset, in: store) == 0)
    }

    @Test("a chapter prepended above the reader is fully compensated")
    func prependedChapterIsCompensated() throws {
        let store = Self.store([Self.outline(chapterIndex: 5, heights: [120, 240, 360])])
        let originalOffset: CGFloat = 120 + 90
        let anchor = try #require(
            AnchorCompensator.anchor(atScrollOffset: originalOffset, in: store)
        )
        #expect(anchor.chapterIndex == 5)

        // Scrolling backwards loads the previous chapter in front of everything.
        let earlier = Self.outline(chapterIndex: 4, heights: [500, 250.5])
        store.setOutline(earlier, prepend: true)

        let compensation = try #require(
            AnchorCompensator.compensation(for: anchor, from: originalOffset, in: store)
        )
        // The anchor has to move down by exactly the height of what was inserted above it.
        #expect(compensation == 750.5)

        let reanchored = try #require(
            AnchorCompensator.anchor(atScrollOffset: originalOffset + compensation, in: store)
        )
        #expect(reanchored == anchor)
    }

    @Test("the anchor survives every fragment in a chapter being re-measured at once")
    func anchorSurvivesWholeChapterRemeasurement() throws {
        let estimates: [CGFloat] = [180, 180, 180, 180, 180, 180, 180, 180]
        let actuals: [CGFloat] = [143.25, 266.5, 91, 302.75, 154, 198.5, 87.25, 240]
        let store = Self.store([Self.outline(chapterIndex: 2, heights: estimates)])

        let originalOffset: CGFloat = 180 * 5 + 40
        let anchor = try #require(
            AnchorCompensator.anchor(atScrollOffset: originalOffset, in: store)
        )
        #expect(anchor.charOffset == 250)

        for (index, height) in actuals.enumerated() {
            store.recordActualHeight(height, chapter: 2, fragment: index)
        }

        let corrected = try #require(AnchorCompensator.scrollOffset(for: anchor, in: store))
        // The anchored fragment now starts at the sum of the actual heights before it, and the
        // reader is still 40pt into it.
        #expect(corrected == actuals[0..<5].reduce(0, +) + 40)

        let reanchored = try #require(
            AnchorCompensator.anchor(atScrollOffset: corrected, in: store)
        )
        #expect(reanchored == anchor)
    }

    // MARK: - Boundaries and absent content

    @Test("an offset exactly on a fragment boundary anchors to the fragment starting there")
    func boundaryOffsetAnchorsToFollowingFragment() throws {
        let store = Self.store([Self.outline(chapterIndex: 0, heights: [100, 200, 300])])
        let anchor = try #require(AnchorCompensator.anchor(atScrollOffset: 100, in: store))
        #expect(anchor.charOffset == 50)
        #expect(anchor.distanceIntoFragment == 0)
    }

    @Test("the top of the content anchors to the first fragment")
    func topOfContentAnchorsToFirstFragment() throws {
        let store = Self.store([Self.outline(chapterIndex: 9, heights: [100, 200])])
        let anchor = try #require(AnchorCompensator.anchor(atScrollOffset: 0, in: store))
        #expect(anchor.chapterIndex == 9)
        #expect(anchor.charOffset == 0)
        #expect(anchor.distanceIntoFragment == 0)
    }

    @Test("an anchor whose chapter was evicted yields nil rather than a stale offset")
    func evictedChapterYieldsNil() throws {
        let store = Self.store([
            Self.outline(chapterIndex: 3, heights: [100, 200]),
            Self.outline(chapterIndex: 4, heights: [300]),
        ])
        let anchor = try #require(AnchorCompensator.anchor(atScrollOffset: 150, in: store))
        #expect(anchor.chapterIndex == 3)

        store.removeChapter(3)

        // Nothing to restore. Returning a number here would scroll the reader somewhere arbitrary,
        // which is worse than declining to adjust.
        #expect(AnchorCompensator.scrollOffset(for: anchor, in: store) == nil)
        #expect(AnchorCompensator.compensation(for: anchor, from: 150, in: store) == nil)
    }

    @Test("an empty store has nothing to anchor to")
    func emptyStoreHasNoAnchor() {
        let store = FragmentGeometryStore()
        #expect(AnchorCompensator.anchor(atScrollOffset: 0, in: store) == nil)
        #expect(AnchorCompensator.anchor(atScrollOffset: 500, in: store) == nil)
    }

    @Test("anchoring spans chapters in scroll order")
    func anchoringSpansChapters() throws {
        let store = Self.store([
            Self.outline(chapterIndex: 7, heights: [100, 150]),
            Self.outline(chapterIndex: 8, heights: [200, 250]),
        ])

        // 20pt into the second chapter's second fragment.
        let offset: CGFloat = 100 + 150 + 200 + 20
        let anchor = try #require(AnchorCompensator.anchor(atScrollOffset: offset, in: store))
        #expect(anchor.chapterIndex == 8)
        #expect(anchor.charOffset == 50)
        #expect(anchor.distanceIntoFragment == 20)
        #expect(AnchorCompensator.scrollOffset(for: anchor, in: store) == offset)
    }

    @Test("measured heights never regress, so compensation is never undone")
    func measuredHeightsNeverRegress() throws {
        let store = Self.store([Self.outline(chapterIndex: 0, heights: [200, 200, 200])])
        let anchor = try #require(AnchorCompensator.anchor(atScrollOffset: 450, in: store))

        store.recordActualHeight(320, chapter: 0, fragment: 0)
        let afterFirst = try #require(AnchorCompensator.scrollOffset(for: anchor, in: store))

        // Evicting the CTFrame keeps the measured height (§9 invariant 2). If it fell back to the
        // estimate, the reader would be shoved back up by 120pt on scrolling away and returning.
        let descriptor = try #require(store.descriptor(chapter: 0, fragment: 0))
        #expect(descriptor.height == 320)
        #expect(descriptor.isEstimate == false)
        #expect(AnchorCompensator.scrollOffset(for: anchor, in: store) == afterFirst)
    }
}
