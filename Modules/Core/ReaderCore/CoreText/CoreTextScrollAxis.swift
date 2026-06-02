import UIKit

enum CoreTextScrollAxis: Equatable {
    case vertical
    case horizontalRTL

    var isHorizontalRTL: Bool {
        self == .horizontalRTL
    }

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
