import UIKit

enum ReaderTapZone {
    case leading
    case center
    case trailing
}

@MainActor
protocol ReaderPagingAdapter: AnyObject {
    var style: ReaderPagingStyle { get }
    var viewController: UIViewController { get }

    func bind(
        provider: ReaderPageProvider,
        session: ReaderSessionStore,
        delegate: ReaderPagingAdapterDelegate
    )
    func apply(state: ReaderPresentationState, animated: Bool)
    func jump(to location: ReaderLocation, animated: Bool)
    func cancelInFlightTransition()
    func teardown()
}

@MainActor
protocol ReaderPagingAdapterDelegate: AnyObject {
    func pagingAdapter(
        _ adapter: ReaderPagingAdapter,
        didSettleAt location: ReaderLocation,
        pageIndex: Int
    )

    func pagingAdapter(
        _ adapter: ReaderPagingAdapter,
        didRequestTapZone zone: ReaderTapZone
    )
}

struct PageViewControllerPagingAdapterDescriptor: Equatable {
    let style: ReaderPagingStyle
    let transitionStyle: UIPageViewController.TransitionStyle
    let disablesBuiltInSwipe: Bool
    let usesCoverOverlay: Bool

    init(pageTurnStyle: PageTurnStyle) {
        style = ReaderPagingStyle(pageTurnStyle: pageTurnStyle)
        switch pageTurnStyle {
        case .curl:
            transitionStyle = .pageCurl
            disablesBuiltInSwipe = false
            usesCoverOverlay = false
        case .slide:
            transitionStyle = .scroll
            disablesBuiltInSwipe = false
            usesCoverOverlay = false
        case .cover:
            transitionStyle = .scroll
            disablesBuiltInSwipe = true
            usesCoverOverlay = true
        case .none:
            transitionStyle = .scroll
            disablesBuiltInSwipe = true
            usesCoverOverlay = false
        }
    }

    func spineLocation(isRTL: Bool) -> UIPageViewController.SpineLocation {
        isRTL && style == .curl ? .max : .min
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
