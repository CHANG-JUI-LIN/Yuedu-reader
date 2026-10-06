import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// Selection, highlights and narration in the legacy engine draw rects from
/// `CoreTextAnnotationRenderer.rects`. After punctuation squeezed by a negative kern,
/// each character's rect must start where its glyph does: CoreText's caret offsets put
/// the boundary half the kern inside the next glyph, which cut a quarter em off it.
@Suite("Legacy selection geometry")
struct LegacySelectionGeometryTests {
    private static let size: CGFloat = 20

    /// 國？」國國, Traditional: 」 gives up its far side to the fixed ？.
    private func line(vertical: Bool) -> CTLine {
        let text = NSMutableAttributedString(string: "國？」國國", attributes: [.font: UIFont.systemFont(ofSize: Self.size)])
        CJKTypography.apply(to: text, style: .traditional, vertical: vertical)
        if vertical { CJKTypography.applyOrientation(to: text) }
        return CTLineCreateWithAttributedString(text)
    }

    /// Where each character's glyph starts along the line, from the advances.
    private func glyphStarts(_ line: CTLine) -> [CGFloat] {
        var advances: [(index: CFIndex, width: CGFloat)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var widths = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &widths)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            advances += zip(indices, widths).map { ($0.0, $0.1.width) }
        }
        return (0...5).map { index in advances.filter { $0.index < index }.reduce(0) { $0 + $1.width } }
    }

    @Test("Each character's rect spans its glyph after a squeezed mark", arguments: [false, true])
    func rectsFollowGlyphs(vertical: Bool) {
        let line = line(vertical: vertical)
        let starts = glyphStarts(line)
        for index in 0..<5 {
            let rect = CoreTextAnnotationRenderer.rects(
                forRange: NSRange(location: index, length: 1), lines: [line], lineOrigins: [.zero],
                layoutHeight: 0, writingMode: vertical ? .verticalRTL : .horizontal
            ).first ?? .null
            let (from, to) = vertical ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
            #expect(abs(from - starts[index]) < 0.01 && abs(to - starts[index + 1]) < 0.01,
                    "vertical=\(vertical) index \(index): \(from)...\(to), glyph \(starts[index])...\(starts[index + 1])")
        }
    }
}
