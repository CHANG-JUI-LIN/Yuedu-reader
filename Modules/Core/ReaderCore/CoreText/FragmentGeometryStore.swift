import CoreGraphics
import CoreText
import Foundation

/// The single source of truth for scroll geometry: which chapters are present, what each
/// fragment's height is, and whether that height is measured or still a guess.
///
/// `Technotes/ViewportScrollArchitecture.md` §5. Today `UICollectionViewFlowLayout` derives
/// content size by asking `sizeForItemAt` for every item's exact height, which is precisely what
/// forces the whole chapter to be laid out before it can be inserted (§3.2). Routing every height
/// question through one owner is what later lets an *estimated* height answer them.
///
/// Stage 1 keeps behaviour identical: heights recorded here come from real layout, so the store
/// reports the same numbers `CoreTextChunk.height` always did. Estimates only start answering
/// queries in stage 3.
@MainActor
final class FragmentGeometryStore {

    private var outlines: [Int: ChapterOutline] = [:]
    /// Chapter order along the scroll axis. Kept explicitly because chapters can be prepended,
    /// and because a dictionary's ordering says nothing about what the reader sees.
    private(set) var chapterOrder: [Int] = []

    // MARK: - Population

    /// Installs (or replaces) a chapter's outline.
    ///
    /// - Parameter prepend: whether the chapter goes before everything loaded so far, which is
    ///   what scrolling backwards into an earlier chapter does.
    func setOutline(_ outline: ChapterOutline, prepend: Bool = false) {
        let chapter = outline.chapterIndex
        let isNew = outlines[chapter] == nil
        outlines[chapter] = outline
        guard isNew else { return }
        if prepend {
            chapterOrder.insert(chapter, at: 0)
        } else {
            chapterOrder.append(chapter)
        }
    }

    func removeChapter(_ chapter: Int) {
        outlines.removeValue(forKey: chapter)
        chapterOrder.removeAll { $0 == chapter }
    }

    func removeAll() {
        outlines.removeAll()
        chapterOrder.removeAll()
    }

    func outline(for chapter: Int) -> ChapterOutline? {
        outlines[chapter]
    }

    var loadedChapterCount: Int {
        chapterOrder.count
    }

    // MARK: - Geometry

    func fragmentCount(inChapter chapter: Int) -> Int {
        outlines[chapter]?.fragments.count ?? 0
    }

    /// Height of one fragment — measured when known, estimated otherwise.
    func height(chapter: Int, fragment: Int) -> CGFloat? {
        guard let outline = outlines[chapter],
              outline.fragments.indices.contains(fragment)
        else { return nil }
        return outline.fragments[fragment].height
    }

    func descriptor(chapter: Int, fragment: Int) -> FragmentDescriptor? {
        guard let outline = outlines[chapter],
              outline.fragments.indices.contains(fragment)
        else { return nil }
        return outline.fragments[fragment]
    }

    func totalHeight(chapter: Int) -> CGFloat {
        outlines[chapter]?.totalEstimatedHeight ?? 0
    }

    /// Height of everything currently loaded. This is what replaces flow layout's summed
    /// `sizeForItemAt` in stage 2 — the number that decides `contentSize`.
    var totalHeight: CGFloat {
        chapterOrder.reduce(0) { $0 + totalHeight(chapter: $1) }
    }

    /// Whether any loaded fragment is still estimated, i.e. whether `totalHeight` is provisional.
    var hasEstimatedHeights: Bool {
        chapterOrder.contains { outlines[$0]?.hasEstimates == true }
    }

    /// Total fragments across every loaded chapter, in scroll order.
    var flatFragmentCount: Int {
        chapterOrder.reduce(0) { $0 + fragmentCount(inChapter: $1) }
    }

    /// Height of the fragment at `index` counting continuously across chapters in scroll order.
    ///
    /// This is the shape the collection view asks in: it addresses one flat list of items and
    /// knows nothing about chapter boundaries. Walking `chapterOrder` is O(loaded chapters) —
    /// a handful, since chapters are evicted as the reader moves away.
    func height(atFlatIndex index: Int) -> CGFloat? {
        guard index >= 0 else { return nil }
        var remaining = index
        for chapter in chapterOrder {
            let count = fragmentCount(inChapter: chapter)
            if remaining < count {
                return height(chapter: chapter, fragment: remaining)
            }
            remaining -= count
        }
        return nil
    }

    // MARK: - Measurement feedback

    /// Records the height real layout produced for a fragment.
    ///
    /// - Returns: how much the chapter's total height moved, which is what the anchor compensator
    ///   needs in stage 3 to keep the viewport still. Zero when nothing changed.
    @discardableResult
    func recordActualHeight(
        _ height: CGFloat,
        chapter: Int,
        fragment: Int,
        laidOut: Bool = true
    ) -> CGFloat {
        guard var outline = outlines[chapter],
              outline.fragments.indices.contains(fragment)
        else { return 0 }
        let before = outline.fragments[fragment].height
        outline.recordActualHeight(height, at: fragment, laidOut: laidOut)
        let after = outline.fragments[fragment].height
        outlines[chapter] = outline
        return after - before
    }

    /// Chapter-relative character offset → fragment index.
    ///
    /// The anchor for scroll compensation is a character offset, never an index path: chapters
    /// get prepended and reloaded, which invalidates indices but never character offsets
    /// (§附錄).
    func fragmentIndex(chapter: Int, containing location: CFIndex) -> Int? {
        outlines[chapter]?.fragmentIndex(containing: location)
    }

    /// Distance from the start of the loaded content to the top of the given fragment.
    ///
    /// Walks the chapters ahead of it in scroll order, so the result is directly comparable with
    /// `contentOffset`.
    func offsetOfFragment(chapter: Int, fragment: Int) -> CGFloat? {
        guard let outline = outlines[chapter],
              outline.fragments.indices.contains(fragment),
              let chapterPosition = chapterOrder.firstIndex(of: chapter)
        else { return nil }

        var offset: CGFloat = 0
        for earlier in chapterOrder[..<chapterPosition] {
            offset += totalHeight(chapter: earlier)
        }
        for index in 0..<fragment {
            offset += outline.fragments[index].height
        }
        return offset
    }
}
