import Foundation

struct CoreTextReadingPosition: Equatable {
    let spineIndex: Int
    let charOffset: Int

    static func chapterStart(_ spineIndex: Int) -> Self {
        Self(spineIndex: spineIndex, charOffset: 0)
    }

    static func chapterEnd(_ spineIndex: Int) -> Self {
        Self(spineIndex: spineIndex, charOffset: .max)
    }
}

enum CoreTextReadingPositionMapper {
    static func pageIndex(
        for position: CoreTextReadingPosition,
        layouts: [Int: CoreTextPaginator.ChapterLayout],
        spinePageOffsets: [Int]
    ) -> Int? {
        guard spinePageOffsets.indices.contains(position.spineIndex),
              let layout = layouts[position.spineIndex] else {
            return nil
        }

        let localPage = localPageIndex(for: position, in: layout)
        return spinePageOffsets[position.spineIndex] + localPage
    }

    static func localPageIndex(
        for position: CoreTextReadingPosition,
        in layout: CoreTextPaginator.ChapterLayout
    ) -> Int {
        layout.pageIndex(for: clampedCharOffset(for: position, in: layout))
    }

    static func clampedCharOffset(
        for position: CoreTextReadingPosition,
        in layout: CoreTextPaginator.ChapterLayout
    ) -> Int {
        let upperBound = max(layout.attributedString.length, 0)
        if position.charOffset == .max {
            return upperBound
        }
        return min(max(position.charOffset, 0), upperBound)
    }
}
