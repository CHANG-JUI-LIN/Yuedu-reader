/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import CoreText
import Foundation
import UIKit

// MARK: - Core Text 分頁器：將 NSAttributedString 切成多頁

final class NativePageBuilder {

    /// 分頁結果
    struct PageSlice {
        let chapterIndex: Int
        let chapterTitle: String
        /// 該頁對應的富文字子串
        let attributedContent: NSAttributedString
        /// 該頁在章節中的序號（0 起始）
        let pageInChapter: Int
    }

    /// 章節分頁摘要（用於懶加載時的快速索引）
    struct ChapterPageInfo {
        let chapterIndex: Int
        let pageCount: Int
        /// 該章節第一頁在全域 allPages 中的起始索引
        let globalStartPage: Int
    }

    /// 對一個章節的 NSAttributedString 做 Core Text 分頁
    static func paginate(
        attributed: NSAttributedString,
        chapterIndex: Int,
        chapterTitle: String,
        pageSize: CGSize,
        titleAttributes: [NSAttributedString.Key: Any]? = nil,
        titleBottomPadding: CGFloat = 20
    ) -> [PageSlice] {
        guard attributed.length > 0, pageSize.width > 0, pageSize.height > 0 else {
            return [PageSlice(
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                attributedContent: NSAttributedString(string: ""),
                pageInChapter: 0
            )]
        }

        var pages: [PageSlice] = []
        var currentOffset = 0
        var pageNum = 0
        let totalLength = attributed.length

        while currentOffset < totalLength {
            // 第一頁留出標題空間
            var availableHeight = pageSize.height
            if pageNum == 0, let titleAttrs = titleAttributes {
                let titleStr = NSAttributedString(string: chapterTitle + "
", attributes: titleAttrs)
                let titleFramesetter = CTFramesetterCreateWithAttributedString(titleStr)
                let titleSize = CTFramesetterSuggestFrameSizeWithConstraints(
                    titleFramesetter,
                    CFRange(location: 0, length: titleStr.length),
                    nil,
                    CGSize(width: pageSize.width, height: .greatestFiniteMagnitude),
                    nil
                )
                availableHeight -= (titleSize.height + titleBottomPadding)
                availableHeight = max(availableHeight, pageSize.height * 0.3) // 至少保留 30%
            }

            // 取剩餘文字
            let remaining = attributed.attributedSubstring(
                from: NSRange(location: currentOffset, length: totalLength - currentOffset)
            )

            // 用 CTFramesetter 計算這一頁能容納多少字
            let framesetter = CTFramesetterCreateWithAttributedString(remaining)
            var fitRange = CFRange(location: 0, length: 0)
            CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: 0),
                nil,
                CGSize(width: pageSize.width, height: availableHeight),
                &fitRange
            )

            let charsThisPage = fitRange.length > 0 ? fitRange.length : remaining.length
            let pageRange = NSRange(location: currentOffset, length: min(charsThisPage, totalLength - currentOffset))
            let pageAttr = attributed.attributedSubstring(from: pageRange)

            pages.append(PageSlice(
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                attributedContent: pageAttr,
                pageInChapter: pageNum
            ))

            currentOffset += pageRange.length
            pageNum += 1

            // 安全閥：避免死循環
            if pageRange.length == 0 { break }
        }

