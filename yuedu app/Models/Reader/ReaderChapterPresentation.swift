import Foundation

public enum ReaderOverlayState: Equatable {
    case hidden
    case loading
    case failed(message: String)
}

public enum ReaderRefreshAction: Equatable {
    case none
    case notifyChapterDataChanged(index: Int)
    case rebuildPages
}

public struct ReaderChapterPresentation: Equatable {
    public let chapterIndex: Int
    public let isCurrent: Bool
    public let hasContent: Bool
    public let isCoreText: Bool
    public let loadState: ChapterLoadState

    public init(chapterIndex: Int, isCurrent: Bool, hasContent: Bool, isCoreText: Bool, loadState: ChapterLoadState) {
        self.chapterIndex = chapterIndex
        self.isCurrent = isCurrent
        self.hasContent = hasContent
        self.isCoreText = isCoreText
        self.loadState = loadState
    }

    public var overlayState: ReaderOverlayState {
        if hasContent { return .hidden }
        switch loadState {
        case .idle, .loading:
            return .loading
        case .failed(let reason):
            return .failed(message: reason)
        case .ready:
            // If ready but content missing, treat as loading fallback
            return .loading
        }
    }

    public var refreshAction: ReaderRefreshAction {
        guard isCurrent, hasContent, loadState == .ready else { return .none }
        if isCoreText {
            return .notifyChapterDataChanged(index: chapterIndex)
        } else {
            return .rebuildPages
        }
    }
}
