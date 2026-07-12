import CoreText
import Foundation
import UIKit

/// Slices a chapter's NSAttributedString into multiple chunks of approximately heightCap height each.
/// Pure function, safe to run on background threads.
enum CoreTextChunkSlicer {
    /// Default max height per chunk: ~3 screen heights, balancing slicing cost and memory
    static let defaultHeightCap: CGFloat = 2000

    /// When the natural fitRange would split a paragraph, look backward up to this many UTF-16 code units
    /// for the nearest paragraph boundary. Chunks that would become too short are left unsplit.
    static let paragraphBoundaryLookback: CGFloat = 400

    /// Slicing result
    struct Output {
        let chunks: [CoreTextChunk]
        let framesetter: CTFramesetter
        let attributedString: NSAttributedString
    }

    static func slice(
        attributedString attrStr: NSAttributedString,
        chapterIndex: Int,
        contentWidth: CGFloat,
        heightCap: CGFloat = defaultHeightCap,
        writingMode: ReaderWritingMode = .horizontal,
        pageBackgroundColor: UIColor? = nil,
        pageBackgroundImage: UIImage? = nil
    ) -> Output {
        let framesetter = CoreTextFramesetterFactory.make(for: attrStr)
        let totalLen = attrStr.length
        guard contentWidth > 0, totalLen > 0 else {
            return Output(chunks: [], framesetter: framesetter, attributedString: attrStr)
        }

        if writingMode.isVertical {
            return sliceVertical(
                attributedString: attrStr,
                framesetter: framesetter,
                chapterIndex: chapterIndex,
                contentHeight: contentWidth,
                widthCap: heightCap,
                writingMode: writingMode,
                pageBackgroundColor: pageBackgroundColor,
                pageBackgroundImage: pageBackgroundImage
            )
        }

        let nsString = attrStr.string as NSString
        var chunks: [CoreTextChunk] = []
        var offset: CFIndex = 0

        while offset < totalLen {
            let constraints = CGSize(width: contentWidth, height: heightCap)
            var fitRange = CFRange(location: 0, length: 0)
            var suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: offset, length: 0),
                nil,
                constraints,
                &fitRange
            )

