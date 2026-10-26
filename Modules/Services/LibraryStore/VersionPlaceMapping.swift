import Foundation

/// A place carried from one version of a work to another: from a 來源配置's list to an EPUB's,
/// from an imported TXT to a module's book, and back (換源 between versions, maintainer
/// 2026-10-26: 「所有來源都是相同地位」).
///
/// The two lists do not count alike. A 來源配置's, a module's and a TXT's chapter is its place in
/// the list; an EPUB's entry points into the spine (`WorkTableOfContents`), where several entries
/// can share one spine item and front matter shifts the rest. So a place is first turned into its
/// entry's place in the old list, that entry is found again in the new list by title
/// (`ChapterAlignment`, as 換源 between sources does, the first entry included), and the new entry
/// says where its reader opens. The text of another version starts its chapters elsewhere, so no
/// offset is carried.
enum VersionPlaceMapping {
    /// The entry `spineIndex` is read in: the last one that starts at or before it. Nil for an
    /// empty list.
    static func listPosition(ofSpine spineIndex: Int, in chapters: [OnlineChapterRef]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        return chapters.lastIndex { $0.index <= spineIndex } ?? 0
    }

    /// Where the new version's reader opens for `spineIndex` of the old one: the matching entry's
    /// spine item, at its anchor when it has one. Nil when either list is empty: nothing can be
    /// found again, and the new version opens where it was left.
    static func target(forSpine spineIndex: Int, from old: [OnlineChapterRef], to new: [OnlineChapterRef]) -> ReaderTOCTarget? {
        guard let oldPosition = listPosition(ofSpine: spineIndex, in: old), !new.isEmpty else { return nil }
        let newPosition = ChapterAlignment.alignedIndex(
            oldIndex: oldPosition,
            oldTitle: old[oldPosition].title,
            oldCount: old.count,
            newTitles: new.map(\.title)
        )
        return WorkTableOfContents.target(of: new[min(max(0, newPosition), new.count - 1)])
    }

    /// A bookmark of the old version, placed at the start of its chapter in the new one, with its
    /// excerpt and note: a highlight's range is an offset into the old text, and drawing it over
    /// the new text would mark the wrong words (`ShelfWorkMerger.carried` keeps a range only
    /// between two lists of one kind). The id stays, so a bookmark carried twice is one.
    static func carried(_ bookmark: Bookmark, from old: [OnlineChapterRef], to new: [OnlineChapterRef]) -> Bookmark {
        let target = target(forSpine: bookmark.position.spineIndex, from: old, to: new)
        let spine = target?.spineIndex ?? bookmark.position.spineIndex
        let title = new.first { $0.index == spine }?.title ?? bookmark.chapterTitle
        return Bookmark(
            chapterIndex: spine, chapterTitle: title,
            position: CoreTextReadingPosition(spineIndex: spine, charOffset: 0),
            length: 0, kind: .bookmark, note: bookmark.note,
            excerpt: bookmark.excerpt, id: bookmark.id, date: bookmark.date
        )
    }
}
