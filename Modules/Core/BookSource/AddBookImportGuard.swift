import Foundation

enum AddBookImportGuard {
    static func shouldApplyResult(
        activeSessionID: UUID,
        resultSessionID: UUID,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeSessionID == resultSessionID
    }
}

