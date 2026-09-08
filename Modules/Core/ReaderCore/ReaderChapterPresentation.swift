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

/// A load-state publication announces availability; it does not replace the bytes
/// already being consumed by a renderer. Explicit refetches and edits replace them.
enum ReaderChapterContentUpdate {
    case available
    case replaced

    /// Returns whether the visible page needs to be placed after supply. An already
    /// installed chapter must keep its current page and document revision.
    @MainActor
    func supply(to engine: any PageRenderingProvider, chapterIndex: Int) async -> Bool {
        let start = SourcePerfTrace.now
        switch self {
        case .available:
            let outcome = await engine.notifyChapterDataAvailable(at: chapterIndex)
            SourcePerfTrace.record(
                "reader.chapter.available", "spine=\(chapterIndex) outcome=\(outcome.rawValue)",
                since: start, thresholdMs: 0
            )
            return outcome != .alreadyLaidOut
        case .replaced:
            await engine.notifyChapterDataChanged(at: chapterIndex)
            SourcePerfTrace.record(
                "reader.chapter.replaced", "spine=\(chapterIndex)",
                since: start, thresholdMs: 0
            )
            return true
        }
    }
}

public enum ReaderChapterPresentation {
    /// Only the chapter being read may advance the network prefetch window.
    /// A volume header or an offscreen prefetch completing must not recursively
    /// queue its neighbors ahead of the reader's current chapter on the source session.
    static func adjacentPrefetchCenter(
        readyChapterIndex: Int,
        currentChapterIndex: Int
    ) -> Int? {
        readyChapterIndex == currentChapterIndex ? currentChapterIndex : nil
    }

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
