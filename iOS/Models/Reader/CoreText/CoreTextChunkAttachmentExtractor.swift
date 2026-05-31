import CoreText
import UIKit

/// Extracts image attachment rects (UIKit coordinates: origin top-left, y downward) from a chunk's CTFrame.
/// chunkSize is the chunk's path size (width × height); the coordinate system matches the cell's drawView bounds.
/// Mirrors CoreTextPaginator.extractImages but operates on a single chunk frame.
enum CoreTextChunkAttachmentExtractor {

    static func extract(
        frame: CTFrame,
        chunkSize: CGSize,
        attributedString: NSAttributedString,
        rangeInChapter: CFRange,
        writingMode: ReaderWritingMode = .horizontal
    ) -> [CoreTextPaginator.RenderedAttachment] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let isVertical = writingMode.isVertical

        var result: [CoreTextPaginator.RenderedAttachment] = []

        for (lineIdx, line) in lines.enumerated() {
            let lineOrigin = origins[lineIdx]
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                guard let delegate = attrs[delegateKey] else { continue }
                guard attrs[HTMLAttributedStringBuilder.spacerRunAttribute] == nil else { continue }
                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                guard let img = info.image else { continue }

                let runLocation = CTRunGetStringRange(run).location
                let paragraphStyle = attributedString.attribute(
                    .paragraphStyle,
                    at: max(0, min(attributedString.length - 1, runLocation)),
                    effectiveRange: nil
                ) as? NSParagraphStyle

                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)

                let rect: CGRect
                switch info.displayMode {
                case .inline:
                    if isVertical {
                        let textAdvance = CTLineGetOffsetForStringIndex(line, runLocation, nil)
                        let lineTypographicCenterX = lineOrigin.x + (lineAscent - lineDescent) / 2
                        let uiY = chunkSize.height - lineOrigin.y + textAdvance
                        rect = CGRect(
                            x: lineTypographicCenterX - (info.drawWidth / 2),
                            y: uiY,
                            width: info.drawWidth,
                            height: info.drawHeight
                        )
                    } else {
                        let flush: CGFloat
                        switch paragraphStyle?.alignment ?? .natural {
                        case .center: flush = 0.5
                        case .right:  flush = 1
                        default:      flush = 0
                        }
                        let penOffset = CGFloat(
                            CTLineGetPenOffsetForFlush(line, Double(flush), Double(chunkSize.width))
                        )
                        let textAdvance = CTLineGetOffsetForStringIndex(line, runLocation, nil)
                        let baselineY = lineOrigin.y
                        let lineHeight = lineAscent + lineDescent
                        let lineBottom = baselineY - lineDescent
                        let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
                        let uiY = chunkSize.height - centeredBottom - info.drawHeight
                        rect = CGRect(
                            x: lineOrigin.x + penOffset + textAdvance + info.paddingLeft,
                            y: uiY,
                            width: info.drawWidth,
                            height: info.drawHeight
                        )
                    }
                case .block:
                    if isVertical {
                        let textAdvance = CTLineGetOffsetForStringIndex(line, runLocation, nil)
                        let lineTypographicCenterX = lineOrigin.x + (lineAscent - lineDescent) / 2
                        let uiY = chunkSize.height - lineOrigin.y + textAdvance
                        rect = CGRect(
                            x: lineTypographicCenterX - (info.drawWidth / 2),
                            y: uiY,
                            width: info.drawWidth,
                            height: info.drawHeight
                        )
                    } else {
                        let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
                        let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
                        let boxWidth = max(1, chunkSize.width - leftInset - rightInset)
                        let occupiedWidth = min(boxWidth, info.width)
                        let alignedX: CGFloat
                        switch paragraphStyle?.alignment ?? .left {
                        case .center: alignedX = leftInset + max(0, (boxWidth - occupiedWidth) / 2)
                        case .right:  alignedX = leftInset + max(0, boxWidth - occupiedWidth)
                        default:      alignedX = leftInset
                        }
                        let baselineY = lineOrigin.y
                        let lineHeight = lineAscent + lineDescent
                        let lineBottom = baselineY - lineDescent
                        let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
                        let uiY = chunkSize.height - centeredBottom - info.drawHeight
                        rect = CGRect(
                            x: alignedX + info.paddingLeft,
                            y: uiY,
                            width: info.drawWidth,
                            height: info.drawHeight
                        )
                    }
                }

                let linkHref = (attrs[HTMLAttributedStringBuilder.internalLinkAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
                #if DEBUG
                if let linkHref, ReaderHTMLUtilities.reviewTarget(fromHref: linkHref) != nil {
                    print("[段評Debug] chunk.inlineReview rect=\(rect) draw=\(info.drawWidth)x\(info.drawHeight) image=\(img.size) rangeStart=\(rangeInChapter.location) hrefHead=\(linkHref.prefix(80))")
                }
                #endif

                result.append(CoreTextPaginator.RenderedAttachment(
                    rect: rect,
                    image: img,
                    opacity: info.opacity,
                    sourceHref: info.source.isEmpty ? nil : info.source,
                    alt: info.alt,
                    linkHref: linkHref,
                    originalSize: img.size
                ))
            }
        }

        return result
    }
}
