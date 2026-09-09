import Foundation
import UIKit

// MARK: - BookCardNavigationGate
//
// Decides whether a book should use the migrated card navigation
// (push/pop with the card transition) or keep its existing modal
// presentation. Text, reflowable EPUB, online HTML, and the shared
// fixed-page reader use the same card transition; audiobooks stay modal.

enum BookCardNavigationGate {
    /// True when `book` belongs to a presentation kind that has been migrated
    /// to the card-navigation push/pop path.
    @MainActor
    static func shouldUseCardTransition(for book: ReadingBook) -> Bool {
        shouldUseCardTransition(
            for: book,
            idiom: UIDevice.current.userInterfaceIdiom
        )
    }

    static func shouldUseCardTransition(
        for book: ReadingBook,
        idiom: UIUserInterfaceIdiom
    ) -> Bool {
        // The first production delivery owns the iPhone UINavigationController
        // path. iPad's sidebar-adaptable root keeps its proven modal reader
        // until it receives a separately designed split-view transition.
        guard idiom == .phone else { return false }
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
