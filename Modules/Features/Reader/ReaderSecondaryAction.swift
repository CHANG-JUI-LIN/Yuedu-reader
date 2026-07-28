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
