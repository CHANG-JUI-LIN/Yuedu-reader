import CoreText
import Foundation
import UIKit

/// Slices a chapter's NSAttributedString into multiple chunks of approximately heightCap height each.
/// Pure function, safe to run on background threads.
enum CoreTextChunkSlicer {
    /// Default max height per chunk: ~3 screen heights, balancing slicing cost and memory
    static let defaultHeightCap: CGFloat = 2000

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
            let actualRange = CFRange(location: offset, length: min(consumeLen, totalLen - offset))
            var actualHeight = ceil(max(suggested.height, 1))

            // Ensure chunk height accommodates block images (drawHeight) within the range
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

    /// Scans the specified range for block images with CTRunDelegate and returns the maximum drawHeight.
    /// Ensures the chunk path height is large enough to contain the entire image (CoreText measurement may be slightly smaller than drawHeight).
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
