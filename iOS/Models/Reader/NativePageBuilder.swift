/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import CoreText
import Foundation
import UIKit

// MARK: - Core Text Paginator: Split NSAttributedString into pages

final class NativePageBuilder {

    /// Pagination result
    struct PageSlice {
        let chapterIndex: Int
        let chapterTitle: String
        /// The attributed substring for this page
        let attributedContent: NSAttributedString
        /// The page's zero-based index within the chapter
        let pageInChapter: Int
    }

    /// Chapter page summary for fast indexing during lazy loading
    struct ChapterPageInfo {
        let chapterIndex: Int
        let pageCount: Int
        /// Starting global page index of this chapter in allPages
        let globalStartPage: Int
    }

    /// Paginate a single chapter's NSAttributedString using Core Text
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
            // Reserve space for the title on the first page
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
                availableHeight = max(availableHeight, pageSize.height * 0.3) // Reserve at least 30%
            }

            // Get remaining text
            let remaining = attributed.attributedSubstring(
                from: NSRange(location: currentOffset, length: totalLength - currentOffset)
            )

            // Use CTFramesetter to determine how many characters fit on this page
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

            // Safety valve: prevent infinite loop
            if pageRange.length == 0 { break }
        }

        return pages
    }

    /// Batch-paginate all chapters synchronously (suitable for books with few chapters)
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

    // MARK: - Progressive Pagination (for large novels)

    /// Estimate the page count for a single chapter (no actual CoreText layout, very fast)
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
        let charsPerLine = max(1, Int(pageSize.width / fontSize))
        let charsPerPage = linesPerPage * charsPerLine
        return max(1, Int(ceil(Double(charCount) / Double(charsPerPage))))
    }

    /// Paginate all chapters concurrently (multi-core, suitable for large books)
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

    /// Progressive pagination: paginate chapters near the focus chapter first,
    /// return usable results immediately. Remaining chapters are paginated in
    /// the background, with updates delivered via onProgress.
    ///
    /// - Parameters:
    ///   - focusChapter: The chapter index the user is currently reading
    ///   - chapters: All chapters
    ///   - onReady: Focus zone pagination complete, with initial allPages and estimated total pages
    ///   - onProgress: Callback after each background batch, with updated allPages
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
            // Phase 1: Paginate focus zone (±3 chapters)
            let radius = 3
            let lo = max(0, focus - radius)
            let hi = min(count - 1, focus + radius)

            var paginatedSlices = [[PageSlice]?](repeating: nil, count: count)

            // Focus zone: synchronous pagination (small, fast)
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

            // Non-focus zone: generate placeholder slices using estimated page counts
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
                    // Placeholder slice: attributedContent empty, replaced later
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

            // Phase 2: Background concurrent pagination of remaining chapters
            let remaining = (0..<count).filter { $0 < lo || $0 > hi }
            guard !remaining.isEmpty else { return }

            // Process in batches of 20 chapters to avoid memory spikes
            let batchSize = 20
            var batchStart = 0
            while batchStart < remaining.count {
                let batchEnd = min(batchStart + batchSize, remaining.count)
                let batch = Array(remaining[batchStart..<batchEnd])

                // Intra-batch concurrency
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

                // Update results
                for (idx, i) in batch.enumerated() {
                    paginatedSlices[i] = batchResults[idx]
                }

                let updated = paginatedSlices.compactMap { $0 }.flatMap { $0 }
                onProgress(updated)

                batchStart = batchEnd
            }
        }
    }

    /// Compute the layout area (uses the same margin logic as the TXT charsPerPage path)
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

        // Snap height to an integer multiple of line height, ensuring full lines per page
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
