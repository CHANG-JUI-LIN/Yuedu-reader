import CoreText
import UIKit

final class CoreTextPaginator {

    // MARK: - ChapterLayout

    struct ChapterLayout {
        let spineIndex: Int
        let attributedString: NSAttributedString
        /// 預建的 CTFramesetter，draw(_ rect:) 直接使用，不重建
        let framesetter: CTFramesetter
        /// 每頁對應的 UTF-16 字符範圍（總長度 == attributedString.length）
        let pageRanges: [CFRange]
        /// pageIndex → 圖片在 UIView 座標系（左上角原點）的 CGRect
        let imageRects: [Int: CGRect]
        /// pageIndex → 嵌入圖片（來自 CTRunDelegate 的 ImageRunInfo）
        let pageImages: [Int: UIImage]
        let renderSize: CGSize
        let fontSize: CGFloat
    }

    enum InvalidationReason {
        case fontSizeChanged  // 清除全部快取
        case viewSizeChanged  // 清除全部快取
        case themeChanged     // 不清快取，只重繪
    }

    private var cache: [CacheKey: ChapterLayout] = [:]
    private struct CacheKey: Hashable {
        let spineIndex: Int
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
    }

    // MARK: - 公開 API

    func paginate(
        spineIndex: Int,
        attrStr: NSAttributedString,
        renderSize: CGSize,
        fontSize: CGFloat
    ) async -> ChapterLayout {
        let key = CacheKey(spineIndex: spineIndex,
                           width: renderSize.width,
                           height: renderSize.height,
                           fontSize: fontSize)
        if let cached = cache[key] { return cached }

        let layout = await Task.detached(priority: .userInitiated) {
            Self.computeLayout(spineIndex: spineIndex,
                               attrStr: attrStr,
                               renderSize: renderSize,
                               fontSize: fontSize)
        }.value

        cache[key] = layout
        return layout
    }

    func invalidate(reason: InvalidationReason) {
        switch reason {
        case .fontSizeChanged, .viewSizeChanged:
            cache.removeAll()
        case .themeChanged:
            break
        }
    }

    // MARK: - 核心分頁算法（static，可在任意執行緒執行）

    private static func computeLayout(
        spineIndex: Int,
        attrStr: NSAttributedString,
        renderSize: CGSize,
        fontSize: CGFloat
    ) -> ChapterLayout {
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let pagePath = CGPath(rect: CGRect(origin: .zero, size: renderSize), transform: nil)

        var pageRanges: [CFRange] = []
        var currentLocation = 0

        while currentLocation < attrStr.length {
            let searchRange = CFRangeMake(currentLocation, 0)
            let frame = CTFramesetterCreateFrame(framesetter, searchRange, pagePath, nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)

            // 防止無限迴圈：若 visibleRange.length == 0，強制前進一個字符
            let advance = visibleRange.length > 0 ? visibleRange.length : 1
            pageRanges.append(CFRangeMake(currentLocation, advance))
            currentLocation += advance
        }

        let (imageRects, pageImages) = extractImages(
            framesetter: framesetter,
            pageRanges: pageRanges,
            renderSize: renderSize,
            attrStr: attrStr
        )

        return ChapterLayout(
            spineIndex: spineIndex,
            attributedString: attrStr,
            framesetter: framesetter,
            pageRanges: pageRanges,
            imageRects: imageRects,
            pageImages: pageImages,
            renderSize: renderSize,
            fontSize: fontSize
        )
    }

    private static func extractImages(
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        renderSize: CGSize,
        attrStr: NSAttributedString
    ) -> (rects: [Int: CGRect], images: [Int: UIImage]) {
        let pagePath = CGPath(rect: CGRect(origin: .zero, size: renderSize), transform: nil)
        var rects: [Int: CGRect] = [:]
        var images: [Int: UIImage] = [:]
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)

        for (pageIdx, range) in pageRanges.enumerated() {
            let frame = CTFramesetterCreateFrame(framesetter, range, pagePath, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

            for (lineIdx, line) in lines.enumerated() {
                let lineOrigin = origins[lineIdx]
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                for run in runs {
                    let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                    guard let delegate = attrs[delegateKey] else { continue }
                    // CTRunDelegate is a CoreFoundation type; unconditional cast is correct
                    let ctDelegate = delegate as! CTRunDelegate
                    let ptr = CTRunDelegateGetRefCon(ctDelegate)
                    let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()

                    let xOffset = CTLineGetOffsetForStringIndex(
                        line,
                        CTRunGetStringRange(run).location,
                        nil
                    )
                    let ctY = lineOrigin.y - info.height
                    let uiY = renderSize.height - ctY - info.height
                    let runBounds = CGRect(x: lineOrigin.x + xOffset,
                                          y: uiY,
                                          width: info.width,
                                          height: info.height)

                    rects[pageIdx] = runBounds
                    if let img = info.image {
                        images[pageIdx] = img
                    }
                }
            }
        }
        return (rects, images)
    }
}

// MARK: - Binary Search Extension

extension CoreTextPaginator.ChapterLayout {
    /// 給定 UTF-16 charOffset，二分搜尋對應的頁碼（O(log n)）
    func pageIndex(for charOffset: Int) -> Int {
        guard !pageRanges.isEmpty else { return 0 }
        var lo = 0
        var hi = pageRanges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pageRanges[mid].location <= charOffset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}
