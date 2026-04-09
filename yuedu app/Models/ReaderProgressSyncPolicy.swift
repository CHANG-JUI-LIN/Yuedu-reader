import Foundation

enum ReaderProgressSyncPolicy {
    static func shouldPersistOnPageChanged(
        isCoreTextReady: Bool,
        totalPages: Int,
        isRestoringPosition: Bool
    ) -> Bool {
        isCoreTextReady && totalPages > 0 && !isRestoringPosition
    }

    static func shouldUseEnginePageDirectly(
        enginePage: Int,
        totalPages: Int,
        savedPositionSnapshot: Double,
        hasRestoreTarget: Bool
    ) -> Bool {
        if enginePage > 0 {
            return true
        }
        if totalPages <= 0 {
            return false
        }
        return savedPositionSnapshot == 0 && !hasRestoreTarget
    }
}