        return pages
    }

    /// 批量分頁所有章節（同步，適合章節數量少的書）
    static func paginateAll(
        chapters: [(title: String, attributed: NSAttributedString)],
        pageSize: CGSize,
        fontSize: CGFloat,
        textColor: UIColor = .label
    ) -> [PageSlice] {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize + 8, weight: .bold),
            .foregroundColor: textColor
        ]

        var allPages: [PageSlice] = []
        for (index, chapter) in chapters.enumerated() {
            let chapterPages = paginate(
                attributed: chapter.attributed,
                chapterIndex: index,
                chapterTitle: chapter.title,
                pageSize: pageSize,
                titleAttributes: titleAttrs
            )
            allPages.append(contentsOf: chapterPages)
        }
        return allPages
    }

    // MARK: - 漸進式分頁（百萬字小說專用）

    /// 估算單章頁數（不做真正的 CoreText 排版，極快）
    static func estimatePageCount(
        charCount: Int,
        pageSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat = 0
    ) -> Int {
        guard charCount > 0, pageSize.width > 0, pageSize.height > 0 else { return 1 }
        let font = UIFont.systemFont(ofSize: fontSize)
        let lineH = font.lineHeight + lineSpacing
        let linesPerPage = max(1, Int(pageSize.height / lineH))
        // 中文約每行 pageSize.width / fontSize 個字
        let charsPerLine = max(1, Int(pageSize.width / fontSize))
        let charsPerPage = linesPerPage * charsPerLine
        return max(1, Int(ceil(Double(charCount) / Double(charsPerPage))))
    }

    /// 並行分頁所有章節（多核加速，適合大型書籍）
    static func paginateAllConcurrently(
        chapters: [(title: String, attributed: NSAttributedString)],
        pageSize: CGSize,
        fontSize: CGFloat,
        textColor: UIColor = .label
    ) -> [PageSlice] {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize + 8, weight: .bold),
            .foregroundColor: textColor
        ]

        let count = chapters.count
        var results = [[PageSlice]](repeating: [], count: count)

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let chapter = chapters[index]
            results[index] = paginate(
                attributed: chapter.attributed,
                chapterIndex: index,
                chapterTitle: chapter.title,
                pageSize: pageSize,
                titleAttributes: titleAttrs
            )
        }

        return results.flatMap { $0 }
    }

    /// 漸進式分頁：先分頁焦點章節附近，立刻返回可用結果。
    /// 剩餘章節在背景並行分頁，透過 onProgress 回調更新。
    ///
    /// - Parameters:
    ///   - focusChapter: 使用者當前閱讀的章節索引
    ///   - chapters: 所有章節
    ///   - onReady: 焦點區域分頁完成，帶初始 allPages 和估算總頁數（可立刻顯示 UI）
    ///   - onProgress: 背景每完成一批章節就回調，帶更新後的完整 allPages
    static func paginateProgressively(
        focusChapter: Int,
        chapters: [(title: String, attributed: NSAttributedString)],
        pageSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat = 0,
        textColor: UIColor = .label,
        onReady: @escaping ([PageSlice], Int) -> Void,
        onProgress: @escaping ([PageSlice]) -> Void
    ) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize + 8, weight: .bold),
            .foregroundColor: textColor
        ]
        let count = chapters.count
        guard count > 0 else {
            onReady([], 0)
            return
        }

        let focus = min(max(focusChapter, 0), count - 1)

        DispatchQueue.global(qos: .userInitiated).async {
            // Phase 1: 分頁焦點區域（前後各 3 章）
            let radius = 3
            let lo = max(0, focus - radius)
            let hi = min(count - 1, focus + radius)

            var paginatedSlices = [[PageSlice]?](repeating: nil, count: count)

            // 焦點區域同步分頁（量小，很快）
            for i in lo...hi {
                let ch = chapters[i]
                paginatedSlices[i] = paginate(
                    attributed: ch.attributed,
                    chapterIndex: i,
                    chapterTitle: ch.title,
                    pageSize: pageSize,
                    titleAttributes: titleAttrs
                )
            }

            // 非焦點區域：用估算頁數生成佔位 PageSlice
            for i in 0..<count where paginatedSlices[i] == nil {
                let ch = chapters[i]
                let est = estimatePageCount(
                    charCount: ch.attributed.length,
                    pageSize: pageSize,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing
                )
                var placeholder: [PageSlice] = []
                for p in 0..<est {
                    // 佔位 slice：attributedContent 留空，後續替換
                    placeholder.append(PageSlice(
                        chapterIndex: i,
                        chapterTitle: ch.title,
                        attributedContent: NSAttributedString(string: ""),
                        pageInChapter: p
                    ))
                }
                paginatedSlices[i] = placeholder
            }

            let initialPages = paginatedSlices.compactMap { $0 }.flatMap { $0 }
            let estimatedTotal = initialPages.count
            onReady(initialPages, estimatedTotal)

            // Phase 2: 背景並行分頁剩餘章節
            let remaining = (0..<count).filter { $0 < lo || $0 > hi }
            guard !remaining.isEmpty else { return }

            // 分批處理，每批 20 章，避免記憶體峰值過高
            let batchSize = 20
            var batchStart = 0
            while batchStart < remaining.count {
                let batchEnd = min(batchStart + batchSize, remaining.count)
                let batch = Array(remaining[batchStart..<batchEnd])

                // 批內並行
                var batchResults = [[PageSlice]](repeating: [], count: batch.count)
                DispatchQueue.concurrentPerform(iterations: batch.count) { idx in
                    let i = batch[idx]
                    let ch = chapters[i]
                    batchResults[idx] = paginate(
                        attributed: ch.attributed,
                        chapterIndex: i,
                        chapterTitle: ch.title,
                        pageSize: pageSize,
                        titleAttributes: titleAttrs
                    )
                }

                // 更新結果
                for (idx, i) in batch.enumerated() {
                    paginatedSlices[i] = batchResults[idx]
                }

                let updated = paginatedSlices.compactMap { $0 }.flatMap { $0 }
                onProgress(updated)

                batchStart = batchEnd
            }
        }
    }

    /// 計算排版區域（與 TXT 版 charsPerPage 使用相同邊距邏輯）
    static func computePageSize(
        screenSize: CGSize? = nil,
        pageMarginH: CGFloat,
        pageMarginV: CGFloat,
        fontSize: CGFloat = 0,
        lineSpacing: CGFloat = 0
    ) -> CGSize {
        let screen = screenSize ?? UIScreen.main.bounds.size
        let safeTop: CGFloat = 54
        let safeBottom: CGFloat = 34
        let footerClearance: CGFloat = 50
        let totalV = safeTop + safeBottom + pageMarginV * 2 + footerClearance
        var h = max(200, screen.height - totalV)
        let w = max(200, screen.width - pageMarginH * 2)

        // 將高度對齊到行高的整數倍，確保每頁剛好塞滿整數行（類似起點排版）
        if fontSize > 0 {
            let font = UIFont.systemFont(ofSize: fontSize)
            let singleLineHeight = font.lineHeight + lineSpacing
            if singleLineHeight > 0 {
                let lines = floor(h / singleLineHeight)
                if lines > 0 {
                    h = lines * singleLineHeight
                }
            }
        }

        return CGSize(width: w, height: h)
    }
}
*/
