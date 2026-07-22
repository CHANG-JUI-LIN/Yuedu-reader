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
}

public enum ReaderManualRefreshAction: Equatable {
    case relayoutCachedContent
    case fetchMissingContent
}

public enum ReaderChapterPresentation {
    public static func manualRefreshAction(
        isContentAvailable: Bool
    ) -> ReaderManualRefreshAction {
        isContentAvailable ? .relayoutCachedContent : .fetchMissingContent
    }

    public static func overlayState(isContentAvailable: Bool, loadState: ChapterLoadState?) -> ReaderChapterOverlayState {
        if isContentAvailable { return .hidden }
        guard let loadState = loadState else { return .loading }
        switch loadState {
        case .idle, .loading:
            return .loading
        case .failed(let reason):
            return .failed(message: reason)
        case .ready:
            // State claims ready but validated content is unavailable. Surface the
            // inconsistency and wait for an explicit retry; auto-refetching here loops
            // forever when the same validation failure repeats.
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
        guard isContentAvailable, newState == .ready else { return .none }
        if usesCoreText {
            return .notifyChapterDataChanged(currentChapterIndex)
        } else {
            return .rebuildPages
        }
    }
}
