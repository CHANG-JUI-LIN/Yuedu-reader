import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// Restoring a reading position used to be chunk-granular: `scrollToItem(at: .top)` can only reach
/// a chunk's leading edge, so however far into the chunk the reader was got discarded — 84, 259
/// and 530 characters in three device captures. That loss is not cosmetic: the landed position is
/// what gets saved on exit, so each visit to scroll mode walks the saved progress backwards.
///
/// `CoreTextChunk.topOffset(forCharacterIndex:)` is what makes the restore character-accurate.
@Suite("Chunk character offset", .serialized)
struct ChunkCharacterOffsetTests {

    private static let font = UIFont.systemFont(ofSize: 18)

    private static func slicedChunks(paragraphs: Int) -> [CoreTextChunk] {
        let attributed = NSMutableAttributedString()
        for index in 0..<paragraphs {
            attributed.append(NSAttributedString(
                string: "第 \(index) 段，內容夠長，足以在窄欄裡換成好幾行，讓行的頂端有明顯的高度差。\n",
                attributes: [.font: font, .foregroundColor: UIColor.black]
            ))
        }
        return CoreTextChunkSlicer.slice(
            attributedString: attributed,
            chapterIndex: 0,
            contentWidth: 220,
            heightCap: 2000
        ).chunks
    }

    @Test("offset grows monotonically as the character index advances through the chunk")
    func offsetGrowsWithCharacterIndex() throws {
        let chunks = Self.slicedChunks(paragraphs: 40)
        let chunk = try #require(chunks.first)
        try #require(chunk.charRange.length > 200)

        let start = chunk.charRange.location
        let end = start + chunk.charRange.length
        var previous: CGFloat = -1
        var sawGrowth = false

        for index in stride(from: start + 1, to: end, by: 25) {
            let offset = try #require(
                chunk.topOffset(forCharacterIndex: index),
                "no offset for index \(index) in \(chunk.charRange)"
            )
            #expect(offset >= 0)
            #expect(offset < chunk.height)
            #expect(offset >= previous, "offset went backwards at index \(index)")
            if offset > previous { sawGrowth = true }
            previous = offset
        }
        // A chunk spanning many lines must resolve to more than one height, or the restore is
        // still effectively chunk-granular.
        #expect(sawGrowth)
    }

    @Test("a character far into the chunk resolves well below its top edge")
    func lateCharacterResolvesBelowTop() throws {
        let chunks = Self.slicedChunks(paragraphs: 40)
        let chunk = try #require(chunks.first)
        let start = chunk.charRange.location
        let late = start + chunk.charRange.length - 10

        let offset = try #require(chunk.topOffset(forCharacterIndex: late))
        // The exact number depends on font metrics, so the assertion is the property that matters:
        // the reader lands nowhere near the chunk's top. Landing at 0 is the bug this replaces.
        #expect(offset > chunk.height / 2)
    }

    @Test("indexes outside the chunk have no offset")
    func outOfRangeIndexesReturnNil() throws {
        let chunks = Self.slicedChunks(paragraphs: 40)
        let chunk = try #require(chunks.first)
        let start = chunk.charRange.location
        let end = start + chunk.charRange.length

        // The chunk's own start is deliberately nil: its answer is the chunk edge, which the
        // caller already has, and returning 0 would hide a genuine "not in this chunk" result.
        #expect(chunk.topOffset(forCharacterIndex: start) == nil)
        #expect(chunk.topOffset(forCharacterIndex: end) == nil)
        #expect(chunk.topOffset(forCharacterIndex: end + 500) == nil)
        #expect(chunk.topOffset(forCharacterIndex: -1) == nil)
    }

    @Test("a later chunk resolves against its own range, not the chapter start")
    func laterChunkUsesItsOwnRange() throws {
        let chunks = Self.slicedChunks(paragraphs: 40)
        try #require(chunks.count > 1)
        let chunk = chunks[1]
        try #require(chunk.charRange.location > 0)

        // Chapter-relative indexing: an index inside chunk 1's range must resolve, and one from
        // chunk 0 must not.
        let inside = chunk.charRange.location + min(50, chunk.charRange.length - 1)
        #expect(chunk.topOffset(forCharacterIndex: inside) != nil)
        #expect(chunk.topOffset(forCharacterIndex: 1) == nil)
    }

    @Test("vertical writing declines rather than answering in the wrong axis")
    func verticalWritingReturnsNil() throws {
        let attributed = NSAttributedString(
            string: (0..<40).map { "直排第 \($0) 段內容夠長可以換行。" }.joined(separator: "\n"),
            attributes: [.font: Self.font, .foregroundColor: UIColor.black]
        )
        let chunks = CoreTextChunkSlicer.slice(
            attributedString: attributed,
            chapterIndex: 0,
            contentWidth: 320,
            heightCap: 240,
            writingMode: .verticalRTL
        ).chunks
        let chunk = try #require(chunks.first)

        // Vertical lines advance along x. Returning a y here would move the reader sideways in a
        // coordinate space that means nothing; the caller keeps chunk-edge behaviour instead.
        let inside = chunk.charRange.location + min(20, max(1, chunk.charRange.length - 1))
        #expect(chunk.topOffset(forCharacterIndex: inside) == nil)
    }
}
