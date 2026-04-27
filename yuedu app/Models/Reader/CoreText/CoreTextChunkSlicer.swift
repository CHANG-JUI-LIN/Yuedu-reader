import CoreText
import Foundation
import UIKit

/// 把整章 NSAttributedString 切成多個 ~heightCap 高的 chunk。
/// 純函式，可在背景執行緒跑。
enum CoreTextChunkSlicer {
    /// 預設每塊高度上限：約 3 個螢幕，平衡切片成本與記憶體
    static let defaultHeightCap: CGFloat = 2000

    /// 切片結果
    struct Output {
        let chunks: [CoreTextChunk]
        let framesetter: CTFramesetter
        let attributedString: NSAttributedString
    }

    static func slice(
        attributedString attrStr: NSAttributedString,
        chapterIndex: Int,
        contentWidth: CGFloat,
        heightCap: CGFloat = defaultHeightCap
    ) -> Output {
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr as CFAttributedString)
        let totalLen = attrStr.length
        guard contentWidth > 0, totalLen > 0 else {
            return Output(chunks: [], framesetter: framesetter, attributedString: attrStr)
        }

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

            // 單一元素超過 heightCap（典型：封面圖、巨幅插圖）→ 不限高重抓
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

            // 防呆：CoreText 偶爾會回 length 0；強制至少推進 1 字以避免無限迴圈
            let consumeLen = max(fitRange.length, 1)
            let actualRange = CFRange(location: offset, length: min(consumeLen, totalLen - offset))
            var actualHeight = ceil(max(suggested.height, 1))

            // 確保 chunk 高度容得下其中的 block 圖片（drawHeight）
            actualHeight = max(actualHeight, blockImageHeight(in: attrStr, range: actualRange))

            let path = CGPath(
                rect: CGRect(x: 0, y: 0, width: contentWidth, height: actualHeight),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(framesetter, actualRange, path, nil)

            chunks.append(CoreTextChunk(
                chapterIndex: chapterIndex,
                charRange: actualRange,
                size: CGSize(width: contentWidth, height: actualHeight),
                framesetter: framesetter,
                attributedString: attrStr,
                frame: frame
            ))

            offset = actualRange.location + actualRange.length
        }

        return Output(chunks: chunks, framesetter: framesetter, attributedString: attrStr)
    }

    /// 掃描指定 range 內含 CTRunDelegate 的 block 圖片，回傳最大 drawHeight。
    /// 用於確保 chunk path 高度足夠容納整張圖（CoreText 量度可能略小於 drawHeight）。
    private static func blockImageHeight(in attrStr: NSAttributedString, range: CFRange) -> CGFloat {
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location >= 0,
              nsRange.location + nsRange.length <= attrStr.length else { return 0 }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var maxHeight: CGFloat = 0
        attrStr.enumerateAttribute(delegateKey, in: nsRange, options: []) { value, _, _ in
            guard let v = value else { return }
            let ctDelegate = v as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(ctDelegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            if info.displayMode == .block {
                maxHeight = max(maxHeight, info.drawHeight)
            }
        }
        return maxHeight
    }
}
