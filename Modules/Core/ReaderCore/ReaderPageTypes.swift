import Foundation

struct PageContent {
    let chapterIndex: Int
    let chapterTitle: String
    let content: String
    let pageInChapter: Int
    var attributedContent: NSAttributedString?
}

enum PageTurnAnimation {
    static let slideDuration: Double = 0.25
}

enum ReaderTOCSelection {
    static func currentChapter(
        in chapters: [BookChapter],
        currentSpineIndex: Int,
        currentCharOffset: Int,
        anchorOffset: (BookChapter) -> Int?
    ) -> BookChapter? {
        var lastPreviousSpineChapter: BookChapter?
        var lastPreviousSpine = Int.min
        var firstCurrentSpineChapter: BookChapter?
        var bestCurrentSpineChapter: BookChapter?
        var bestCurrentOffset = Int.min

        for chapter in chapters {
            if chapter.index < currentSpineIndex {
                if chapter.index >= lastPreviousSpine {
                    lastPreviousSpine = chapter.index
                    lastPreviousSpineChapter = chapter
                }
                continue
            }

            guard chapter.index == currentSpineIndex else { continue }

            if firstCurrentSpineChapter == nil {
                firstCurrentSpineChapter = chapter
            }

            let offset: Int
            if let fragment = chapter.fragment, !fragment.isEmpty {
                guard let resolved = anchorOffset(chapter) else { continue }
                offset = resolved
            } else {
                offset = 0
            }

            guard offset <= currentCharOffset else { continue }
            if offset > bestCurrentOffset {
                bestCurrentOffset = offset
                bestCurrentSpineChapter = chapter
            }
        }

        return bestCurrentSpineChapter
            ?? firstCurrentSpineChapter
            ?? lastPreviousSpineChapter
    }
}
