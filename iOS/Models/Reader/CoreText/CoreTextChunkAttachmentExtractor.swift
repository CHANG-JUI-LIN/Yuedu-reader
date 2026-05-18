import CoreText
import UIKit

/// Extracts image attachment rects (UIKit coordinates: origin top-left, y downward) from a chunk's CTFrame.
/// chunkSize is the chunk's path size (width × height); the coordinate system matches the cell's drawView bounds.
enum CoreTextChunkAttachmentExtractor {

    static func extract(
        frame: CTFrame,
        chunkSize: CGSize,
        attributedString: NSAttributedString,
        rangeInChapter: CFRange
    ) -> [CoreTextPaginator.RenderedAttachment] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)

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

                // Use the run's position in the original attributedString to look up paragraphStyle
                let runStart = CTRunGetStringRange(run).location
                let lookupIdx = max(0, min(attributedString.length - 1, runStart))
                let paragraphStyle = attributedString.attribute(
                    .paragraphStyle,
                    at: lookupIdx,
                    effectiveRange: nil
                ) as? NSParagraphStyle

                let flush: CGFloat
                switch paragraphStyle?.alignment ?? .natural {
                case .center: flush = 0.5
                case .right:  flush = 1
                default:      flush = 0
                }
                let penOffset = CGFloat(
                    CTLineGetPenOffsetForFlush(line, Double(flush), Double(chunkSize.width))
                )

                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)

                // CoreText baseline Y (chunk path origin is bottom-left, positive upward)
                let baselineY = lineOrigin.y
                let lineHeight = lineAscent + lineDescent
                let lineBottom = baselineY - lineDescent
                let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
                // Convert to UIKit (origin top-left, positive downward)
                let uiY = chunkSize.height - centeredBottom - info.drawHeight

                let rect: CGRect
                switch info.displayMode {
                case .inline:
                    let xOffset = CTLineGetOffsetForStringIndex(line, runStart, nil)
                    rect = CGRect(
                        x: lineOrigin.x + penOffset + xOffset + info.paddingLeft,
                        y: uiY,
                        width: info.drawWidth,
                        height: info.drawHeight
                    )
                case .block:
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
                    rect = CGRect(
                        x: alignedX + info.paddingLeft,
                        y: uiY,
                        width: info.drawWidth,
                        height: info.drawHeight
                    )
                }

                result.append(CoreTextPaginator.RenderedAttachment(
                    rect: rect,
                    image: img,
                    opacity: info.opacity,
                    sourceHref: info.source.isEmpty ? nil : info.source,
                    alt: info.alt,
                    linkHref: (attrs[HTMLAttributedStringBuilder.internalLinkAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    originalSize: img.size
                ))
            }
        }

        _ = rangeInChapter // Reserved for future chapter-level positioning if needed
        return result
    }
}
