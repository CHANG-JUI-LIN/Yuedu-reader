import Foundation

enum ReaderProgressSyncPolicy {
    /// All continuous text sources own live position in ReaderSessionStore. Publishing the
    /// library's entire record array on every gesture invalidates offscreen tabs.
    /// Data persistence remains unchanged; only UI observation is session-local.
    ///
    /// Vertical writing scrolls through the same host and keeps its progress the same way.
    /// Left out, every exit wrote the shelf's progress from the chapter number, over the exact
    /// figure each settled scroll had saved: a book read to 13.8% of its first chapter showed 0%
    /// on the shelf (2026-10-16).
    static func usesSessionLocalScrollProgress(isScrollMode: Bool, hasScrollEngine: Bool) -> Bool {
        isScrollMode && hasScrollEngine
    }

    /// A preview or failed migration cannot publish canonical chapter numbers.
    static func canPublishIndexPosition(isTXT: Bool, indexReady: Bool) -> Bool {
        !isTXT || indexReady
    }
    static func shouldPersistOnPageChanged(
        isCoreTextReady: Bool,
        totalPages: Int,
        isRestoringPosition: Bool
    ) -> Bool {
        isCoreTextReady && totalPages > 0 && !isRestoringPosition
    }
}
