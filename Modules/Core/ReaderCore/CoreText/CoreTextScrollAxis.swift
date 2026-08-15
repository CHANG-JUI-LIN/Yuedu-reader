import UIKit

enum CoreTextScrollAxis: Equatable {
    case vertical
    case horizontalRTL

    var isHorizontalRTL: Bool {
        self == .horizontalRTL
    }

    /// Scroll axis in `ReaderScrollLayout`'s own terms.
    var readerScrollLayoutAxis: ReaderScrollLayout.Axis {
        switch self {
        case .vertical:
            return .vertical
        case .horizontalRTL:
            return .horizontalRTL
        }
    }

    /// Used by the reader: `CoreTextCollectionScrollViewController` is on flow layout. The swap to
    /// `ReaderScrollLayout` was reverted, so an earlier version of this comment claiming otherwise
    /// was wrong. `ReaderScrollLayoutTests` also reads it, to stand a real flow layout next to the
    /// custom one and assert their geometry matches.
    var collectionScrollDirection: UICollectionView.ScrollDirection {
        switch self {
        case .vertical:
            return .vertical
        case .horizontalRTL:
            return .horizontal
        }
    }

    var semanticContentAttribute: UISemanticContentAttribute {
        switch self {
        case .vertical:
            return .unspecified
        case .horizontalRTL:
            return .forceRightToLeft
        }
    }

    var initialScrollPosition: UICollectionView.ScrollPosition {
        switch self {
        case .vertical:
            return .top
        case .horizontalRTL:
            return .right
        }
    }
}
