import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// Stage 1 of `Technotes/ViewportScrollArchitecture.md`. These cover the three invariants §9
/// says must hold before estimated heights are allowed anywhere near the screen:
///
/// 1. **Boundary authority** — the outline's ranges tile the chapter exactly, with no gap or
///    overlap, so a descriptor and its chunk can never disagree about what text they hold.
/// 2. **Height monotonicity** — a measured height never falls back to an estimate.
/// 3. **Total consistency** — the store's total equals the sum of its parts, before and after
///    measurement.
@Suite("Chapter outline and fragment geometry", .serialized)
struct ChapterOutlineTests {

    private static let font = UIFont.systemFont(ofSize: 18)

    private static func chapter(paragraphs: [String]) -> NSAttributedString {
        NSAttributedString(
            string: paragraphs.joined(separator: "\n") + "\n",
            attributes: [.font: font, .foregroundColor: UIColor.black]
        )
    }

    private static func makeOutline(
        _ attributed: NSAttributedString,
        chapterIndex: Int = 0,
        contentWidth: CGFloat = 320
    ) -> ChapterOutline {
        ChapterOutline.make(
            attributedString: attributed,
            chapterIndex: chapterIndex,
            font: font,
            contentWidth: contentWidth,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 8
        )
    }

    // MARK: - Invariant 1: boundary authority

    @Test("fragment ranges tile the chapter with no gap and no overlap")
    func fragmentRangesTileTheChapter() throws {
        let attributed = Self.chapter(paragraphs: [
            "第一段，中文內容。",
            "Second paragraph in Latin script that runs a little longer.",
            "第三段。",
        ])
        let outline = Self.makeOutline(attributed)

        try #require(outline.fragments.count == 3)
        var expectedStart = 0
        for fragment in outline.fragments {
            #expect(fragment.charRange.location == expectedStart)
            #expect(fragment.charRange.length > 0)
            expectedStart = fragment.charRange.location + fragment.charRange.length
        }
        // Tiling must be exhaustive: the last fragment ends at the chapter's end.
        #expect(expectedStart == attributed.length)
    }

    @Test("a chapter without a trailing newline still tiles to the end")
    func chapterWithoutTrailingNewlineTiles() throws {
        let attributed = NSAttributedString(
            string: "只有一段，沒有換行",
            attributes: [.font: Self.font]
        )
        let outline = Self.makeOutline(attributed)

        try #require(outline.fragments.count == 1)
        #expect(outline.fragments[0].charRange.location == 0)
        #expect(outline.fragments[0].charRange.length == attributed.length)
    }

    @Test("consecutive newlines each become their own fragment")
    func blankParagraphsBecomeFragments() throws {
        // A blank line is a real visible gap; collapsing it here would make the outline's total
        // fall short of what CoreText actually draws.
        let attributed = NSAttributedString(string: "甲\n\n乙\n", attributes: [.font: Self.font])
        let outline = Self.makeOutline(attributed)

        #expect(outline.fragments.count == 3)
        #expect(outline.fragments.allSatisfy { $0.height > 0 })
    }

    @Test("an empty chapter produces no fragments and no height")
    func emptyChapterIsEmpty() {
        let outline = Self.makeOutline(NSAttributedString(string: ""))
        #expect(outline.fragments.isEmpty)
        #expect(outline.totalEstimatedHeight == 0)
        #expect(outline.hasEstimates == false)
    }

    @Test("fragment lookup by character offset finds the containing fragment")
    func fragmentLookupByCharacterOffset() throws {
        let attributed = Self.chapter(paragraphs: ["甲甲甲", "乙乙乙乙乙", "丙"])
        let outline = Self.makeOutline(attributed)
        try #require(outline.fragments.count == 3)

        for (index, fragment) in outline.fragments.enumerated() {
            let first = fragment.charRange.location
            let last = fragment.charRange.location + fragment.charRange.length - 1
            #expect(outline.fragmentIndex(containing: first) == index)
            #expect(outline.fragmentIndex(containing: last) == index)
        }
        #expect(outline.fragmentIndex(containing: -1) == nil)
        #expect(outline.fragmentIndex(containing: attributed.length) == nil)
    }

    // MARK: - Invariant 2: height monotonicity

