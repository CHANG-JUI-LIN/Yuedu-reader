import CoreText
import UIKit

final class CoreTextPaginator {

    enum PageKind {
        case text
        case image
    }

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
        let pageKinds: [PageKind]
        let anchorOffsets: [String: Int]
        let renderSize: CGSize
        let fontSize: CGFloat
        /// 排版時使用的四邊邊距（UIEdgeInsets；CoreText path 已按此偏移）
        let contentInsets: UIEdgeInsets
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
        let marginH: CGFloat
        let marginV: CGFloat
    }

    // MARK: - 公開 API

    func paginate(
        spineIndex: Int,
        attrStr: NSAttributedString,
        imagePage: HTMLAttributedStringBuilder.ImagePage? = nil,
        anchorOffsets: [String: Int] = [:],
        renderSize: CGSize,
        fontSize: CGFloat,
        contentInsets: UIEdgeInsets = .zero
    ) async -> ChapterLayout {
        let key = CacheKey(spineIndex: spineIndex,
                           width: renderSize.width,
                           height: renderSize.height,
                           fontSize: fontSize,
                           marginH: contentInsets.left,
                           marginV: contentInsets.top)
        if let cached = cache[key] { return cached }

        let layout = await Task.detached(priority: .userInitiated) {
            Self.computeLayout(spineIndex: spineIndex,
                               attrStr: attrStr,
                               imagePage: imagePage,
                               anchorOffsets: anchorOffsets,
                               renderSize: renderSize,
                               fontSize: fontSize,
                               contentInsets: contentInsets)
        }.value

        cache[key] = layout
        return layout
    }

    @MainActor
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
        imagePage: HTMLAttributedStringBuilder.ImagePage?,
        anchorOffsets: [String: Int],
        renderSize: CGSize,
        fontSize: CGFloat,
        contentInsets: UIEdgeInsets
    ) -> ChapterLayout {
        // 有效內容區域（UIKit 座標：左上角原點）
        let contentRect = CGRect(
            x: contentInsets.left,
            y: contentInsets.top,
            width: max(1, renderSize.width - contentInsets.left - contentInsets.right),
            height: max(1, renderSize.height - contentInsets.top - contentInsets.bottom)
        )
        // CoreText 座標（y 從底部向上）：y = bottom inset
        let contentPathRect = CGRect(
            x: contentInsets.left,
            y: contentInsets.bottom,
            width: contentRect.width,
            height: contentRect.height
        )

        if let imagePage {
            let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
            let imageRect = aspectFitRect(
                for: imagePage.image?.size ?? contentRect.size,
                in: contentRect
            )
            return ChapterLayout(
                spineIndex: spineIndex,
                attributedString: attrStr,
                framesetter: framesetter,
                pageRanges: [CFRangeMake(0, max(attrStr.length, 1))],
                imageRects: [0: imageRect],
                pageImages: imagePage.image.map { [0: $0] } ?? [:],
                pageKinds: [.image],
                anchorOffsets: anchorOffsets,
                renderSize: renderSize,
                fontSize: fontSize,
                contentInsets: contentInsets
            )
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let pagePath = CGPath(rect: contentPathRect, transform: nil)

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

        applyOrphanControl(
            framesetter: framesetter,
            pageRanges: &pageRanges,
            attrStr: attrStr,
            contentPathRect: contentPathRect
        )

        let (imageRects, pageImages, pageKinds) = extractImages(
            framesetter: framesetter,
            pageRanges: pageRanges,
            renderSize: renderSize,
            contentPathRect: contentPathRect,
            attrStr: attrStr
        )

        return ChapterLayout(
            spineIndex: spineIndex,
            attributedString: attrStr,
            framesetter: framesetter,
            pageRanges: pageRanges,
            imageRects: imageRects,
            pageImages: pageImages,
            pageKinds: pageKinds,
            anchorOffsets: anchorOffsets,
            renderSize: renderSize,
            fontSize: fontSize,
            contentInsets: contentInsets
        )
    }

    /// 孤行控制：
    /// - Orphan：上一頁末行是段落首行 → 移到下一頁
    /// - Widow：下一頁首行是段落末行 → 把上一頁末行也移到下一頁（確保 ≥2 行）
    private static func applyOrphanControl(
        framesetter: CTFramesetter,
        pageRanges: inout [CFRange],
        attrStr: NSAttributedString,
        contentPathRect: CGRect
    ) {
        guard pageRanges.count > 1 else { return }
        let nsString = attrStr.string as NSString
        let stringLength = attrStr.length
        let pagePath = CGPath(rect: contentPathRect, transform: nil)

        // Pass 1: Orphan — 上一頁末行是段落首行
        var i = 0
        while i < pageRanges.count - 1 {
            let frame = CTFramesetterCreateFrame(framesetter, pageRanges[i], pagePath, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard lines.count >= 2, let lastLine = lines.last else { i += 1; continue }
            let lastRange = CTLineGetStringRange(lastLine)
            let isOrphan: Bool
            if lastRange.location == 0 {
                isOrphan = false
            } else {
                let ch = nsString.character(at: lastRange.location - 1)
                isOrphan = ch == 0x000A || ch == 0x2028 || ch == 0x2029
            }
            if isOrphan {
                let newLen = lastRange.location - pageRanges[i].location
                if newLen > 0 {
                    let nextEnd = pageRanges[i + 1].location + pageRanges[i + 1].length
                    pageRanges[i] = CFRangeMake(pageRanges[i].location, newLen)
                    pageRanges[i + 1] = CFRangeMake(lastRange.location, nextEnd - lastRange.location)
                }
            }
            i += 1
        }

        // Pass 2: Widow — 下一頁首行是段落末行（且該頁有 ≥2 行）
        for j in 1..<pageRanges.count {
            guard pageRanges[j].length > 0 else { continue }
            let frame = CTFramesetterCreateFrame(framesetter, pageRanges[j], pagePath, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard lines.count >= 2 else { continue }
            let firstRange = CTLineGetStringRange(lines[0])
            let checkIdx = firstRange.location + firstRange.length
            let isWidow = checkIdx >= stringLength
                || nsString.character(at: checkIdx) == 0x000A
                || nsString.character(at: checkIdx) == 0x2028
                || nsString.character(at: checkIdx) == 0x2029
            guard isWidow else { continue }
            // 把上一頁末行移到這頁
            let prevFrame = CTFramesetterCreateFrame(framesetter, pageRanges[j - 1], pagePath, nil)
            let prevLines = CTFrameGetLines(prevFrame) as! [CTLine]
            guard prevLines.count >= 2, let prevLast = prevLines.last else { continue }
            let prevLastRange = CTLineGetStringRange(prevLast)
            let newPrevLen = prevLastRange.location - pageRanges[j - 1].location
            guard newPrevLen > 0 else { continue }
            let newCurrEnd = pageRanges[j].location + pageRanges[j].length
            pageRanges[j - 1] = CFRangeMake(pageRanges[j - 1].location, newPrevLen)
            pageRanges[j] = CFRangeMake(prevLastRange.location, newCurrEnd - prevLastRange.location)
        }
    }

    private static func extractImages(
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        renderSize: CGSize,
        contentPathRect: CGRect,
        attrStr: NSAttributedString
    ) -> (rects: [Int: CGRect], images: [Int: UIImage], kinds: [PageKind]) {
        let pagePath = CGPath(rect: contentPathRect, transform: nil)
        var rects: [Int: CGRect] = [:]
        var images: [Int: UIImage] = [:]
        var kinds = Array(repeating: PageKind.text, count: pageRanges.count)
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
                    let ctY = contentPathRect.origin.y + lineOrigin.y - info.height
                    let uiY = renderSize.height - ctY - info.height
                    let runBounds = CGRect(x: contentPathRect.origin.x + lineOrigin.x + xOffset,
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

        let visibleContent = attrStr.string.unicodeScalars.filter { scalar in
            scalar != "\u{FFFC}" && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        if pageRanges.count == 1,
           visibleContent.isEmpty,
           images.count == 1,
           let image = images[0] {
            // 將 contentPathRect（CoreText 座標）轉換為 UIKit 座標的內容區域
            let uiContentRect = CGRect(
                x: contentPathRect.origin.x,
                y: renderSize.height - contentPathRect.maxY,
                width: contentPathRect.width,
                height: contentPathRect.height
            )
            rects[0] = aspectFitRect(for: image.size, in: uiContentRect)
            kinds[0] = .image
        }

        return (rects, images, kinds)
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
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
