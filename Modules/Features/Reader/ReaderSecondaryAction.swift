import Foundation

/// A book-scoped action offered by the reader chrome — refresh the chapter, change
/// source, download, start narration. Which ones apply depends on the book (a local
/// EPUB only gets playback), so `ReaderView.readerSecondaryActions` builds the list
/// once and every interface renders that same list: Apple Books shows them in its
/// pop-up menu, 現代 in the book card behind the cover thumbnail.
struct ReaderSecondaryAction: Identifiable {
    enum ID: String {
        case playback
        case download
        case changeSource
        case refresh
    }

    let id: ID
    let icon: String
    let label: String
    let action: () -> Void
}

/// What the 現代 book-card popover was asked to open.
///
/// Every one of these opens a sheet, and iOS drops a sheet requested while the popover
/// it came from is still dismissing — 聽書 was the visible casualty: the card slid back
/// into the cover thumbnail and no TTS panel ever appeared. So the tap records the route
/// here and `ReaderView` opens it from the popover's real dismissal, never in the same
/// turn as `showModernBookCard = false`.
enum ReaderModernBookCardRoute: Hashable {
    case secondary(ReaderSecondaryAction.ID)
    case bookDetail
}
