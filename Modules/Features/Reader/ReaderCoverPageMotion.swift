import UIKit

enum ReaderCoverTurnDirection: Equatable {
    case forward
    case backward
}

struct ReaderCoverPageMotion: Equatable {
    let direction: ReaderCoverTurnDirection
    let isRTL: Bool

    static func direction(for translationX: CGFloat, threshold: CGFloat, isRTL: Bool) -> ReaderCoverTurnDirection? {
        if isRTL {
            if translationX > threshold { return .forward }
            if translationX < -threshold { return .backward }
        } else {
            if translationX < -threshold { return .forward }
            if translationX > threshold { return .backward }
        }
        return nil
    }

    func initialX(width: CGFloat) -> CGFloat {
        switch direction {
        case .forward:
            return 0
        case .backward:
            return offscreenX(width: width)
        }
    }

    func interactiveX(progress: CGFloat, width: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 0.999)
        let offscreen = offscreenX(width: width)
        switch direction {
        case .forward:
            return offscreen * clamped
        case .backward:
            return offscreen * (1 - clamped)
        }
    }

    func settledX(width: CGFloat, shouldCommit: Bool) -> CGFloat {
        switch direction {
        case .forward:
            return shouldCommit ? offscreenX(width: width) : 0
        case .backward:
            return shouldCommit ? 0 : offscreenX(width: width)
        }
    }

    var movingEdgeCorners: CACornerMask {
        isRTL
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }

    var shadowOffset: CGSize {
        let ltrOffset: CGFloat = direction == .forward ? 10 : -10
        return CGSize(width: isRTL ? -ltrOffset : ltrOffset, height: 0)
    }

    private func offscreenX(width: CGFloat) -> CGFloat {
        (isRTL ? 1 : -1) * max(width, 1)
    }
}

struct PageViewControllerPagingAdapterDescriptor: Equatable {
    let style: ReaderPagingStyle
    let transitionStyle: UIPageViewController.TransitionStyle
    let disablesBuiltInSwipe: Bool
    let usesCoverOverlay: Bool
    let usesInstantPan: Bool

    init(pageTurnStyle: PageTurnStyle) {
        style = ReaderPagingStyle(pageTurnStyle: pageTurnStyle)
        switch pageTurnStyle {
        case .curl:
            transitionStyle = .pageCurl
            disablesBuiltInSwipe = false
            usesCoverOverlay = false
            usesInstantPan = false
        case .slide:
            transitionStyle = .scroll
            disablesBuiltInSwipe = false
            usesCoverOverlay = false
            usesInstantPan = false
        case .cover:
            transitionStyle = .scroll
            disablesBuiltInSwipe = true
            usesCoverOverlay = true
            usesInstantPan = false
        case .none:
            transitionStyle = .scroll
            disablesBuiltInSwipe = true
            usesCoverOverlay = false
            usesInstantPan = true
        }
    }

    func spineLocation(isRTL: Bool) -> UIPageViewController.SpineLocation {
        isRTL && (style == .curl || style == .cover) ? .max : .min
    }
}

enum ReaderCurlVirtualIndex {
    static func frontIndex(forGlobalPage page: Int, isRTL: Bool) -> Int {
        let base = max(0, page) * 2
        return isRTL ? base + 1 : base
    }

    static func backIndex(forLogicalPage page: Int, isRTL: Bool) -> Int {
        let base = max(0, page) * 2
        return isRTL ? base : base + 1
    }
}

enum ReaderCurlBackPageResolver {
    static func logicalPageIndex(targetPage: Int, visiblePage: Int) -> Int {
        targetPage >= visiblePage ? targetPage - 1 : targetPage
    }

    static func contentPageIndex(logicalPageIndex: Int, totalPages: Int) -> Int? {
        guard logicalPageIndex >= 0 else { return nil }
        let contentPage = logicalPageIndex + 1
        guard contentPage < totalPages else { return nil }
        return contentPage
    }
}
