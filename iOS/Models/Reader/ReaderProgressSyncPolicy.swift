import Foundation

enum ReaderProgressSyncPolicy {
    static func shouldPersistOnPageChanged(
        isCoreTextReady: Bool,
        totalPages: Int,
        isRestoringPosition: Bool
    ) -> Bool {
        isCoreTextReady && totalPages > 0 && !isRestoringPosition
    }
}
