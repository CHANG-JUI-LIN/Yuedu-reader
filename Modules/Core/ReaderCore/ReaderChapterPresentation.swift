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
        case .idle, .loading, .cancelled:
            // `.cancelled` shows the loading surface, not a failure: the fetch was
            // preempted rather than answered, and `handleChapterStateChanges` re-requests
            // it. Painting 章節載入失敗 here is the bug users worked around by refreshing.
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


    /// Reconciles chapter-entry state with the renderer.
    ///
    /// A chapter can become cached while it is still offscreen. Its `.ready`
    /// publication is intentionally ignored at that point, so entering it later
    /// must replace any earlier cache-miss placeholder even though there is no new
    /// state transition to observe.
    public static func entryRefreshAction(
        chapterIndex: Int,
        usesCoreText: Bool,
        loadState: ChapterLoadState,
        isContentAvailable: Bool,
        isLayoutAvailable: Bool
    ) -> ReaderChapterRefreshAction {
        guard usesCoreText,
              loadState == .ready,
              isContentAvailable,
              !isLayoutAvailable
        else {
            return .none
        }
        return .notifyChapterDataChanged(chapterIndex)
    }
}
