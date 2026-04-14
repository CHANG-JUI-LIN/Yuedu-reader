import CoreText
import UIKit

final class CoreTextPaginator {

    struct RenderedAttachment {
        let rect: CGRect
        let image: UIImage
        let opacity: CGFloat
    }

    struct RenderedBlockRenderable {
        let rect: CGRect
        let style: HTMLAttributedStringBuilder.BlockRenderStyle
        let attributedText: NSAttributedString?
        /// String ranges whose text is drawn by drawBlockRenderableText (not by CTFrame drawLines).
        /// Non-empty only when attributedText != nil (usesExplicitGeometry = true).
        let sourceRanges: [NSRange]
    }

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
        /// pageIndex → 行內附件
        let inlineAttachments: [Int: [RenderedAttachment]]
        /// pageIndex → 區塊級附件／裝飾圖片
        let blockAttachments: [Int: [RenderedAttachment]]
        /// pageIndex → 區塊級 renderables（背景／邊框／裝飾圖片）
        let blockRenderables: [Int: [RenderedBlockRenderable]]
        let pageKinds: [PageKind]
        let pageBackgroundImage: UIImage?
        let anchorOffsets: [String: Int]
        let renderSize: CGSize
        let fontSize: CGFloat
        /// 排版時使用的四邊邊距（UIEdgeInsets；CoreText path 已按此偏移）
        let contentInsets: UIEdgeInsets

        /// 僅更新文字顏色，不重新分頁（顏色不影響換行）。
        /// CSS 明確指定前景色（帶 cssSpecifiedForegroundColorAttribute 標記）的 range 保留原色；
        /// 帶 blockBackgroundColorAttribute 的 range 不覆蓋 .backgroundColor，避免遮蔽區塊背景。
        func withUpdatedColors(textColor: UIColor, backgroundColor: UIColor) -> ChapterLayout {
            guard attributedString.length > 0 else { return self }
            let updated = NSMutableAttributedString(attributedString: attributedString)
            let fullRange = NSRange(location: 0, length: updated.length)

            // ── 前景色：先全域套用主題色，再還原 CSS 指定色 ──
            updated.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            updated.enumerateAttribute(
                HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute,
                in: fullRange,
                options: []
            ) { value, effectiveRange, _ in
                if let cssColor = value as? UIColor {
                    updated.addAttribute(.foregroundColor, value: cssColor, range: effectiveRange)
                }
            }

            // ── 背景色：先全域套用主題色，再移除有 CSS 區塊背景的 range ──
            updated.addAttribute(.backgroundColor, value: backgroundColor, range: fullRange)
            updated.enumerateAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                in: fullRange,
                options: []
            ) { value, effectiveRange, _ in
                if value != nil {
                    updated.removeAttribute(.backgroundColor, range: effectiveRange)
                }
            }

