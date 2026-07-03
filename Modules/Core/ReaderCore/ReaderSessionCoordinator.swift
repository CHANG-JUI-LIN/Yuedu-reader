import Combine
import CoreGraphics
import UIKit

enum ReaderAction: Equatable {
    case restore
    case settlePage(
        position: CoreTextReadingPosition,
        pageIndex: Int?,
        totalPages: Int?,
        persist: Bool
    )
    case scrollCommit(position: CoreTextReadingPosition)
    case jumpToPosition(
        position: CoreTextReadingPosition,
        pageIndex: Int?,
        totalPages: Int?,
        isEstimated: Bool
    )
    case switchMode(position: CoreTextReadingPosition)
    case updateAppearance(ReaderAppearance)
    case updateViewport(CGSize)
    case updateDirection(ReaderReadingDirection)
    case updateSpreadMode(ReaderSpreadMode)
    case updatePagingStyle(ReaderPagingStyle)
    case pageTurnRequested(targetPage: Int, visiblePage: Int)
    case pageTransitionSettled(visiblePage: Int)
    case chapterReady(Int?)
    case warmUpNext(currentGlobalPage: Int)
    case internalLinkResolved(position: CoreTextReadingPosition, pageIndex: Int?, totalPages: Int?)
    case clearExternalTarget
}

enum ReaderEffect: Equatable {
    case persistPosition(CoreTextReadingPosition)
    case requestPageTransition(targetPage: Int)
    case warmUpNext(currentGlobalPage: Int)
    case invalidateLayout(ReaderInvalidationReason)
    case clearExternalTarget
    case publishPageChanged(pageIndex: Int, position: CoreTextReadingPosition?)
}

@MainActor
final class ReaderSessionCoordinator: ObservableObject {
    let navigator: ReaderNavigator

    private var transitionQueue = ReaderPageTransitionQueue()
    var externalTargetPosition: CoreTextReadingPosition? {
        navigator.externalTargetPosition
    }

    init(navigator: ReaderNavigator) {
        self.navigator = navigator
    }

    var state: ReaderPresentationState {
        navigator.state
    }

    var isPageTransitioning: Bool {
        transitionQueue.isTransitioning
    }

    @discardableResult
    func restore() async -> ReaderLocation {
        await navigator.restore()
    }

    @discardableResult
    func restoreSync() -> ReaderLocation {
        navigator.restoreSync()
    }

    func setExternalTarget(_ position: CoreTextReadingPosition?) {
        if let position {
            navigator.go(to: position)
        } else {
            navigator.clearExternalTarget()
        }
    }

    @discardableResult
    func clearExternalTarget() -> [ReaderEffect] {
        navigator.clearExternalTarget()
        return [.clearExternalTarget]
    }

    func beginInteractivePageTransition() {
        transitionQueue.beginInteractiveTransition()
    }

    func resetPageTransitionQueue() {
        transitionQueue.reset()
    }

    @discardableResult
    func send(_ action: ReaderAction) -> [ReaderEffect] {
        switch action {
        case .restore:
            return []

        case let .settlePage(position, pageIndex, totalPages, persist):
            navigator.settle(
                at: position,
                pageIndex: pageIndex,
                totalPages: totalPages,
                persist: persist
            )
            return persist ? [.persistPosition(position)] : []

        case let .scrollCommit(position):
            navigator.scrollCommit(to: position)
            return [.persistPosition(position)]

        case let .jumpToPosition(position, pageIndex, totalPages, isEstimated):
            navigator.jump(
                to: position,
                pageIndex: pageIndex,
                totalPages: totalPages,
                isEstimated: isEstimated
            )
            return [.persistPosition(position)]

        case let .switchMode(position):
            navigator.switchMode(to: position)
            return [.persistPosition(position)]

        case let .updateAppearance(appearance):
            navigator.updateAppearance(appearance)
            return []

        case let .updateViewport(size):
            navigator.updateViewport(size)
            return []

        case let .updateDirection(direction):
            navigator.updateDirection(direction)
            return []

        case let .updateSpreadMode(spreadMode):
            navigator.updateSpreadMode(spreadMode)
            return []

        case let .updatePagingStyle(style):
            navigator.switchPagingStyle(style)
            return []

        case let .pageTurnRequested(targetPage, visiblePage):
            switch transitionQueue.requestTransition(to: targetPage, visiblePage: visiblePage) {
            case .ignore, .deferUntilCurrentTransitionFinishes:
                return []
            case .startImmediately:
                return [.requestPageTransition(targetPage: targetPage)]
            }

        case let .pageTransitionSettled(visiblePage):
            var effects: [ReaderEffect] = [.warmUpNext(currentGlobalPage: visiblePage)]
            if let queuedPage = transitionQueue.transitionFinished(showing: visiblePage) {
                effects.append(.requestPageTransition(targetPage: queuedPage))
            }
            return effects

        case .chapterReady:
            return []

        case let .warmUpNext(currentGlobalPage):
            return [.warmUpNext(currentGlobalPage: currentGlobalPage)]

        case let .internalLinkResolved(position, pageIndex, totalPages):
            navigator.internalLink(to: position, pageIndex: pageIndex, totalPages: totalPages)
            return [.persistPosition(position)]

        case .clearExternalTarget:
            return clearExternalTarget()
        }
    }

    func performProgrammaticPageTransition(
        pageTurnStyle: PageTurnStyle,
        on controller: ProgrammaticPageTransitionControlling,
        targetViewController: UIViewController,
        targetViewControllers: [UIViewController]? = nil,
        direction: UIPageViewController.NavigationDirection,
        animated: Bool,
        restoringDataSource: UIPageViewControllerDataSource?,
        completion: @escaping (UIViewController) -> Void
    ) {
        ProgrammaticPageTransitionPerformer(pageTurnStyle: pageTurnStyle).perform(
            on: controller,
            targetViewController: targetViewController,
            targetViewControllers: targetViewControllers,
            direction: direction,
            animated: animated,
            restoringDataSource: restoringDataSource,
            completion: completion
        )
    }
}
