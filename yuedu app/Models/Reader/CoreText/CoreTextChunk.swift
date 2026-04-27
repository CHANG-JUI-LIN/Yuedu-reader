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
}
