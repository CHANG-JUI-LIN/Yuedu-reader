import CoreText
import Foundation
import UIKit

/// A sliced CoreText content block, corresponding to one UICollectionView cell.
/// `frame` being nil means it has been evicted and can be reconstructed from `framesetter` + `charRange`.
final class CoreTextChunk {
    let chapterIndex: Int
    /// Character range (UTF-16) within the chapter's attributedString
    let charRange: CFRange
    let height: CGFloat
    let width: CGFloat
    /// Shared across all chunks of the same chapter; used to rebuild frame after eviction
    let framesetter: CTFramesetter
    let attributedString: NSAttributedString

    private(set) var frame: CTFrame?
    /// Image attachment positions (UIKit coordinates, relative to chunk top-left origin). Cached once during slicing.
    private(set) var attachments: [CoreTextPaginator.RenderedAttachment] = []

    /// Whether this chunk is a single-image block (cover / full-page illustration). When true, skip CTFrame rendering and only draw attachments.
    let isImageOnly: Bool

    init(chapterIndex: Int,
         charRange: CFRange,
         size: CGSize,
         framesetter: CTFramesetter,
         attributedString: NSAttributedString,
         frame: CTFrame?,
         presetAttachments: [CoreTextPaginator.RenderedAttachment]? = nil,
         isImageOnly: Bool = false) {
        self.chapterIndex = chapterIndex
        self.charRange = charRange
        self.width = size.width
        self.height = size.height
        self.framesetter = framesetter
        self.attributedString = attributedString
        self.frame = frame
        self.isImageOnly = isImageOnly
        if let preset = presetAttachments {
            self.attachments = preset
        } else if let f = frame {
            self.attachments = CoreTextChunkAttachmentExtractor.extract(
                frame: f,
                chunkSize: size,
                attributedString: attributedString,
                rangeInChapter: charRange
            )
        }
    }

    func materializeFrameIfNeeded() {
        if isImageOnly { return }
        guard frame == nil else { return }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let f = CTFramesetterCreateFrame(framesetter, charRange, path, nil)
        frame = f
        if attachments.isEmpty {
            attachments = CoreTextChunkAttachmentExtractor.extract(
                frame: f,
                chunkSize: CGSize(width: width, height: height),
                attributedString: attributedString,
                rangeInChapter: charRange
            )
        }
    }

    func evictFrame() {
        frame = nil
    }

    // MARK: - Selection (hit-test / rect calculation)

    /// Converts a UIKit coordinate point within the cell to a chapter-level character index (including the full-chapter index starting from charRange.location)
    func stringIndex(atLocalPoint point: CGPoint) -> Int? {
        if isImageOnly { return nil }
        materializeFrameIfNeeded()
        guard let frame = frame else { return nil }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let coreY = height - point.y
        var bestIdx = 0
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for i in lines.indices {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[i], &ascent, &descent, nil)
            let originY = origins[i].y
            let minY = originY - descent
            let maxY = originY + ascent
            if coreY >= minY && coreY <= maxY {
                bestIdx = i
                bestDist = 0
                break
            }
            let d = coreY < minY ? minY - coreY : coreY - maxY
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        let line = lines[bestIdx]
        let lineOrigin = origins[bestIdx]
        let relativeX = point.x - lineOrigin.x
        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: relativeX, y: 0))
        if idx != kCFNotFound { return max(0, idx) }
        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return nil }
        if relativeX <= 0 { return max(0, range.location) }
        return max(0, range.location + range.length - 1)
    }

    /// Intersects the chapter range with this chunk's character range and produces cell-local (UIKit coordinate) highlight rectangles
    func selectionRects(forChapterRange chapterRange: NSRange) -> [CGRect] {
        if isImageOnly { return [] }
        materializeFrameIfNeeded()
        guard let frame = frame else { return [] }
        let chunkNS = NSRange(location: charRange.location, length: charRange.length)
        let inter = NSIntersectionRange(chunkNS, chapterRange)
        guard inter.length > 0 else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        var rects: [CGRect] = []
        for i in lines.indices {
            let line = lines[i]
            let lineRange = CTLineGetStringRange(line)
            let lineNS = NSRange(location: lineRange.location, length: lineRange.length)
            let lineInter = NSIntersectionRange(lineNS, inter)
            guard lineInter.length > 0 else { continue }
            let startOffset = CGFloat(CTLineGetOffsetForStringIndex(line, lineInter.location, nil))
            let endOffset = CGFloat(CTLineGetOffsetForStringIndex(line, lineInter.location + lineInter.length, nil))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let originY = origins[i].y
            let uiTop = height - (originY + ascent)
            let uiBottom = height - (originY - descent)
            rects.append(CGRect(
                x: origins[i].x + startOffset,
                y: uiTop,
                width: max(0, endOffset - startOffset),
                height: max(0, uiBottom - uiTop)
            ))
        }
        return rects
    }
}
