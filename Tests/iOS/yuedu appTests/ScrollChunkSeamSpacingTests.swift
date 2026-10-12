import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Scroll mode stacks a chapter's chunks edge to edge. Each chunk ends at a paragraph
/// break, so the 段距 after that paragraph has to live inside the chunk's height — the
/// next chunk's first line starts right at its own top.
@Suite("Scroll chunk seam spacing")
struct ScrollChunkSeamSpacingTests {
    /// Baselines of every line, measured from the top of the stacked column.
    private static func stackedBaselines(_ chunks: [CoreTextChunk]) -> [(y: CGFloat, chunk: Int)] {
        var top: CGFloat = 0
        var result: [(y: CGFloat, chunk: Int)] = []
        for (index, chunk) in chunks.enumerated() {
            let frame = try! #require(chunk.frame)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
            let pathHeight = CTFrameGetPath(frame).boundingBoxOfPath.maxY
            for origin in origins {
                result.append((top + pathHeight - origin.y, index))
            }
            top += chunk.height
        }
        return result
    }

    /// Vertical-rl stacks chunks right to left. Distance of every column's baseline from
    /// the right edge of the stacked row, plus whether that column opens a paragraph.
    private static func stackedColumns(_ chunks: [CoreTextChunk], text: NSString) -> [(x: CGFloat, chunk: Int, opensParagraph: Bool)] {
        var right: CGFloat = 0
        var result: [(x: CGFloat, chunk: Int, opensParagraph: Bool)] = []
        for (index, chunk) in chunks.enumerated() {
            let frame = try! #require(chunk.frame)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
            let pathWidth = CTFrameGetPath(frame).boundingBoxOfPath.maxX
            for (line, origin) in zip(lines, origins) {
                let start = CTLineGetStringRange(line).location
                let opens = start == 0 || text.character(at: start - 1) == 0x000A
                result.append((right + pathWidth - origin.x, index, opens))
            }
            right += chunk.width
        }
        return result
    }

    enum Source: String, CaseIterable {
        /// What a TXT book actually lays out with.
        case txtBuilder
        /// 段距 entirely after the paragraph.
        case spacingAfter
        /// 段距 split, as CSS margins arrive: Core Text drops the `before` half on a
        /// frame's first paragraph, so the seam has to carry both halves.
        case spacingBeforeAndAfter
    }

    /// Two-line paragraphs (in a 340pt line), so every paragraph break is visible as a
    /// larger step.
    private static func chapter(_ source: Source, writingMode: ReaderWritingMode = .horizontal) async throws -> NSAttributedString {
        let paragraph = "夜色漸深，城外的河水緩緩流過石橋，橋下的燈火映在水面上搖晃不定。他站在窗前。"
        let body = String(repeating: paragraph + "\n", count: 60)
        switch source {
        case .txtBuilder:
            let builder = TXTLazyAttributedStringBuilder(text: body, chapterIndexes: [
                TXTChapterIndex(index: 0, title: "", contentRange: NSRange(location: 0, length: (body as NSString).length))
            ])
            var settings = EPUBTestFixtures.renderSettings(fontSize: 18, lineHeightMultiple: 1.65, paragraphSpacing: 14.4)
            settings.writingMode = writingMode
            return try await builder.buildChapter(
                at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white
            ).attributedString
        case .spacingAfter, .spacingBeforeAndAfter:
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.65
            style.paragraphSpacing = source == .spacingAfter ? 14.4 : 6.4
            style.paragraphSpacingBefore = source == .spacingAfter ? 0 : 8
            return NSAttributedString(string: body, attributes: [
                .font: UIFont.systemFont(ofSize: 18), .paragraphStyle: style,
            ])
        }
    }

    @Test("A paragraph that ends a chunk keeps its 段距 before the next chunk", arguments: Source.allCases)
    func seamKeepsParagraphSpacing(source: Source) async throws {
        let attributed = try await Self.chapter(source)

        let output = CoreTextChunkSlicer.slice(
            attributedString: attributed,
            chapterIndex: 0,
            contentWidth: 340,
            heightCap: 400
        )
        try #require(output.chunks.count > 3)

        let baselines = Self.stackedBaselines(output.chunks)
        let steps = zip(baselines, baselines.dropFirst()).map { (gap: $1.y - $0.y, seam: $1.chunk != $0.chunk) }
        // Inside a chunk the steps are a line pitch or a line pitch plus 段距.
        let paragraphStep = try #require(steps.filter { !$0.seam }.map(\.gap).max())
        let lineStep = try #require(steps.filter { !$0.seam }.map(\.gap).min())
        try #require(paragraphStep - lineStep > 10, "the chapter has no visible 段距")

        let seams = steps.filter(\.seam)
        try #require(!seams.isEmpty)
        for seam in seams {
            // Every chunk ends at a paragraph break, so every seam is a paragraph step.
            #expect(abs(seam.gap - paragraphStep) < 0.5, "seam step \(seam.gap), paragraph step \(paragraphStep)")
        }
    }

    @Test("Vertical chunks stack their columns at the same pitch as inside a chunk", arguments: Source.allCases)
    func verticalSeamKeepsColumnPitch(source: Source) async throws {
        let raw = try await Self.chapter(source, writingMode: .verticalRTL)
        // As `CoreTextScrollEngine.prepareAttributedString` hands a vertical chapter over.
        let attributed = CoreTextPaginator.preparedAttributedString(
            raw, writingMode: .verticalRTL, fontSize: 18, maxInlineAnnotationAdvance: 340 - 36)

        let output = CoreTextChunkSlicer.slice(
            attributedString: attributed,
            chapterIndex: 0,
            contentWidth: 340,
            heightCap: 400,
            writingMode: .verticalRTL
        )
        try #require(output.chunks.count > 3)

        for chunk in output.chunks {
            let visible = CTFrameGetVisibleStringRange(try #require(chunk.frame))
            #expect(visible.location == chunk.charRange.location && visible.length == chunk.charRange.length,
                    "chunk \(chunk.charRange) lays out only \(visible)")
        }

        let columns = Self.stackedColumns(output.chunks, text: attributed.string as NSString)
        let steps = zip(columns, columns.dropFirst()).map {
            (gap: $1.x - $0.x, seam: $1.chunk != $0.chunk, opensParagraph: $1.opensParagraph)
        }
        let inside = steps.filter { !$0.seam }
        let paragraphStep = try #require(inside.filter(\.opensParagraph).map(\.gap).max())
        let lineStep = try #require(inside.filter { !$0.opensParagraph }.map(\.gap).max())
        try #require(paragraphStep - lineStep > 10, "the chapter has no visible 段距")

        let seams = steps.filter(\.seam)
        try #require(!seams.isEmpty)
        for seam in seams {
            let expected = seam.opensParagraph ? paragraphStep : lineStep
            #expect(abs(seam.gap - expected) < 0.5,
                    "seam step \(seam.gap), expected \(expected) (opens paragraph: \(seam.opensParagraph))")
        }
    }
}
