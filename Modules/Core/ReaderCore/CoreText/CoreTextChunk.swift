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
    let writingMode: ReaderWritingMode

    private(set) var frame: CTFrame?
    var isMaterialized: Bool {
        isImageOnly || frame != nil
    }
    /// Image attachment positions (UIKit coordinates, relative to chunk top-left origin). Cached once during slicing.
    private(set) var attachments: [CoreTextPaginator.RenderedAttachment] = []

    /// Whether this chunk is a single-image block (cover / full-page illustration). When true, skip CTFrame rendering and only draw attachments.
    let isImageOnly: Bool
    /// Horizontal scroll-mode CSS float notch in this chunk's CoreText frame path.
    let floatNotch: CGRect?
    /// Images drawn in the float notch. Kept separately so frame eviction/rebuild preserves them.
    let floatAttachments: [CoreTextPaginator.RenderedAttachment]
    /// Block-level decorations (backgrounds, borders) extracted from the attributed string. Cached once during slicing or materialization.
    private(set) var blockRenderables: [CoreTextPaginator.RenderedBlockRenderable] = []
    /// Inline text annotations (span.small notes in vertical writing mode). Extracted during slicing or frame materialization.
    private(set) var inlineAnnotations: [CoreTextPaginator.RenderedInlineAnnotation] = []

    init(chapterIndex: Int,
         charRange: CFRange,
         size: CGSize,
         framesetter: CTFramesetter,
         attributedString: NSAttributedString,
         frame: CTFrame?,
         writingMode: ReaderWritingMode = .horizontal,
         presetAttachments: [CoreTextPaginator.RenderedAttachment]? = nil,
         isImageOnly: Bool = false,
         floatNotch: CGRect? = nil,
         floatAttachments: [CoreTextPaginator.RenderedAttachment] = [],
         blockRenderables: [CoreTextPaginator.RenderedBlockRenderable] = [],
         inlineAnnotations: [CoreTextPaginator.RenderedInlineAnnotation] = []) {
        self.chapterIndex = chapterIndex
        self.charRange = charRange
        self.width = size.width
        self.height = size.height
        self.framesetter = framesetter
        self.attributedString = attributedString
        self.writingMode = writingMode
        self.frame = frame
        self.isImageOnly = isImageOnly
        self.floatNotch = floatNotch
        self.floatAttachments = floatAttachments
        self.blockRenderables = blockRenderables
        self.inlineAnnotations = inlineAnnotations
        if let preset = presetAttachments {
            self.attachments = preset
        } else if let f = frame {
            self.attachments = floatAttachments + CoreTextChunkAttachmentExtractor.extract(
                frame: f,
                chunkSize: size,
                attributedString: attributedString,
                rangeInChapter: charRange,
                writingMode: writingMode
            )
        }
    }

    func materializeFrameIfNeeded() {
        if isImageOnly { return }
        guard frame == nil else { return }
        guard let built = buildFrameData() else { return }
        applyBuiltFrame(built)
    }

    /// Result of an off-main frame build, ready to be applied on the main thread.
    struct BuiltFrame {
        let frame: CTFrame
        let attachments: [CoreTextPaginator.RenderedAttachment]
        let inlineAnnotations: [CoreTextPaginator.RenderedInlineAnnotation]
        let blockRenderables: [CoreTextPaginator.RenderedBlockRenderable]
    }

    /// Builds the CTFrame and its derived data. Reads only immutable stored
    /// properties, so it is safe to call off the main thread; the result is
    /// applied via `applyBuiltFrame` back on the main thread.
    func buildFrameData() -> BuiltFrame? {
        if isImageOnly { return nil }
        let size = CGSize(width: width, height: height)
        let path = CoreTextPaginator.framePath(
            contentPathRect: CGRect(origin: .zero, size: size),
            floatNotch: floatNotch
        )
        let f = CoreTextPaginator.makeFrame(
            framesetter: framesetter,
            range: charRange,
            path: path,
            writingMode: writingMode
        )
        let builtAttachments = floatAttachments + CoreTextChunkAttachmentExtractor.extract(
            frame: f,
            chunkSize: size,
            attributedString: attributedString,
            rangeInChapter: charRange,
            writingMode: writingMode
        )
        let builtInline = writingMode.isVertical
            ? CoreTextChunkSlicer.extractInlineAnnotations(
                frame: f,
                chunkSize: size,
                attributedString: attributedString
              )
            : []
        let builtBlocks = !writingMode.isVertical
            ? CoreTextChunkSlicer.extractBlockRenderables(
                frame: f,
                chunkSize: size,
                attributedString: attributedString,
                charRange: charRange
              )
            : []
        return BuiltFrame(
            frame: f,
            attachments: builtAttachments,
            inlineAnnotations: builtInline,
            blockRenderables: builtBlocks
        )
    }

    /// Applies a frame built by `buildFrameData`. Must run on the main thread
    /// (the only writer of `frame`); no-ops if the frame was already materialized.
    func applyBuiltFrame(_ built: BuiltFrame) {
        guard frame == nil else { return }
        frame = built.frame
        if attachments.isEmpty { attachments = built.attachments }
        if writingMode.isVertical && inlineAnnotations.isEmpty {
            inlineAnnotations = built.inlineAnnotations
        }
        if !writingMode.isVertical && blockRenderables.isEmpty {
            blockRenderables = built.blockRenderables
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

        if writingMode.isVertical {
            return verticalStringIndex(point: point, lines: lines, origins: origins)
        }

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

        // Check horizontal bounds: tap must be within the line's actual typographic width.
        var lineAscent: CGFloat = 0, lineDescent: CGFloat = 0, lineLeading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &lineLeading))
        let textEndX = lineOrigin.x + lineWidth
        let tapTolerance: CGFloat = 10
        guard point.x >= lineOrigin.x - tapTolerance,
              point.x <= textEndX + tapTolerance
        else {
            return nil
        }

        let relativeX = point.x - lineOrigin.x
        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: relativeX, y: 0))
        if idx != kCFNotFound { return max(0, idx) }
        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return nil }
        if relativeX <= 0 { return max(0, range.location) }
        return max(0, range.location + range.length - 1)
    }

    /// Vertical-rl hit-testing: columns are lines; X selects the column, Y is inline advance within the column.
    private func verticalStringIndex(point: CGPoint, lines: [CTLine], origins: [CGPoint]) -> Int? {
        let tapTolerance: CGFloat = 10

        // Find column by X (block-direction position)
        var bestIdx: Int?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for i in lines.indices {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[i], &ascent, &descent, nil)
            let baselineX = origins[i].x
            let x1 = baselineX - descent
            let x2 = baselineX + ascent
            let minX = min(x1, x2)
            let maxX = max(x1, x2)
            if point.x >= minX - tapTolerance, point.x <= maxX + tapTolerance {
                bestIdx = i; bestDist = 0; break
            }
            let d = point.x < minX ? minX - point.x : point.x - maxX
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        guard let lineIdx = bestIdx, bestDist <= tapTolerance else { return nil }

        let line = lines[lineIdx]
        let lineOrigin = origins[lineIdx]

        var ascent: CGFloat = 0, descent: CGFloat = 0
        let lineAdvance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        // Inline Y bounds: lineOrigin.y is CoreText Y-up → convert to UIKit Y-down
        let lineTopY = height - lineOrigin.y
        let relativeAdvance = point.y - lineTopY
        guard relativeAdvance >= -tapTolerance, relativeAdvance <= lineAdvance + tapTolerance else {
            return nil
        }

        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, min(lineAdvance, relativeAdvance)), y: 0))
        if idx != kCFNotFound { return max(0, idx) }
        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return nil }
        if relativeAdvance <= 0 { return max(0, range.location) }
        return max(0, range.location + range.length - 1)
    }

}

// Thread-safety contract: `buildFrameData` reads only immutable stored
// properties and may run off the main thread; `frame` and the derived arrays
// are written exclusively on the main thread (via `applyBuiltFrame` /
// `materializeFrameIfNeeded`), which is also the only reader during cell draw.
extension CoreTextChunk: @unchecked Sendable {}
extension CoreTextChunk.BuiltFrame: @unchecked Sendable {}
