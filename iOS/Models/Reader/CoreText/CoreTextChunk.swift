import CoreText
import Foundation
import UIKit

/// 一塊已切片的 CoreText 內容，對應 UICollectionView 的一個 cell。
/// `frame` 為 nil 代表已被驅逐，可從 `framesetter` + `charRange` 重建。
final class CoreTextChunk {
    let chapterIndex: Int
    /// 在該章 attributedString 中的 character range（UTF-16）
    let charRange: CFRange
    let height: CGFloat
    let width: CGFloat
    /// 共享於同一章所有 chunk，用來在 evict 後重建 frame
    let framesetter: CTFramesetter
    /// 整章 attributedString，drawLines 需要查屬性（Phase 1 直接交給 CTFrameDraw 渲染，仍保留以便日後擴充）
    let attributedString: NSAttributedString

    private(set) var frame: CTFrame?
    /// 圖片附件位置（UIKit 座標，相對 chunk 左上原點）。slice 時計算一次後快取。
    private(set) var attachments: [CoreTextPaginator.RenderedAttachment] = []

    /// 是否為「整塊單圖」chunk（封面 / 整頁插圖）。為 true 時跳過 CTFrame 渲染，只畫 attachments。
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

    // MARK: - 選取（hit-test / rect 計算）

    /// 把 cell 內的 UIKit 座標點轉成「章節層級」字元 index（含 chunk.charRange.location 起算的全章 index）
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

    /// 把章節範圍交集到本 chunk 的字元範圍，產出 cell-local（UIKit 座標）的反白矩形
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