    @Test("a measured height never falls back to the estimate")
    func measuredHeightNeverRegresses() throws {
        var descriptor = FragmentDescriptor(charRange: CFRange(location: 0, length: 10), estimatedHeight: 40)
        try #require(descriptor.isEstimate)
        #expect(descriptor.state == .estimated)
        #expect(descriptor.height == 40)

        descriptor.recordActualHeight(97, laidOut: true)
        #expect(descriptor.state == .laidOut)
        #expect(descriptor.isEstimate == false)
        #expect(descriptor.height == 97)

        // Evicting the CTFrame keeps the height and only steps the state back to `.measured`.
        descriptor.demoteToMeasured()
        #expect(descriptor.state == .measured)
        #expect(descriptor.height == 97)
        #expect(descriptor.isEstimate == false)
    }

    @Test("demoting a fragment that was never laid out does nothing")
    func demotingAnEstimatedFragmentIsANoOp() {
        var descriptor = FragmentDescriptor(charRange: CFRange(location: 0, length: 4), estimatedHeight: 20)
        descriptor.demoteToMeasured()
        #expect(descriptor.state == .estimated)
        #expect(descriptor.height == 20)
    }

    // MARK: - Estimation model

    @Test("estimated height scales with character count, not with wall clock")
    func estimatedHeightScalesWithCharacterCount() {
        let model = EstimatedHeightModel(
            contentWidth: 320,
            averageGlyphAdvance: 16,
            lineHeight: 27,
            paragraphSpacing: 8
        )
        #expect(model.charactersPerLine == 20)

        // Typed constants, not inline `27 + 8`: an all-literal arithmetic expression inside
        // `#expect` has no typed operand to infer CGFloat from, so the macro evaluates it as
        // `Int` and the comparison fails against an equal CGFloat.
        let oneLine: CGFloat = 27 + 8
        let twoLines: CGFloat = 54 + 8

        // 20 characters is exactly one line; 21 spills onto a second.
        #expect(model.estimatedHeight(characterCount: 20) == oneLine)
        #expect(model.estimatedHeight(characterCount: 21) == twoLines)
        // An empty paragraph still occupies a line — it is a visible gap.
        #expect(model.estimatedHeight(characterCount: 0) == oneLine)
    }

    @Test("a narrow column still yields at least one character per line")
    func narrowColumnDoesNotDivideByZero() {
        let model = EstimatedHeightModel(
            contentWidth: 4,
            averageGlyphAdvance: 40,
            lineHeight: 20,
            paragraphSpacing: 0
        )
        #expect(model.charactersPerLine == 1)
        #expect(model.estimatedHeight(characterCount: 3) == 60)
    }

    @Test("CJK text estimates a narrower column than Latin at the same point size")
    func cjkAdvancesWiderThanLatin() {
        let cjk = EstimatedHeightModel.make(
            font: Self.font,
            cjkFraction: 1,
            contentWidth: 320,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 0
        )
        let latin = EstimatedHeightModel.make(
            font: Self.font,
            cjkFraction: 0,
            contentWidth: 320,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 0
        )
        // Full-width glyphs are wider, so fewer fit per line and the same text runs taller.
        #expect(cjk.charactersPerLine < latin.charactersPerLine)
        #expect(cjk.estimatedHeight(characterCount: 200) > latin.estimatedHeight(characterCount: 200))
    }

    @Test("CJK fraction separates Han text from Latin text")
    func cjkFractionDetectsScript() {
        #expect(ChapterOutline.cjkFraction(in: "全部都是中文字元內容" as NSString) == 1.0)
        #expect(ChapterOutline.cjkFraction(in: "all latin characters here" as NSString) == 0.0)
        #expect(ChapterOutline.cjkFraction(in: "" as NSString) == 0.0)
    }

    // MARK: - Invariant 3: store totals

    @Test("store total equals the sum of its fragments, before and after measurement")
    @MainActor
    func storeTotalMatchesSumOfFragments() throws {
        let attributed = Self.chapter(paragraphs: ["甲甲甲甲", "乙乙乙乙乙乙", "丙丙"])
        let outline = Self.makeOutline(attributed, chapterIndex: 3)
        let store = FragmentGeometryStore()
        store.setOutline(outline)

        try #require(store.fragmentCount(inChapter: 3) == 3)
        let estimatedTotal = (0..<3).compactMap { store.height(chapter: 3, fragment: $0) }.reduce(0, +)
        #expect(store.totalHeight == estimatedTotal)
        #expect(store.hasEstimatedHeights)

        // Real layout reports a different height than the estimate for the middle fragment.
        let before = try #require(store.height(chapter: 3, fragment: 1))
        let delta = store.recordActualHeight(before + 42, chapter: 3, fragment: 1)
        #expect(delta == 42)

        let measuredTotal = (0..<3).compactMap { store.height(chapter: 3, fragment: $0) }.reduce(0, +)
        #expect(store.totalHeight == measuredTotal)
        #expect(store.totalHeight == estimatedTotal + 42)
        // Two fragments are still estimates, so the total is still provisional.
        #expect(store.hasEstimatedHeights)
    }

