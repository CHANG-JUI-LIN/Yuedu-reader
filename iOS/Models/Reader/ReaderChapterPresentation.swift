import Foundation

public enum ReaderChapterOverlayState: Equatable {
    case hidden
    case loading
    case failed(message: String)
}

public enum ReaderChapterRefreshAction: Equatable {
    case none
    case notifyChapterDataChanged(Int)
    case rebuildPages
    /// The chapter state is `.ready` but its content is missing from the validated
    /// cache — clears the stale cache entry and re-fetches immediately.
    case resetAndRefetchChapter(Int)
}

public enum ReaderChapterPresentation {
    public static func overlayState(isContentAvailable: Bool, loadState: ChapterLoadState?) -> ReaderChapterOverlayState {
        if isContentAvailable { return .hidden }
        guard let loadState = loadState else { return .loading }
        switch loadState {
        case .idle, .loading:
            return .loading
        case .failed(let reason):
            return .failed(message: reason)
        case .ready:
            // State claims ready but validated content is unavailable (e.g. a legacy
            // cache entry without the .package.json artifact).  Return .failed so the
            // "點擊重試" button is shown and the auto-reset path in refreshAction can
            // clear and re-fetch — avoids a permanent "loading" deadlock.
            return .failed(message: "資料不一致，請點擊重試")
        }
    }

    public static func refreshAction(
        changedChapterIndex: Int,
        currentChapterIndex: Int,
        usesCoreText: Bool,
        newState: ChapterLoadState?,
        isContentAvailable: Bool
    ) -> ReaderChapterRefreshAction {
        guard changedChapterIndex == currentChapterIndex else { return .none }
        // State transitioned to .ready but content is not available in the validated
        // cache — automatically clear and re-fetch instead of staying stuck.
        if newState == .ready, !isContentAvailable {
            return .resetAndRefetchChapter(changedChapterIndex)
        }
        guard isContentAvailable, newState == .ready else { return .none }
        if usesCoreText {
            return .notifyChapterDataChanged(currentChapterIndex)
        } else {
            return .rebuildPages
        }
    }
}
