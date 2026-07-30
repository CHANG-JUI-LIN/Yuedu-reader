import CoreGraphics
import Foundation

enum ReaderDisplayMode: Equatable {
    case paged
    case scroll
}

enum ReaderRenderRefreshIntent: Equatable {
    case layout
    case appearance
    case chapterContent(Int)
    case modeActivation
}

struct ReaderRenderRefreshRequest: Equatable {
    let intent: ReaderRenderRefreshIntent
    let mode: ReaderDisplayMode
    let settings: ReaderRenderSettings
    let position: CoreTextReadingPosition
    let viewportSize: CGSize
}

enum ReaderRenderRefreshFailure: Error, Equatable {
    case engineUnavailable(ReaderDisplayMode)
    case layoutUnavailable(Int)
    case scrollViewportUnavailable
    case scrollLayoutUnavailable(Int)
}

enum ReaderRenderRefreshResult: Equatable {
    case completed(transactionID: UInt64)
    case superseded(transactionID: UInt64)
    case failed(transactionID: UInt64, failure: ReaderRenderRefreshFailure)

    var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

struct ReaderVisibleRefreshCommit: Equatable {
    let transactionID: UInt64
    let mode: ReaderDisplayMode
    let position: CoreTextReadingPosition
}

enum ReaderVisibleRefreshOutcome: Equatable {
    case applied
    case failed(ReaderRenderRefreshFailure)
}