    @Test("fragment offsets account for chapters ahead of it in scroll order")
    @MainActor
    func fragmentOffsetsAccumulateAcrossChapters() throws {
        let store = FragmentGeometryStore()
        let first = Self.makeOutline(Self.chapter(paragraphs: ["甲", "乙"]), chapterIndex: 5)
        let second = Self.makeOutline(Self.chapter(paragraphs: ["丙", "丁"]), chapterIndex: 6)
        store.setOutline(first)
        store.setOutline(second)

        #expect(store.chapterOrder == [5, 6])
        #expect(store.offsetOfFragment(chapter: 5, fragment: 0) == 0)

        let firstChapterHeight = store.totalHeight(chapter: 5)
        #expect(store.offsetOfFragment(chapter: 6, fragment: 0) == firstChapterHeight)

        let secondFragmentHeight = try #require(store.height(chapter: 6, fragment: 0))
        #expect(
            store.offsetOfFragment(chapter: 6, fragment: 1)
                == firstChapterHeight + secondFragmentHeight
        )
    }

    @Test("a prepended chapter lands ahead of everything already loaded")
    @MainActor
    func prependedChapterComesFirst() {
        let store = FragmentGeometryStore()
        store.setOutline(Self.makeOutline(Self.chapter(paragraphs: ["乙"]), chapterIndex: 6))
        store.setOutline(Self.makeOutline(Self.chapter(paragraphs: ["甲"]), chapterIndex: 5), prepend: true)

        #expect(store.chapterOrder == [5, 6])
        #expect(store.offsetOfFragment(chapter: 5, fragment: 0) == 0)
        #expect(store.offsetOfFragment(chapter: 6, fragment: 0) == store.totalHeight(chapter: 5))
    }

    @Test("removing a chapter drops both its geometry and its place in the order")
    @MainActor
    func removingChapterDropsItsGeometry() {
        let store = FragmentGeometryStore()
        store.setOutline(Self.makeOutline(Self.chapter(paragraphs: ["甲"]), chapterIndex: 1))
        store.setOutline(Self.makeOutline(Self.chapter(paragraphs: ["乙"]), chapterIndex: 2))
        let totalBefore = store.totalHeight

        store.removeChapter(1)
        #expect(store.chapterOrder == [2])
        #expect(store.outline(for: 1) == nil)
        #expect(store.height(chapter: 1, fragment: 0) == nil)
        #expect(store.totalHeight < totalBefore)
        #expect(store.totalHeight == store.totalHeight(chapter: 2))
    }

    // MARK: - Stage 1: the store must report exactly what the chunks measured

    /// Real sliced chunks, so the comparison is against CoreText's own numbers rather than a
    /// hand-built stand-in.
    private static func slicedChunks(paragraphs: Int, heightCap: CGFloat = 200) -> [CoreTextChunk] {
        let attributed = NSMutableAttributedString()
        for index in 0..<paragraphs {
            attributed.append(NSAttributedString(
                string: "第 \(index) 段，內容夠長足以換行，讓切片器產生多個 chunk。\n",
                attributes: [.font: font, .foregroundColor: UIColor.black]
            ))
        }
        return CoreTextChunkSlicer.slice(
            attributedString: attributed,
            chapterIndex: 0,
            contentWidth: 220,
            heightCap: heightCap
        ).chunks
    }

    @Test("an outline built from laid-out chunks reports their heights and ranges unchanged")
    func measuredOutlineMatchesChunksExactly() throws {
        let chunks = Self.slicedChunks(paragraphs: 40)
        try #require(chunks.count > 1)

        let outline = ChapterOutline.measured(chapterIndex: 0, chunks: chunks[...]) { $0.height }
        try #require(outline.fragments.count == chunks.count)

        for (fragment, chunk) in zip(outline.fragments, chunks) {
            #expect(fragment.charRange.location == chunk.charRange.location)
            #expect(fragment.charRange.length == chunk.charRange.length)
            #expect(fragment.height == chunk.height)
            // Nothing may be an estimate at stage 1 — an estimated height reaching the screen
            // before the anchor compensator exists is exactly the scroll-jump risk of §8.1.
            #expect(fragment.isEstimate == false)
            #expect(fragment.state == .laidOut)
        }
        #expect(outline.hasEstimates == false)
        #expect(outline.totalEstimatedHeight == chunks.reduce(0) { $0 + $1.height })
    }

    @Test("flat index walks chapters in scroll order and stops at the end")
    @MainActor
    func flatIndexWalksChaptersInScrollOrder() throws {
        let first = Self.slicedChunks(paragraphs: 30)
        let second = Self.slicedChunks(paragraphs: 20)
        try #require(first.count > 1 && second.count > 1)

        let store = FragmentGeometryStore()
        store.setOutline(ChapterOutline.measured(chapterIndex: 7, chunks: first[...]) { $0.height })
        store.setOutline(ChapterOutline.measured(chapterIndex: 8, chunks: second[...]) { $0.height })

        #expect(store.flatFragmentCount == first.count + second.count)

        // The flat list is the two chapters concatenated, which is what the collection view maps
        // one-to-one onto cells.
        let expected = (first + second).map(\.height)
        for (index, height) in expected.enumerated() {
            #expect(store.height(atFlatIndex: index) == height)
        }
        #expect(store.height(atFlatIndex: expected.count) == nil)
        #expect(store.height(atFlatIndex: -1) == nil)
    }

    /// The defect this pins down shipped and was reported from a device as "開書回來反覆跳很久才
    /// 穩定到原本的位置". The store used to be grouped from `chapterRanges`, a second
    /// `@Published` property assigned just after `chunks`; a rebuild triggered between the two
    /// assignments saw ranges that did not cover every chunk, and the uncovered chunks fell off
    /// the flat index and reported zero extent.
    ///
    /// Grouping from `chunks` alone makes the mapping total by construction — which is what these
    /// assert, since "every chunk is covered" is the property that was violated.
    @Test("grouping covers every chunk, so the flat index can never run short")
    @MainActor
    func groupingCoversEveryChunk() throws {
        let first = Self.slicedChunks(paragraphs: 24)
        let second = Self.slicedChunks(paragraphs: 16)
        try #require(first.count > 1 && second.count > 1)

        // Two chapters' chunks concatenated, as the engine holds them.
        let chunks = first + second.map { chunk in
            CoreTextChunk(
                chapterIndex: 1,
                charRange: chunk.charRange,
                size: CGSize(width: chunk.width, height: chunk.height),
                framesetter: chunk.framesetter,
                attributedString: chunk.attributedString,
                frame: nil,
                writingMode: .horizontal
            )
        }

        let outlines = ChapterOutline.grouped(chunks: chunks) { $0.height }
        #expect(outlines.map(\.chapterIndex) == [0, 1])
        #expect(outlines.reduce(0) { $0 + $1.fragments.count } == chunks.count)

        let store = FragmentGeometryStore()
        outlines.forEach { store.setOutline($0) }

        // The invariant: one flat slot per chunk, each reporting that chunk's own extent, and
        // nothing past the end.
        #expect(store.flatFragmentCount == chunks.count)
        for (index, chunk) in chunks.enumerated() {
            #expect(store.height(atFlatIndex: index) == chunk.height)
        }
        #expect(store.height(atFlatIndex: chunks.count) == nil)
    }

    @Test("grouping an empty chunk list yields no outlines")
    func groupingEmptyChunksYieldsNothing() {
        #expect(ChapterOutline.grouped(chunks: []) { $0.height }.isEmpty)
    }

    @Test("vertical writing measures chunks along the horizontal axis")
    func verticalOutlineUsesWidthAsExtent() throws {
        let attributed = NSAttributedString(
            string: (0..<40).map { "直排第 \($0) 段內容。" }.joined(separator: "\n"),
            attributes: [.font: Self.font, .foregroundColor: UIColor.black]
        )
        let chunks = CoreTextChunkSlicer.slice(
            attributedString: attributed,
            chapterIndex: 0,
            contentWidth: 320,
            heightCap: 240,
            writingMode: .verticalRTL
        ).chunks
        try #require(chunks.count > 1)

        // Vertical RTL scrolls sideways, so the store's "height" is the chunk's width.
        let outline = ChapterOutline.measured(chapterIndex: 0, chunks: chunks[...]) { $0.width }
        for (fragment, chunk) in zip(outline.fragments, chunks) {
            #expect(fragment.height == chunk.width)
        }
    }

    @Test("recording a height for a fragment that does not exist changes nothing")
    @MainActor
    func recordingOutOfRangeHeightIsIgnored() {
        let store = FragmentGeometryStore()
        store.setOutline(Self.makeOutline(Self.chapter(paragraphs: ["甲"]), chapterIndex: 0))
        let before = store.totalHeight

        #expect(store.recordActualHeight(999, chapter: 0, fragment: 99) == 0)
        #expect(store.recordActualHeight(999, chapter: 42, fragment: 0) == 0)
        #expect(store.totalHeight == before)
    }
}
