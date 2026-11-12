import Foundation

/// How a two-page spread pairs reflowable pages: two pages of one chapter, every chapter's
/// first page opening a spread, and a chapter that ends on a spread's first page facing a
/// blank page.
///
/// Spreads used to pair global page indices (0,1)(2,3)…. A global index counts estimated pages
/// for every chapter not laid out yet, and which chapters are laid out differs from one open of
/// an online book to the next, so the same reading position fell on a spread's first page in
/// one open and its second in the next. The reader saves a spread by its first page, so each
/// open could move them a page back — over a chapter start onto the previous chapter's last
/// page (回饋中心 #182). A page's place within its own chapter is the only part of its index no
/// other chapter's layout can change, so pairing reads that and nothing else
/// (maintainer's choice, 2026-11-12).
///
/// Fixed-layout books pair by their own spread properties (`FixedLayoutSpreadPairingProviding`).
extension StablePositionResolving {
    /// The first page of the spread holding `page`.
    func spreadStart(containing page: Int) -> Int {
        let page = max(0, page)
        return page - localPosition(for: page).localPage % 2
    }

    /// The page facing a spread's first page, or nil where its chapter — or the book, at
    /// `pageCount` pages — ends on it.
    func spreadPartner(of first: Int, pageCount: Int) -> Int? {
        let partner = first + 1
        guard partner < pageCount,
              localPosition(for: partner).spineIndex == localPosition(for: first).spineIndex
        else { return nil }
        return partner
    }
}
