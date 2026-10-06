import YueduCoreText
import CoreText
import Foundation
import UIKit
import YueduCoreTextTypography

/// A sliced CoreText content block, corresponding to one UICollectionView cell.
/// `frame` being nil means it has been evicted and can be reconstructed from `framesetter` + `charRange`.
final class CoreTextChunk {
    let chapterIndex: Int
    /// Character range (UTF-16) within the chapter's attributedString
    let charRange: CFRange
    let height: CGFloat
    let width: CGFloat
    /// Shared across all chunks of the same chapter; used to rebuild frame after eviction.
    /// The main thread owns it once slicing hands the chunks over: Core Text layout
    /// objects are used by one thread at a time. Off-main frame builds use
    /// framesetters their executor owns (`CoreTextFramesetterCache`).
    let framesetter: CTFramesetter
    let attributedString: NSAttributedString
    let writingMode: ReaderWritingMode
    /// Publication-authored page backdrop. The color is painted first, then the image, so
    /// transparent EPUB artwork composites against the intended fill instead of the reader theme.
    let pageBackgroundColor: UIColor?
    let pageBackgroundImage: UIImage?

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
         inlineAnnotations: [CoreTextPaginator.RenderedInlineAnnotation] = [],
         pageBackgroundColor: UIColor? = nil,
         pageBackgroundImage: UIImage? = nil) {
        self.chapterIndex = chapterIndex
        self.charRange = charRange
        self.width = size.width
        self.height = size.height
        self.framesetter = framesetter
        self.attributedString = attributedString
        self.writingMode = writingMode
        self.pageBackgroundColor = pageBackgroundColor
        self.pageBackgroundImage = pageBackgroundImage
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

    /// The one recipe for this chunk's CTFrame: same range, path and frame
    /// attributes for the first build, a rebuild after eviction, and the scroll
    /// raster worker. Reads only immutable stored properties. The caller owns
    /// `framesetter` exclusively while this runs (Core Text layout objects are
    /// used by one thread at a time).
    func makeFrame(using framesetter: CTFramesetter) -> CTFrame {
        CoreTextPaginator.makeFrame(
            framesetter: framesetter,
            range: charRange,
            path: CoreTextPaginator.framePath(
                contentPathRect: CGRect(origin: .zero, size: CGSize(width: width, height: height)),
                floatNotch: floatNotch
            ),
            writingMode: writingMode
        )
    }

    /// Result of an off-main frame build, ready to be applied on the main thread.
    struct BuiltFrame {
        let frame: CTFrame
        let attachments: [CoreTextPaginator.RenderedAttachment]
        let inlineAnnotations: [CoreTextPaginator.RenderedInlineAnnotation]
        let blockRenderables: [CoreTextPaginator.RenderedBlockRenderable]
    }

    /// Builds with the chapter's shared `framesetter`, which the main thread owns
    /// after slicing. Main thread only: an off-main build uses
    /// `buildFrameData(using:)` with a framesetter its executor owns
    /// (`CoreTextFrameWarmer`), never this one.
    func buildFrameData() -> BuiltFrame? {
        assert(Thread.isMainThread, "CoreTextChunk.framesetter is used by the main thread only")
        return buildFrameData(using: framesetter)
    }

    /// Builds the CTFrame and its derived data. Reads only immutable stored
    /// properties; the caller owns `framesetter` exclusively while this runs.
    /// The result is applied via `applyBuiltFrame` on the main thread.
    func buildFrameData(using framesetter: CTFramesetter) -> BuiltFrame? {
        if isImageOnly { return nil }
        let size = CGSize(width: width, height: height)
        let f = makeFrame(using: framesetter)
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

    // MARK: - Position restore

    /// Distance from this chunk's top edge to the top of the line holding `characterIndex`.
    ///
    /// The inverse of `stringIndex(atLocalPoint:)`, and the piece that makes restoring a reading
    /// position character-accurate. Without it the reader can only be put at a chunk's top edge,
    /// which silently discards however far into the chunk they actually were — measured on device
    /// at 84, 259 and 530 characters. Worse, the discarded position is what gets saved on the way
    /// out, so every visit to scroll mode walks the reader's progress backwards.
    ///
    /// - Parameter characterIndex: chapter-relative UTF-16 index, the same space as `charRange`.
    /// - Returns: `nil` when the index is outside this chunk, or when there is nothing to lay out
    ///   (an image-only chunk has no lines and its top edge *is* the right answer).
    func topOffset(forCharacterIndex characterIndex: Int) -> CGFloat? {
        guard !isImageOnly,
              characterIndex > charRange.location,
              characterIndex < charRange.location + charRange.length
        else { return nil }
        materializeFrameIfNeeded()
        guard let frame else { return nil }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        // Vertical writing lays lines out along x, right to left; the caller handles that axis
        // itself, so refuse rather than return a number in the wrong axis.
        guard !writingMode.isVertical else { return nil }

        for index in lines.indices {
            // `CTLineGetStringRange` already reports chapter-relative indices, because the frame
            // was built from a range of the whole chapter's attributed string. Adding
            // `charRange.location` on top double-counts: harmless for the chunk at offset 0,
            // but for every later chunk it pushes `start` past the target so the *first* line
            // always matches — the restore then lands 2.5pt into the chunk no matter where the
            // reader actually was. `stringIndex(atLocalPoint:)` returns these ranges unmodified
            // for the same reason.
            let lineRange = CTLineGetStringRange(lines[index])
            guard characterIndex < lineRange.location + lineRange.length else {
                continue
            }
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[index], &ascent, nil, nil)
            // CoreText origins are bottom-up within the frame; the line's top in UIKit
            // coordinates is the frame height minus its ascent above the baseline.
            return max(0, height - (origins[index].y + ascent))
        }
        return nil
    }

    // MARK: - Selection (hit-test / rect calculation)

    /// Reading progress is the line at the viewport's leading edge, independent
    /// of its alignment or width. A selection hit test can legitimately miss a
    /// short line at the viewport centre; that must never reset saved progress
    /// to the start of a multi-screen chunk.
    func readingOffset(atVerticalOffset y: CGFloat) -> Int? {
        guard !writingMode.isVertical else { return nil }
        if isImageOnly { return charRange.location }
        materializeFrameIfNeeded()
        guard let frame else { return nil }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let coreY = height - y
        var nearest: Int?
        var distance = CGFloat.greatestFiniteMagnitude
        for index in lines.indices {
            let range = CTLineGetStringRange(lines[index])
            guard range.length > 0 else { continue }
            var ascent: CGFloat = 0, descent: CGFloat = 0
            CTLineGetTypographicBounds(lines[index], &ascent, &descent, nil)
            let delta = max(0, origins[index].y - descent - coreY,
                            coreY - origins[index].y - ascent)
            if delta < distance {
                nearest = range.location
                distance = delta
            }
            if delta == 0 { break }
        }
        return nearest
    }

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
        let idx = GlyphBoundary.index(line, at: relativeX)
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

        let idx = GlyphBoundary.index(line, at: max(0, min(lineAdvance, relativeAdvance)))
        if idx != kCFNotFound { return max(0, idx) }
        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return nil }
        if relativeAdvance <= 0 { return max(0, range.location) }
        return max(0, range.location + range.length - 1)
    }

}

// Thread-safety contract: `buildFrameData(using:)` and `makeFrame(using:)` read
// only immutable stored properties and may run off the main thread with a
// framesetter the calling executor owns. The shared `framesetter` is used on the
// main thread only (`buildFrameData()`). `frame` and the derived arrays are
// written exclusively on the main thread (via `applyBuiltFrame` /
// `materializeFrameIfNeeded`), which is also the only reader during cell draw.
extension CoreTextChunk: @unchecked Sendable {}
extension CoreTextChunk.BuiltFrame: @unchecked Sendable {}
