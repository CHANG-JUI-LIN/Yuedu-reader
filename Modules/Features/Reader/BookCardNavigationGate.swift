import Foundation

// MARK: - BookCardNavigationGate
//
// Decides whether a book should use the migrated card navigation
// (push/pop with the card transition) or keep its existing modal
// presentation. Text, reflowable EPUB, online HTML, and the shared
// fixed-page reader use the same card transition; audiobooks stay modal.

enum BookCardNavigationGate {
    /// True when `book` belongs to a presentation kind that has been migrated
    /// to the card-navigation push/pop path, in a window of this width.
    static func shouldUseCardTransition(
        for book: ReadingBook,
        isRegularWidth: Bool
    ) -> Bool {
        // The first production delivery owns the full-width UINavigationController
        // path of a compact window. A regular-width window's sidebar-adaptable root
        // (iPad, an unfolded iPhone Duo) keeps its proven modal reader until it
        // receives a separately designed split-view transition: pushed there, the
        // reader would open inside the content column, beside the sidebar.
        guard !isRegularWidth else { return false }
        let kind = book.resolvedPipelineKind
        // Audiobooks retain their dedicated modal presentation.
        switch kind {
        case .audio:
            return false
        default:
            return true
        }
    }
}