            let newFramesetter = CTFramesetterCreateWithAttributedString(updated)
            return ChapterLayout(
                spineIndex: spineIndex,
                attributedString: updated,
                framesetter: newFramesetter,
                pageRanges: pageRanges,
                inlineAttachments: inlineAttachments,
                blockAttachments: blockAttachments,
                blockRenderables: blockRenderables,
                pageKinds: pageKinds,
                pageBackgroundImage: pageBackgroundImage,
                anchorOffsets: anchorOffsets,
                renderSize: renderSize,
                fontSize: fontSize,
                contentInsets: contentInsets
            )
        }
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
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let letterSpacing: CGFloat
    }

    // MARK: - 公開 API

    func paginate(
        spineIndex: Int,
        attrStr: NSAttributedString,
        imagePage: HTMLAttributedStringBuilder.ImagePage? = nil,
        pageBackgroundImage: UIImage? = nil,
        anchorOffsets: [String: Int] = [:],
        renderSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat = 0,
        paragraphSpacing: CGFloat = 0,
        letterSpacing: CGFloat = 0,
        contentInsets: UIEdgeInsets = .zero
    ) async -> ChapterLayout {
        let key = CacheKey(spineIndex: spineIndex,
                           width: renderSize.width,
                           height: renderSize.height,
                           fontSize: fontSize,
                           marginH: contentInsets.left,
                           marginV: contentInsets.top,
                           lineSpacing: lineSpacing,
                           paragraphSpacing: paragraphSpacing,
                           letterSpacing: letterSpacing)
        if let cached = cache[key] { return cached }

        let layout = await Task.detached(priority: .userInitiated) {
            Self.computeLayout(spineIndex: spineIndex,
                               attrStr: attrStr,
                               imagePage: imagePage,
                               pageBackgroundImage: pageBackgroundImage,
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
        pageBackgroundImage: UIImage?,
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
                inlineAttachments: [:],
                blockAttachments: imagePage.image.map { [0: [RenderedAttachment(rect: imageRect, image: $0, opacity: 1)]] } ?? [:],
                blockRenderables: [:],
                pageKinds: [.image],
                pageBackgroundImage: nil,
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

        let (inlineAttachments, blockAttachments, pageKinds) = extractImages(
            framesetter: framesetter,
            pageRanges: pageRanges,
            renderSize: renderSize,
            contentPathRect: contentPathRect,
            attrStr: attrStr
        )
        let blockRenderables = extractBlockRenderables(
            framesetter: framesetter,
            pageRanges: pageRanges,
            contentPathRect: contentPathRect,
            renderSize: renderSize,
            attrStr: attrStr
        )

        return ChapterLayout(
            spineIndex: spineIndex,
            attributedString: attrStr,
            framesetter: framesetter,
            pageRanges: pageRanges,
            inlineAttachments: inlineAttachments,
            blockAttachments: blockAttachments,
            blockRenderables: blockRenderables,
            pageKinds: pageKinds,
            pageBackgroundImage: pageBackgroundImage,
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
    ) -> (inline: [Int: [RenderedAttachment]], block: [Int: [RenderedAttachment]], kinds: [PageKind]) {
        let pagePath = CGPath(rect: contentPathRect, transform: nil)
        var inlineAttachments: [Int: [RenderedAttachment]] = [:]
        var blockAttachments: [Int: [RenderedAttachment]] = [:]
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

                    let paragraphStyle = attrStr.attribute(
                        .paragraphStyle,
                        at: max(0, CTRunGetStringRange(run).location),
                        effectiveRange: nil
                    ) as? NSParagraphStyle
                    let flush: CGFloat
                    switch paragraphStyle?.alignment ?? .natural {
                    case .center:
                        flush = 0.5
                    case .right:
                        flush = 1
                    default:
                        flush = 0
                    }
                    let penOffset = CGFloat(
                        CTLineGetPenOffsetForFlush(line, Double(flush), Double(contentPathRect.width))
                    )

                    var runAscent: CGFloat = 0
                    var runDescent: CGFloat = 0
                    _ = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &runAscent, &runDescent, nil)
                    var lineAscent: CGFloat = 0
                    var lineDescent: CGFloat = 0
                    _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
                    let baselineY = contentPathRect.origin.y + lineOrigin.y
                    let lineHeight = lineAscent + lineDescent
                    let lineBottom = baselineY - lineDescent
                    let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
                    let uiY = renderSize.height - centeredBottom - info.drawHeight
                    if let img = info.image {
                        let hasBlockRenderable = attrs[HTMLAttributedStringBuilder.blockRenderStyleAttribute] != nil
                        let rect: CGRect
                        switch info.displayMode {
                        case .inline:
                            let xOffset = CTLineGetOffsetForStringIndex(
                                line,
                                CTRunGetStringRange(run).location,
                                nil
                            )
                            rect = CGRect(
                                x: contentPathRect.origin.x + lineOrigin.x + penOffset + xOffset + info.paddingLeft,
                                y: uiY,
                                width: info.drawWidth,
                                height: info.drawHeight
                            )
                        case .block:
                            let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
                            let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
                            let boxWidth = max(1, contentPathRect.width - leftInset - rightInset)
                            let occupiedWidth = min(boxWidth, info.width)
                            let alignedX: CGFloat
                            switch paragraphStyle?.alignment ?? .left {
                            case .center:
                                alignedX = contentPathRect.origin.x + leftInset + max(0, (boxWidth - occupiedWidth) / 2)
                            case .right:
                                alignedX = contentPathRect.origin.x + leftInset + max(0, boxWidth - occupiedWidth)
                            default:
                                alignedX = contentPathRect.origin.x + leftInset
                            }
                            rect = CGRect(
                                x: alignedX + info.paddingLeft,
                                y: uiY,
                                width: info.drawWidth,
                                height: info.drawHeight
                            )
                        }

                        let attachment = RenderedAttachment(rect: rect, image: img, opacity: info.opacity)
                        switch info.displayMode {
                        case .inline:
                            inlineAttachments[pageIdx, default: []].append(attachment)
                        case .block:
                            if !hasBlockRenderable {
                                blockAttachments[pageIdx, default: []].append(attachment)
                            }
                        }
                    }
                }
            }
        }

        let visibleContent = attrStr.string.unicodeScalars.filter { scalar in
            scalar != "\u{FFFC}" && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        if pageRanges.count == 1,
           visibleContent.isEmpty,
           blockAttachments.count == 1,
           let attachment = blockAttachments[0]?.first {
            // 將 contentPathRect（CoreText 座標）轉換為 UIKit 座標的內容區域
            let uiContentRect = CGRect(
                x: contentPathRect.origin.x,
                y: renderSize.height - contentPathRect.maxY,
                width: contentPathRect.width,
                height: contentPathRect.height
            )
            let imageRect = aspectFitRect(for: attachment.image.size, in: uiContentRect)
            blockAttachments[0] = [RenderedAttachment(rect: imageRect, image: attachment.image, opacity: attachment.opacity)]
            kinds[0] = .image
        }

        return (inlineAttachments, blockAttachments, kinds)
    }

    private static func extractBlockRenderables(
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        contentPathRect: CGRect,
        renderSize: CGSize,
        attrStr: NSAttributedString
    ) -> [Int: [RenderedBlockRenderable]] {
        let pagePath = CGPath(rect: contentPathRect, transform: nil)
        var pageRenderables: [Int: [RenderedBlockRenderable]] = [:]

        for (pageIdx, range) in pageRanges.enumerated() {
            let frame = CTFramesetterCreateFrame(framesetter, range, pagePath, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard !lines.isEmpty else { continue }

            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

            struct DecorationGroup {
                let blockID: String
                let style: HTMLAttributedStringBuilder.BlockRenderStyle
                let ranges: [NSRange]
                var rect: CGRect
                var usesExplicitGeometry: Bool
                let isContainer: Bool
            }

            struct SpanGroup {
                let blockID: String
                let style: HTMLAttributedStringBuilder.BlockRenderStyle
                var ranges: [NSRange]
                let isContainer: Bool
            }

            var spanGroupsByID: [String: SpanGroup] = [:]
            let pageNSRange = NSRange(location: range.location, length: range.length)
            attrStr.enumerateAttribute(
                HTMLAttributedStringBuilder.blockRenderStyleAttribute,
                in: pageNSRange,
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

            // 容器層裝飾（父 div 的 border/background，跨越 block 子元素）
            attrStr.enumerateAttribute(
                HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
                in: pageNSRange,
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

            var groups: [DecorationGroup] = spanGroupsByID.values.map {
                DecorationGroup(
                    blockID: $0.blockID,
                    style: $0.style,
                    ranges: $0.ranges,
                    rect: .null,
                    usesExplicitGeometry: false,
                    isContainer: $0.isContainer
                )
            }
            guard !groups.isEmpty else { continue }

            for groupIndex in groups.indices {
                if let explicitRect = computeExplicitBlockRenderableRect(
                    style: groups[groupIndex].style,
                    ranges: groups[groupIndex].ranges,
                    attrStr: attrStr,
                    contentPathRect: contentPathRect,
                    renderSize: renderSize
                ) {
                    groups[groupIndex].rect = explicitRect
                    groups[groupIndex].usesExplicitGeometry = true
                }
            }

            for (lineIdx, line) in lines.enumerated() {
                let lineRange = CTLineGetStringRange(line)
                let lineStart = lineRange.location
                guard lineStart < attrStr.length else { continue }

                let lineNSRange = NSRange(location: lineRange.location, length: lineRange.length)

                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)

                let lineOrigin = origins[lineIdx]
                let adjustedOrigin = CGPoint(
                    x: lineOrigin.x + contentPathRect.minX,
                    y: lineOrigin.y + contentPathRect.minY
                )

                for groupIndex in groups.indices {
                    if groups[groupIndex].usesExplicitGeometry {
                        continue
                    }
                    let intersects = groups[groupIndex].ranges.contains { span in
                        NSIntersectionRange(span, lineNSRange).length > 0
                    }
                    guard intersects else { continue }

                    let attributeLocation = max(
                        lineStart,
                        groups[groupIndex].ranges
                            .compactMap { span -> Int? in
                                let intersection = NSIntersectionRange(span, lineNSRange)
                                return intersection.length > 0 ? intersection.location : nil
                            }
                            .min() ?? lineStart
                    )
                    guard let paragraphStyle = attrStr.attribute(
                        .paragraphStyle,
                        at: attributeLocation,
                        effectiveRange: nil
                    ) as? NSParagraphStyle else { continue }

                    let leftInset = min(paragraphStyle.headIndent, paragraphStyle.firstLineHeadIndent)
                    let rightInset = paragraphStyle.tailIndent < 0 ? -paragraphStyle.tailIndent : 0
                    let availableWidth = max(1, contentPathRect.width - leftInset - rightInset)
                    let preferredWidth = max(
                        1,
                        min(
                            availableWidth,
                            groups[groupIndex].style.blockImage.map { $0.drawSize.width + $0.paddingLeft + $0.paddingRight }
                                ?? groups[groupIndex].style.width
                                ?? availableWidth
                        )
                    )
                    let blockX: CGFloat
                    if groups[groupIndex].style.isHorizontallyCentered {
                        blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
                    } else {
                        switch groups[groupIndex].style.textAlign {
                        case .center:
                            blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
                        case .right:
                            blockX = contentPathRect.minX + leftInset + max(0, availableWidth - preferredWidth)
                        default:
                            blockX = contentPathRect.minX + leftInset
                        }
                    }
                    let lineHeight = max(paragraphStyle.minimumLineHeight, lineAscent + lineDescent)
                    let blockHeight = max(
                        lineHeight,
                        groups[groupIndex].style.blockImage?.drawSize.height ?? groups[groupIndex].style.height ?? 0
                    )
                    let inferredTopY = renderSize.height - (adjustedOrigin.y + lineAscent)
                    let uiY = inferredTopY
                    let rect = CGRect(
                        x: blockX,
                        y: uiY,
                        width: preferredWidth,
                        height: blockHeight
                    )

                    groups[groupIndex].rect = groups[groupIndex].rect.isNull
                        ? rect
                        : groups[groupIndex].rect.union(rect)
                }
            }

            let renderables = groups
                .filter { !$0.rect.isNull }
                .map { group -> RenderedBlockRenderable in
                    // 容器群組僅繪製裝飾（border/background），不接管文字渲染
                    let text: NSAttributedString? = group.isContainer ? nil : explicitRenderableText(
                        style: group.style,
                        ranges: group.ranges,
                        attrStr: attrStr,
                        explicitRect: group.rect
                    )
                    return RenderedBlockRenderable(
                        rect: group.rect,
                        style: group.style,
                        attributedText: text,
                        sourceRanges: text != nil ? group.ranges : []
                    )
                }
            if !renderables.isEmpty {
                pageRenderables[pageIdx] = renderables
            }
        }

        return pageRenderables
    }

    private static func computeExplicitBlockRenderableRect(
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        ranges: [NSRange],
        attrStr: NSAttributedString,
        contentPathRect: CGRect,
        renderSize: CGSize
    ) -> CGRect? {
        let mergedRange = mergeRanges(ranges)
        let mergedText: String
        if let mergedRange, mergedRange.location < attrStr.length {
            mergedText = (attrStr.string as NSString).substring(with: mergedRange)
        } else {
            mergedText = ""
        }
        let hasMeaningfulText = containsMeaningfulText(mergedText)
        let hasVisualDecoration =
            style.backgroundFillColor != nil
            || style.borderTopWidth > 0
            || style.borderBottomWidth > 0
            || style.blockImage != nil
        let hasExplicitGeometryHint =
            style.height != nil
            || style.visualOffsetBefore > 0
            || (style.width != nil && style.isHorizontallyCentered)
        let usesExplicitGeometry =
            hasVisualDecoration
            && hasExplicitGeometryHint
            && (hasMeaningfulText || style.blockImage == nil)
        guard usesExplicitGeometry else { return nil }

        guard let mergedRange,
              mergedRange.location < attrStr.length
        else {
            return nil
        }

        let paragraphStyle = attrStr.attribute(
            .paragraphStyle,
            at: mergedRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
        let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
        let availableWidth = max(1, contentPathRect.width - leftInset - rightInset)
        let preferredWidth = max(
            1,
            min(
                availableWidth,
                style.blockImage.map { $0.drawSize.width + $0.paddingLeft + $0.paddingRight }
                    ?? style.width
                    ?? availableWidth
            )
        )

        let blockX: CGFloat
        if style.isHorizontallyCentered {
            blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
        } else {
            switch style.textAlign {
            case .center:
                blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
            case .right:
                blockX = contentPathRect.minX + leftInset + max(0, availableWidth - preferredWidth)
            default:
                blockX = contentPathRect.minX + leftInset
            }
        }

        let constrainedWidth = max(1, preferredWidth - style.paddingLeft - style.paddingRight)
        let blockHeight: CGFloat
        if let blockImage = style.blockImage {
            blockHeight = max(blockImage.drawSize.height, style.height ?? 0)
        } else {
            let measured = measureHeight(
                for: attrStr.attributedSubstring(from: mergedRange),
                constrainedWidth: constrainedWidth
            )
            blockHeight = max(measured, style.height ?? 0)
        }

        let uiTop = (renderSize.height - contentPathRect.maxY) + style.visualOffsetBefore
        return CGRect(
            x: blockX,
            y: uiTop,
            width: preferredWidth,
            height: max(1, blockHeight)
        )
    }

    private static func explicitRenderableText(
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        ranges: [NSRange],
        attrStr: NSAttributedString,
        explicitRect: CGRect
    ) -> NSAttributedString? {
        guard !explicitRect.isNull,
              let mergedRange = mergeRanges(ranges),
              mergedRange.location < attrStr.length
        else {
            return nil
        }

        let text = NSMutableAttributedString(attributedString: attrStr.attributedSubstring(from: mergedRange))
        while text.length > 0 {
            let last = (text.string as NSString).character(at: text.length - 1)
            if last == 0x000A || last == 0x2028 || last == 0x2029 {
                text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
            } else {
                break
            }
        }

        guard containsMeaningfulText(text.string) else {
            return nil
        }

        let sanitized = NSMutableAttributedString(string: text.string)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var filtered: [NSAttributedString.Key: Any] = [:]
            for key in [
                NSAttributedString.Key.font,
                .foregroundColor,
                .backgroundColor,
                .kern,
                .baselineOffset,
                .underlineStyle,
                .underlineColor,
                .strikethroughStyle,
                .strikethroughColor,
                .paragraphStyle,
            ] {
                if let value = attributes[key] {
                    filtered[key] = value
                }
            }
            sanitized.setAttributes(filtered, range: range)
        }

        sanitized.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: sanitized.length)) { value, range, _ in
            guard let paragraphStyle = value as? NSParagraphStyle else { return }
            let normalized = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            normalized.paragraphSpacingBefore = 0
            normalized.paragraphSpacing = 0
            normalized.firstLineHeadIndent = 0
            normalized.headIndent = 0
            normalized.tailIndent = 0
            if style.isHorizontallyCentered {
                normalized.alignment = .center
            }
            sanitized.addAttribute(.paragraphStyle, value: normalized, range: range)
        }

        let hasExplicitTextGeometry =
            style.backgroundFillColor != nil
            || style.width != nil
            || style.isHorizontallyCentered
            || style.visualOffsetBefore > 0
        return hasExplicitTextGeometry ? sanitized : nil
    }

    private static func containsMeaningfulText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFFFC, 0x2028, 0x2029, 0x00A0:
                continue
            default:
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            return true
        }
        return false
    }

    private static func mergeRanges(_ ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.min(by: { $0.location < $1.location }) else { return nil }
        var lower = first.location
        var upper = first.location + first.length
        for range in ranges.dropFirst() {
            lower = min(lower, range.location)
            upper = max(upper, range.location + range.length)
        }
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private static func measureHeight(for attributedString: NSAttributedString, constrainedWidth: CGFloat) -> CGFloat {
        guard attributedString.length > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attributedString.length),
            nil,
            CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(size.height)
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
