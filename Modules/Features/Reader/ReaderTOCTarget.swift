import Foundation

/// A 目錄 entry the reader is asked to open from outside its own 目錄: 作品詳情's 目錄, or a
/// chapter picked on 作品詳情 above the reader. `fragment` is the anchor inside the spine item
/// when the entry points into the middle of one — Project Gutenberg's EPUBs put many chapters
/// in one file.
///
/// The reader lands on it through its own 目錄 jump (`ReaderView.jumpToTOCEntry`), so an entry
/// lands where the same entry picked in the reader's 目錄 does.
struct ReaderTOCTarget: Hashable {
    let spineIndex: Int
    let fragment: String?

    /// The entry as the reader's 目錄 holds it.
    var entry: BookChapter {
        BookChapter(index: spineIndex, title: "", content: "", fragment: fragment)
    }
}

/// Scroll mode: a 目錄 entry whose anchor waits for its spine item to enter the scroll window.
/// `generation` is the chapter jump it belongs to; a later jump drops it.
struct ReaderPendingTOCEntry {
    let entry: BookChapter
    let generation: Int
}
