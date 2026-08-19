import Foundation

struct CoreTextReadingPosition: Codable, Equatable {
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

    // MARK: - Page stepping

    /// The page after `position`, as a position.
    ///
    /// This is what the `UIPageViewController` data source walks. It deliberately
    /// never consults `spinePageOffsets`: a global page index is only meaningful
    /// inside the pagination that produced it, and a chapter laying out mid-turn
    /// renumbers every page after it. Chapter boundaries come from `chapterCount`
    /// alone, so crossing one needs no layout on the far side.
    ///
    /// Returns nil at the end of the book, and when the current chapter has no
    /// layout — there is no honest answer to "what follows a page we never
    /// measured", and UIKit reads nil as "no next page".
    static func positionAfter(
        _ position: CoreTextReadingPosition,
        layouts: [Int: CoreTextPaginator.ChapterLayout],
        chapterCount: Int
    ) -> CoreTextReadingPosition? {
        let spineIndex = position.spineIndex
        guard (0..<chapterCount).contains(spineIndex),
              let layout = layouts[spineIndex],
              !layout.pageRanges.isEmpty
        else { return nil }

        let localPage = localPageIndex(for: position, in: layout)
        if localPage + 1 < layout.pageRanges.count {
            return CoreTextReadingPosition(
                spineIndex: spineIndex,
                charOffset: Int(layout.pageRanges[localPage + 1].location)
            )
        }

        // Partial layout: the chapter continues past what has been measured. The
        // first unmeasured character is a real anchor — once the full pass lands it
        // resolves to the very next page, with no index to go stale in between.
        if layout.isPartial {
            let coveredEnd = layout.pageRanges.last.map { Int($0.location + $0.length) } ?? 0
            if coveredEnd < layout.attributedString.length {
                return CoreTextReadingPosition(spineIndex: spineIndex, charOffset: coveredEnd)
            }
        }

        guard spineIndex + 1 < chapterCount else { return nil }
        return .chapterStart(spineIndex + 1)
    }

    /// The page before `position`, as a position. Mirror of `positionAfter`;
    /// returns nil at the start of the book.
    static func positionBefore(
        _ position: CoreTextReadingPosition,
        layouts: [Int: CoreTextPaginator.ChapterLayout],
        chapterCount: Int
    ) -> CoreTextReadingPosition? {
        let spineIndex = position.spineIndex
        guard (0..<chapterCount).contains(spineIndex),
              let layout = layouts[spineIndex],
              !layout.pageRanges.isEmpty
        else { return nil }

        let localPage = localPageIndex(for: position, in: layout)
        if localPage > 0 {
            return CoreTextReadingPosition(
                spineIndex: spineIndex,
                charOffset: Int(layout.pageRanges[localPage - 1].location)
            )
        }

        guard spineIndex > 0 else { return nil }
        // `.chapterEnd` is a sentinel offset, resolved against the previous
        // chapter's layout whenever it lands — so backward crossing needs no
        // layout on the far side either.
        return .chapterEnd(spineIndex - 1)
    }
}