            // Single element exceeds heightCap (e.g. cover image, large illustration) → re-fetch without height limit
            if fitRange.length == 0 {
                var fr2 = CFRange(location: 0, length: 0)
                suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    CFRange(location: offset, length: 0),
                    nil,
                    CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    &fr2
                )
                fitRange = fr2
            }

            // Guard: CoreText occasionally returns length 0; force advance at least 1 character to avoid infinite loop
            let consumeLen = max(fitRange.length, 1)
            var actualRange = CFRange(location: offset, length: min(consumeLen, totalLen - offset))

            // ── Paragraph-boundary adjustment ──
            // When the natural fitRange would split a paragraph, walk backward to the nearest \n
            // so each chunk starts at a paragraph boundary, preserving paragraphSpacingBefore and firstLineHeadIndent.
            if actualRange.length > 0, actualRange.location + actualRange.length < totalLen {
                let chunkEnd = actualRange.location + actualRange.length
                let lookbackStart = max(actualRange.location, chunkEnd - Int(paragraphBoundaryLookback))
                var paragraphBoundary: Int?
                var searchPos = chunkEnd - 1
                while searchPos >= lookbackStart {
                    let char = nsString.character(at: searchPos)
                    if char == 0x000A { // \n paragraph separator
                        paragraphBoundary = searchPos + 1 // include the \n in the current chunk
                        break
                    }
                    searchPos -= 1
                }
                if let boundary = paragraphBoundary, boundary > actualRange.location {
                    let adjustedLen = boundary - actualRange.location
                    actualRange.length = adjustedLen
                    // Recompute height for the trimmed range
                    var frAdj = CFRange(location: 0, length: 0)
                    suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                        framesetter,
                        actualRange,
                        nil,
                        CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                        &frAdj
                    )
                }
            }

            var actualHeight = ceil(max(suggested.height, 1))

            // Ensure chunk height accommodates block images (drawHeight) within the range
            actualHeight = max(actualHeight, blockImageHeight(in: attrStr, range: actualRange))
            actualHeight = max(actualHeight, floatImageHeight(in: attrStr, range: actualRange))

            var frameBuild = makeHorizontalFrame(
                framesetter: framesetter,
                attrStr: attrStr,
                range: actualRange,
                chunkSize: CGSize(width: contentWidth, height: actualHeight),
                writingMode: writingMode
            )

            if let splitLocation = frameBuild.splitBeforeFloatLocation,
               splitLocation > actualRange.location {
                actualRange.length = splitLocation - actualRange.location
                var frAdj = CFRange(location: 0, length: 0)
                suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    actualRange,
                    nil,
                    CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    &frAdj
                )
                actualHeight = ceil(max(suggested.height, 1))
                actualHeight = max(actualHeight, blockImageHeight(in: attrStr, range: actualRange))
                frameBuild = makeHorizontalFrame(
                    framesetter: framesetter,
                    attrStr: attrStr,
                    range: actualRange,
                    chunkSize: CGSize(width: contentWidth, height: actualHeight),
                    writingMode: writingMode
                )
            }

            let visible = CTFrameGetVisibleStringRange(frameBuild.frame)
            if visible.location == actualRange.location,
               visible.length > 0,
               visible.length < actualRange.length {
                actualRange.length = visible.length
                frameBuild = makeHorizontalFrame(
                    framesetter: framesetter,
                    attrStr: attrStr,
                    range: actualRange,
                    chunkSize: CGSize(width: contentWidth, height: actualHeight),
                    writingMode: writingMode
                )
            }

            let chunkSize = CGSize(width: contentWidth, height: actualHeight)
            // Extract block decorations during slicing so they survive frame eviction
            let decorations = extractBlockRenderables(
                frame: frameBuild.frame,
                chunkSize: chunkSize,
                attributedString: attrStr,
                charRange: actualRange
            )

            chunks.append(CoreTextChunk(
                chapterIndex: chapterIndex,
                charRange: actualRange,
                size: chunkSize,
                framesetter: framesetter,
                attributedString: attrStr,
                frame: frameBuild.frame,
                writingMode: writingMode,
                floatNotch: frameBuild.floatNotch,
                floatAttachments: frameBuild.floatAttachments,
                blockRenderables: decorations,
                pageBackgroundColor: pageBackgroundColor,
                pageBackgroundImage: pageBackgroundImage
            ))

            offset = actualRange.location + actualRange.length
        }

        return Output(chunks: chunks, framesetter: framesetter, attributedString: attrStr)
    }

    private static func sliceVertical(
        attributedString attrStr: NSAttributedString,
        framesetter: CTFramesetter,
        chapterIndex: Int,
        contentHeight: CGFloat,
        widthCap: CGFloat,
        writingMode: ReaderWritingMode,
        pageBackgroundColor: UIColor?,
        pageBackgroundImage: UIImage?
    ) -> Output {
        let totalLen = attrStr.length
        var chunks: [CoreTextChunk] = []
        var offset: CFIndex = 0
        let chunkWidth = max(1, widthCap)
        let chunkHeight = max(1, contentHeight)

        while offset < totalLen {
            let path = CGPath(
                rect: CGRect(x: 0, y: 0, width: chunkWidth, height: chunkHeight),
                transform: nil
            )
            let searchRange = CFRange(location: offset, length: totalLen - offset)
            let probeFrame = CoreTextPaginator.makeFrame(
                framesetter: framesetter,
                range: searchRange,
                path: path,
                writingMode: writingMode
            )
            let visible = CTFrameGetVisibleStringRange(probeFrame)
            let consumeLen = max(visible.length, 1)
            let actualRange = CFRange(location: offset, length: min(consumeLen, totalLen - offset))
            let frame = CoreTextPaginator.makeFrame(
                framesetter: framesetter,
                range: actualRange,
                path: path,
                writingMode: writingMode
            )
            var finalFrame = frame
            var finalChunkWidth = chunkWidth
            if actualRange.location + actualRange.length >= totalLen {
                let usedWidth = min(chunkWidth, max(1, verticalUsedWidth(of: frame) + 2))
                if usedWidth < chunkWidth {
                    let compactPath = CGPath(
                        rect: CGRect(x: 0, y: 0, width: usedWidth, height: chunkHeight),
                        transform: nil
                    )
                    let compactFrame = CoreTextPaginator.makeFrame(
                        framesetter: framesetter,
                        range: actualRange,
                        path: compactPath,
                        writingMode: writingMode
                    )
                    let compactVisible = CTFrameGetVisibleStringRange(compactFrame)
                    if compactVisible.location == actualRange.location,
                       compactVisible.length >= actualRange.length {
                        finalFrame = compactFrame
                        finalChunkWidth = usedWidth
                    }
                }
            }

            let chunkSize = CGSize(width: finalChunkWidth, height: chunkHeight)
            let annotations = extractInlineAnnotations(
                frame: finalFrame,
                chunkSize: chunkSize,
                attributedString: attrStr
            )
            chunks.append(CoreTextChunk(
                chapterIndex: chapterIndex,
                charRange: actualRange,
                size: chunkSize,
                framesetter: framesetter,
                attributedString: attrStr,
                frame: finalFrame,
                writingMode: writingMode,
                blockRenderables: [],
                inlineAnnotations: annotations,
                pageBackgroundColor: pageBackgroundColor,
                pageBackgroundImage: pageBackgroundImage
            ))
            offset = actualRange.location + actualRange.length
        }

        return Output(chunks: chunks, framesetter: framesetter, attributedString: attrStr)
    }

    private static func verticalUsedWidth(of frame: CTFrame) -> CGFloat {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return 1 }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let originX = origins[index].x
            minX = min(minX, originX - descent)
            maxX = max(maxX, originX + ascent)
        }

        guard minX.isFinite, maxX.isFinite, maxX > minX else { return 1 }
        return ceil(maxX - minX)
    }

    private struct HorizontalFrameBuild {
        let frame: CTFrame
        let floatNotch: CGRect?
        let floatAttachments: [CoreTextPaginator.RenderedAttachment]
        let splitBeforeFloatLocation: Int?
    }

    private static func makeHorizontalFrame(
        framesetter: CTFramesetter,
        attrStr: NSAttributedString,
        range: CFRange,
        chunkSize: CGSize,
        writingMode: ReaderWritingMode
    ) -> HorizontalFrameBuild {
        let contentRect = CGRect(origin: .zero, size: chunkSize)
        let rectangularPath = CGPath(rect: contentRect, transform: nil)
        guard !writingMode.isVertical,
              let marker = CoreTextPaginator.floatMarkers(in: attrStr).first(where: { marker in
                  marker.offset >= range.location
                      && marker.offset < range.location + range.length
                      && marker.placeholder.image != nil
              })
        else {
            let frame = CoreTextPaginator.makeFrame(
                framesetter: framesetter,
                range: range,
                path: rectangularPath,
                writingMode: writingMode
            )
            return HorizontalFrameBuild(
                frame: frame,
                floatNotch: nil,
                floatAttachments: [],
                splitBeforeFloatLocation: nil
            )
        }

        let probe = CoreTextPaginator.makeFrame(
            framesetter: framesetter,
            range: range,
            path: rectangularPath,
            writingMode: writingMode
        )
        guard let lineTop = CoreTextPaginator.lineTopY(in: probe, offset: marker.offset, contentPathRect: contentRect),
              let image = marker.placeholder.image else {
            return HorizontalFrameBuild(
                frame: probe,
                floatNotch: nil,
                floatAttachments: [],
                splitBeforeFloatLocation: nil
            )
        }

        let p = marker.placeholder
        let notchWidth = p.drawWidth + p.marginLeft + p.marginRight
        let notchHeight = min(contentRect.height, p.drawHeight + p.marginTop + p.marginBottom)
        let notchBottom = lineTop - notchHeight
        if notchBottom < contentRect.minY, marker.offset > range.location {
            return HorizontalFrameBuild(
                frame: probe,
                floatNotch: nil,
                floatAttachments: [],
                splitBeforeFloatLocation: marker.offset
            )
        }

        let clampedBottom = max(contentRect.minY, notchBottom)
        let uiTop = chunkSize.height - lineTop + p.marginTop
        let notch: CGRect
        let attachmentRect: CGRect
        switch p.side {
        case .left:
            notch = CGRect(x: contentRect.minX, y: clampedBottom, width: notchWidth, height: lineTop - clampedBottom)
            attachmentRect = CGRect(x: contentRect.minX + p.marginLeft, y: uiTop, width: p.drawWidth, height: p.drawHeight)
        case .right:
            notch = CGRect(x: contentRect.maxX - notchWidth, y: clampedBottom, width: notchWidth, height: lineTop - clampedBottom)
            attachmentRect = CGRect(x: contentRect.maxX - p.marginRight - p.drawWidth, y: uiTop, width: p.drawWidth, height: p.drawHeight)
        }

        let path = CoreTextPaginator.framePath(contentPathRect: contentRect, floatNotch: notch)
        let frame = CoreTextPaginator.makeFrame(
            framesetter: framesetter,
            range: range,
            path: path,
            writingMode: writingMode
        )
        let attachment = CoreTextPaginator.RenderedAttachment(
            rect: attachmentRect,
            image: image,
            opacity: 1,
            sourceHref: p.source.isEmpty ? nil : p.source,
            alt: p.alt,
            originalSize: image.size
        )
        return HorizontalFrameBuild(
            frame: frame,
            floatNotch: notch,
            floatAttachments: [attachment],
            splitBeforeFloatLocation: nil
        )
    }

    /// Scans the specified range for block images with CTRunDelegate and returns the maximum drawHeight.
    /// Ensures the chunk path height is large enough to contain the entire image (CoreText measurement may be slightly smaller than drawHeight).
    private static func blockImageHeight(in attrStr: NSAttributedString, range: CFRange) -> CGFloat {
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location >= 0,
              nsRange.location + nsRange.length <= attrStr.length else { return 0 }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var maxHeight: CGFloat = 0
        attrStr.enumerateAttribute(delegateKey, in: nsRange, options: []) { value, effectiveRange, _ in
            guard let v = value else { return }
            guard attrStr.attribute(HTMLAttributedStringBuilder.spacerRunAttribute, at: effectiveRange.location, effectiveRange: nil) == nil else { return }
            let ctDelegate = v as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(ctDelegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            if info.displayMode == .block {
                maxHeight = max(maxHeight, info.drawHeight)
            }
        }
        return maxHeight
    }

    private static func floatImageHeight(in attrStr: NSAttributedString, range: CFRange) -> CGFloat {
        CoreTextPaginator.floatMarkers(in: attrStr)
            .filter { marker in
                marker.offset >= range.location && marker.offset < range.location + range.length
            }
            .map { marker in
                marker.placeholder.drawHeight
                    + marker.placeholder.marginTop
                    + marker.placeholder.marginBottom
            }
            .max() ?? 0
    }

    // MARK: - Block renderable extraction

    /// Extracts block-level decorations (background colors, borders, decorative images) for a single scroll chunk.
    /// Mirrors CoreTextPaginator.extractBlockRenderables but operates on a single CTFrame rather than per-page ranges.
    static func extractBlockRenderables(
        frame: CTFrame,
        chunkSize: CGSize,
        attributedString attrStr: NSAttributedString,
        charRange: CFRange
    ) -> [CoreTextPaginator.RenderedBlockRenderable] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return [] }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let chunkNSRange = NSRange(location: charRange.location, length: charRange.length)
        let contentHeight = chunkSize.height

        // ── Gather decoration spans ──
        var spanGroupsByID: [String: SpanGroup] = [:]

        attrStr.enumerateAttribute(
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            in: chunkNSRange,
            options: []
        ) { value, effectiveRange, _ in
            guard let renderStyle = value as? HTMLAttributedStringBuilder.BlockRenderStyle,
                  let blockID = attrStr.attribute(
                      HTMLAttributedStringBuilder.blockRenderIDAttribute,
                      at: effectiveRange.location,
                      effectiveRange: nil
                  ) as? String
            else { return }
            if var existing = spanGroupsByID[blockID] {
                existing.ranges.append(effectiveRange)
                spanGroupsByID[blockID] = existing
            } else {
                spanGroupsByID[blockID] = SpanGroup(
                    blockID: blockID,
                    style: renderStyle,
                    ranges: [effectiveRange],
                    isContainer: false
                )
            }
        }

        attrStr.enumerateAttribute(
            HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            in: chunkNSRange,
            options: []
        ) { value, effectiveRange, _ in
            guard let renderStyle = value as? HTMLAttributedStringBuilder.BlockRenderStyle,
                  let blockID = attrStr.attribute(
                      HTMLAttributedStringBuilder.containerBlockRenderIDAttribute,
                      at: effectiveRange.location,
                      effectiveRange: nil
                  ) as? String
            else { return }
            if var existing = spanGroupsByID[blockID] {
                existing.ranges.append(effectiveRange)
                spanGroupsByID[blockID] = existing
            } else {
                spanGroupsByID[blockID] = SpanGroup(
                    blockID: blockID,
                    style: renderStyle,
                    ranges: [effectiveRange],
                    isContainer: true
                )
            }
        }

        var groups = Array(spanGroupsByID.values)
        guard !groups.isEmpty else { return [] }

        // ── Union line rects into decoration groups ──
        for (lineIdx, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            guard lineStart < attrStr.length else { continue }
            let lineNSRange = NSRange(location: lineRange.location, length: lineRange.length)

            var lineAscent: CGFloat = 0, lineDescent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
            let lineOrigin = origins[lineIdx]

            for i in groups.indices {
                let intersects = groups[i].ranges.contains { NSIntersectionRange($0, lineNSRange).length > 0 }
                guard intersects else { continue }

                let attributeLocation = max(
                    lineStart,
                    groups[i].ranges.compactMap { span -> Int? in
                        let inter = NSIntersectionRange(span, lineNSRange)
                        return inter.length > 0 ? inter.location : nil
                    }.min() ?? lineStart
                )
                guard let paragraphStyle = attrStr.attribute(
                    .paragraphStyle, at: attributeLocation, effectiveRange: nil
                ) as? NSParagraphStyle else { continue }

                let leftInset = min(paragraphStyle.headIndent, paragraphStyle.firstLineHeadIndent)
                let rightInset = paragraphStyle.tailIndent < 0 ? -paragraphStyle.tailIndent : 0
                let availableWidth = max(1, chunkSize.width - leftInset - rightInset)
                let preferredWidth = max(1, min(availableWidth,
                    groups[i].style.blockImage.map { $0.drawSize.width + $0.paddingLeft + $0.paddingRight }
                        ?? groups[i].style.width ?? availableWidth))

                let blockX: CGFloat
                if groups[i].style.isHorizontallyCentered {
                    blockX = leftInset + max(0, (availableWidth - preferredWidth) / 2)
                } else {
                    switch groups[i].style.textAlign {
                    case .center: blockX = leftInset + max(0, (availableWidth - preferredWidth) / 2)
                    case .right:  blockX = leftInset + max(0, availableWidth - preferredWidth)
                    default:       blockX = leftInset
                    }
                }

                let lineHeight = max(paragraphStyle.minimumLineHeight, lineAscent + lineDescent)
                let blockHeight = max(lineHeight,
                    groups[i].style.blockImage?.drawSize.height ?? groups[i].style.height ?? lineHeight)
                let uiY = contentHeight - (lineOrigin.y + lineAscent)

                let rect = CGRect(x: blockX, y: uiY, width: preferredWidth, height: blockHeight)
                groups[i].rect = groups[i].rect.isNull ? rect : groups[i].rect.union(rect)
            }
        }

        // ── Build RenderedBlockRenderable from groups ──
        return groups.compactMap { group -> CoreTextPaginator.RenderedBlockRenderable? in
            guard !group.rect.isNull else { return nil }
            let imageAttachment = chunkBlockImageAttachment(
                rect: group.rect, style: group.style, ranges: group.ranges, attrStr: attrStr
            )
            let text: NSAttributedString? = group.isContainer ? nil : nil // scroll mode renders text via CTFrameDraw
            return CoreTextPaginator.RenderedBlockRenderable(
                rect: group.rect,
                style: group.style,
                attributedText: text,
                sourceRanges: text != nil ? group.ranges : [],
                imageAttachment: imageAttachment
            )
        }
    }

    /// Extracts a block-image attachment from style + ranges (mirrors CoreTextPaginator.makeBlockImageAttachment).
    private static func chunkBlockImageAttachment(
        rect: CGRect,
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        ranges: [NSRange],
        attrStr: NSAttributedString
    ) -> CoreTextPaginator.RenderedAttachment? {
        guard let blockImage = style.blockImage, let image = blockImage.image else { return nil }

        let contentWidth = max(1, rect.width - blockImage.paddingLeft - blockImage.paddingRight)
        let drawWidth = min(blockImage.drawSize.width, contentWidth)
        let drawHeight = blockImage.drawSize.height
        let imgX: CGFloat
        switch blockImage.alignment {
        case .center: imgX = rect.minX + blockImage.paddingLeft + max(0, (contentWidth - drawWidth) / 2)
        case .right:  imgX = rect.minX + blockImage.paddingLeft + max(0, contentWidth - drawWidth)
        default:       imgX = rect.minX + blockImage.paddingLeft
        }
        let contentY = rect.minY + blockImage.paddingTop
        let contentH = max(1, rect.height - blockImage.paddingTop - blockImage.paddingBottom)
        let imgY = contentY + max(0, (contentH - drawHeight) / 2)

        var mediaAttachment: EPUBMediaAttachment?
        for range in ranges {
            let safeLocation = max(0, min(range.location, attrStr.length))
            guard safeLocation < attrStr.length else { continue }
            if let media = attrStr.attribute(
                HTMLAttributedStringBuilder.mediaAttachmentAttribute,
                at: safeLocation,
                effectiveRange: nil
            ) as? EPUBMediaAttachment {
                mediaAttachment = media
                break
            }
        }

        return CoreTextPaginator.RenderedAttachment(
            rect: CGRect(x: imgX, y: imgY, width: drawWidth, height: drawHeight),
            image: image,
            opacity: blockImage.opacity,
            sourceHref: blockImage.source.isEmpty ? nil : blockImage.source,
            alt: nil,
            linkHref: nil,
            mediaAttachment: mediaAttachment,
            originalSize: image.size
        )
    }

    // MARK: - Inline annotation extraction

    /// Extracts inline text annotations (span.small notes in vertical writing mode) from a chunk's CTFrame.
    /// Mirrors CoreTextPaginator.extractInlineAnnotations but operates on a single chunk frame.
    static func extractInlineAnnotations(
        frame: CTFrame,
        chunkSize: CGSize,
        attributedString: NSAttributedString
    ) -> [CoreTextPaginator.RenderedInlineAnnotation] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return [] }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)

        var result: [CoreTextPaginator.RenderedInlineAnnotation] = []

        for (lineIdx, line) in lines.enumerated() {
            let lineOrigin = origins[lineIdx]
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                guard attrs[HTMLAttributedStringBuilder.inlineAnnotationRunAttribute] != nil,
                      let delegate = attrs[delegateKey]
                else { continue }

                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                guard let annotation = info as? InlineAnnotationRunInfo else { continue }

                let runLocation = CTRunGetStringRange(run).location
                let textAdvance = CTLineGetOffsetForStringIndex(line, runLocation, nil)
                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
                let typographicCenterX = lineOrigin.x + (lineAscent - lineDescent) / 2

                let uiRect = CGRect(
                    x: typographicCenterX - (annotation.drawWidth / 2),
                    y: chunkSize.height - lineOrigin.y + textAdvance,
                    width: annotation.drawWidth,
                    height: annotation.drawHeight
                )

                result.append(CoreTextPaginator.RenderedInlineAnnotation(
                    uiRect: uiRect,
                    attributedString: annotation.attributedString
                ))
            }
        }

        return result
    }
}

/// Internal types used by the slicer's block extraction logic (must match CoreTextPaginator.SpanGroup semantics).
private struct SpanGroup {
    let blockID: String
    let style: HTMLAttributedStringBuilder.BlockRenderStyle
    var ranges: [NSRange]
    var rect: CGRect = .null
    let isContainer: Bool
}
