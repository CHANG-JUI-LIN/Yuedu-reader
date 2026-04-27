import CoreText
import UIKit

/// 從一個 chunk 的 CTFrame 中抽取圖片附件 rect（UIKit 座標：原點左上、y 向下）。
/// chunkSize 是 chunk 的 path 大小 (width × height)；座標系與 cell 的 drawView bounds 相同。
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
                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                guard let img = info.image else { continue }

                // run 在原 attributedString 的位置；用該位置查 paragraphStyle
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

                // CoreText baseline Y（chunk 的 path 原點是左下，向上為正）
                let baselineY = lineOrigin.y
                let lineHeight = lineAscent + lineDescent
                let lineBottom = baselineY - lineDescent
                let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
                // 轉到 UIKit（左上原點，向下為正）
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
                    opacity: info.opacity
                ))
            }
        }

        _ = rangeInChapter // 預留：日後若需要章節定位可用
        return result
    }
}
