import UIKit

struct ReaderResolvedPage {
    let pageIndex: Int
    let location: ReaderLocation
    let isPlaceholder: Bool
    let snapshot: UIImage?
}

enum ReaderBoundaryDirection: Equatable {
    case forward
    case backward
}

enum ReaderBoundaryReadiness: Equatable {
    case ready(target: ReaderLocation, pageIndex: Int)
    case placeholder(target: ReaderLocation, pageIndex: Int)
    case loading(target: ReaderLocation)
    case unavailable
}

enum ReaderInvalidationReason: Equatable {
    case viewportChanged(CGSize)
    case appearanceChanged(ReaderAppearance)
    case contentChanged(spineIndex: Int?)
    case directionChanged(ReaderReadingDirection)
}

@MainActor
protocol ReaderPageProvider: AnyObject {
    var totalPages: Int? { get }

    func prepare(viewportSize: CGSize, state: ReaderPresentationState) async
    func resolvePage(at index: Int) async -> ReaderResolvedPage?
    func resolvePage(at location: ReaderLocation) async -> ReaderResolvedPage?
    func resolveLocation(forPage index: Int) async -> ReaderLocation?
    func resolvePageIndex(for location: ReaderLocation) async -> Int?
    func prepareBoundary(from location: ReaderLocation, direction: ReaderBoundaryDirection) async -> ReaderBoundaryReadiness
    func adjacentLocation(from location: ReaderLocation, logicalForward: Bool) async -> ReaderLocation?
    func prefetch(around location: ReaderLocation, radius: Int) async
    func invalidate(reason: ReaderInvalidationReason) async
    func invalidateLayout(reason: ReaderInvalidationReason) async
}

@MainActor
final class LegacyCoreTextPageProvider: ReaderPageProvider {
    private let engine: any PageRenderingProvider
    private let bookId: String

    init(engine: any PageRenderingProvider, bookId: String) {
        self.engine = engine
        self.bookId = bookId
    }

    var totalPages: Int? {
        engine.totalPages
    }

    func prepare(viewportSize: CGSize, state: ReaderPresentationState) async {
        if engine.totalPages == 0 || engine.renderSize != viewportSize {
            await engine.start(renderSize: viewportSize, bookId: bookId)
        }
    }

    func resolvePage(at index: Int) async -> ReaderResolvedPage? {
        guard index >= 0, index < engine.totalPages else { return nil }
        let viewController = engine.pageViewController(at: index)
        let isPlaceholder = viewController is PlaceholderPageViewController
        let position = readingPosition(from: viewController)
            ?? engine.readingPosition(forPage: index)
            ?? CoreTextReadingPosition(
                spineIndex: engine.charOffset(forPage: index).spineIndex,
                charOffset: engine.charOffset(forPage: index).charOffset
            )
        return ReaderResolvedPage(
            pageIndex: index,
            location: ReaderLocation(
                position,
                source: isPlaceholder ? .placeholder : nil,
                isEstimated: isPlaceholder,
                progression: ReaderLocation.Progression(pageIndex: index, totalPages: engine.totalPages)
            ),
            isPlaceholder: isPlaceholder,
            snapshot: engine.renderSnapshot(forPage: index)
        )
    }

    func resolvePage(at location: ReaderLocation) async -> ReaderResolvedPage? {
        guard let index = engine.pageIndex(for: location.coreTextPosition) else { return nil }
        return await resolvePage(at: index)
    }

    func resolveLocation(forPage index: Int) async -> ReaderLocation? {
        await resolvePage(at: index)?.location
    }

    func resolvePageIndex(for location: ReaderLocation) async -> Int? {
        engine.pageIndex(for: location.coreTextPosition)
            ?? engine.estimatedGlobalPage(for: location.coreTextPosition)
    }

    func prepareBoundary(
        from location: ReaderLocation,
        direction: ReaderBoundaryDirection
    ) async -> ReaderBoundaryReadiness {
        let targetLocation: ReaderLocation
        switch direction {
        case .forward:
            guard let currentPage = await resolvePageIndex(for: location) else {
                return .loading(target: location)
            }
            let nextPage = currentPage + 1
            guard nextPage < engine.totalPages else { return .unavailable }
            if let position = engine.readingPosition(forPage: nextPage) {
                targetLocation = ReaderLocation(position)
            } else {
                let offset = engine.charOffset(forPage: nextPage)
                targetLocation = ReaderLocation(spineIndex: offset.spineIndex, charOffset: offset.charOffset)
            }
        case .backward:
            if location.charOffset == 0, location.spineIndex > 0 {
                targetLocation = ReaderLocation(
                    .chapterEnd(location.spineIndex - 1),
                    source: .placeholder,
                    isEstimated: true
                )
            } else {
                guard let currentPage = await resolvePageIndex(for: location) else {
                    return .loading(target: location)
                }
                let local = engine.localPosition(for: currentPage)
                if local.localPage == 0, local.spineIndex > 0 {
                    targetLocation = ReaderLocation(
                        .chapterEnd(local.spineIndex - 1),
                        source: .placeholder,
                        isEstimated: true
                    )
                } else {
                    let previousPage = currentPage - 1
                    guard previousPage >= 0 else { return .unavailable }
                    if let position = engine.readingPosition(forPage: previousPage) {
                        targetLocation = ReaderLocation(position)
                    } else {
                        let offset = engine.charOffset(forPage: previousPage)
                        targetLocation = ReaderLocation(spineIndex: offset.spineIndex, charOffset: offset.charOffset)
                    }
                }
            }
        }

        guard let targetPage = await resolvePageIndex(for: targetLocation) else {
            return .loading(target: targetLocation)
        }

        let viewController = engine.pageViewController(for: targetLocation.coreTextPosition)
        if viewController is PlaceholderPageViewController {
            return .placeholder(target: targetLocation, pageIndex: targetPage)
        }
        return .ready(target: targetLocation, pageIndex: targetPage)
    }

    func adjacentLocation(from location: ReaderLocation, logicalForward: Bool) async -> ReaderLocation? {
        guard let page = engine.pageIndex(for: location.coreTextPosition) else { return nil }
        let nextPage = logicalForward ? page + 1 : page - 1
        guard nextPage >= 0, nextPage < engine.totalPages else { return nil }
        guard let position = engine.readingPosition(forPage: nextPage) else { return nil }
        return ReaderLocation(position)
    }

    func prefetch(around location: ReaderLocation, radius: Int) async {
        guard radius > 0,
              let page = engine.pageIndex(for: location.coreTextPosition) else { return }
        engine.warmUpNext(currentGlobalPage: page)
    }

    func invalidate(reason: ReaderInvalidationReason) async {
        await invalidateLayout(reason: reason)
    }

    func invalidateLayout(reason: ReaderInvalidationReason) async {
        switch reason {
        case .viewportChanged(let size):
            await engine.invalidateLayout(newSize: size)
        case .appearanceChanged, .directionChanged:
            await engine.invalidateLayout(newSize: engine.renderSize)
        case .contentChanged(let spineIndex):
            if let spineIndex {
                await engine.notifyChapterDataChanged(at: spineIndex)
            } else {
                await engine.invalidateLayout(newSize: engine.renderSize)
            }
        }
    }

    private func readingPosition(from viewController: UIViewController) -> CoreTextReadingPosition? {
        if let provider = viewController as? CoreTextReadingPositionProviding {
            return provider.coreTextReadingPosition
        }
        if let provider = viewController as? PageIndexProviding {
            return engine.readingPosition(forPage: provider.globalPageIndex)
        }
        return nil
    }
}
