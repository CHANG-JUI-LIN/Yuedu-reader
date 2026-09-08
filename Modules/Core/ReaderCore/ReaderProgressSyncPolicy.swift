import Foundation

enum ReaderProgressSyncPolicy {
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
