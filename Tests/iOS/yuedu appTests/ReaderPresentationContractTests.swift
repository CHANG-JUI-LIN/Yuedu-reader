import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct ReaderPresentationContractTests {
    @Test("maps app page turn styles to paging adapter descriptors")
    func mapsPageTurnStyleToAdapterDescriptor() {
        let slide = PageViewControllerPagingAdapterDescriptor(pageTurnStyle: .slide)
        #expect(slide.style == .slide)
        #expect(slide.transitionStyle == .scroll)
        #expect(!slide.disablesBuiltInSwipe)
        #expect(!slide.usesCoverOverlay)
        #expect(slide.spineLocation(isRTL: true) == .min)

        let curl = PageViewControllerPagingAdapterDescriptor(pageTurnStyle: .curl)
        #expect(curl.style == .curl)
        #expect(curl.transitionStyle == .pageCurl)
        #expect(!curl.disablesBuiltInSwipe)
        #expect(curl.spineLocation(isRTL: true) == .max)

        let cover = PageViewControllerPagingAdapterDescriptor(pageTurnStyle: .cover)
        #expect(cover.style == .cover)
        #expect(cover.transitionStyle == .scroll)
        #expect(cover.disablesBuiltInSwipe)
        #expect(cover.usesCoverOverlay)

        let none = PageViewControllerPagingAdapterDescriptor(pageTurnStyle: .none)
        #expect(none.style == .none)
        #expect(none.transitionStyle == .scroll)
        #expect(none.disablesBuiltInSwipe)
        #expect(!none.usesCoverOverlay)
    }

    @Test("curl virtual indices mirror when RTL uses a right-hand spine")
    func curlVirtualIndicesMirrorForRTLSpine() {
        #expect(ReaderCurlVirtualIndex.frontIndex(forGlobalPage: 3, isRTL: false) == 6)
        #expect(ReaderCurlVirtualIndex.backIndex(forLogicalPage: 3, isRTL: false) == 7)

        #expect(ReaderCurlVirtualIndex.frontIndex(forGlobalPage: 3, isRTL: true) == 7)
        #expect(ReaderCurlVirtualIndex.backIndex(forLogicalPage: 3, isRTL: true) == 6)
    }

    @Test("curl back page content follows logical reader direction")
    func curlBackPageContentFollowsLogicalReaderDirection() {
        #expect(ReaderCurlBackPageResolver.logicalPageIndex(targetPage: 4, visiblePage: 3) == 3)
        #expect(ReaderCurlBackPageResolver.contentPageIndex(logicalPageIndex: 3, totalPages: 6) == 4)

        #expect(ReaderCurlBackPageResolver.logicalPageIndex(targetPage: 2, visiblePage: 3) == 2)
        #expect(ReaderCurlBackPageResolver.contentPageIndex(logicalPageIndex: 2, totalPages: 6) == 3)

        #expect(ReaderCurlBackPageResolver.contentPageIndex(logicalPageIndex: -1, totalPages: 6) == nil)
        #expect(ReaderCurlBackPageResolver.contentPageIndex(logicalPageIndex: 5, totalPages: 6) == nil)
    }

    @Test("curl back pages stay opaque solid color but keep stable position identity")
    func curlBackPageStaysSolidColorWithStableIdentity() {
        let position = CoreTextReadingPosition(spineIndex: 2, charOffset: 64)
        let backPage = PageBackViewController(
            virtualIndex: 7,
            logicalPageIndex: 3,
            globalPageIndex: 4,
            backgroundColor: .white,
            readingPosition: position
        )

        backPage.loadViewIfNeeded()

        #expect(backPage.view.isOpaque)
        #expect(backPage.view.backgroundColor == .white)
        #expect(backPage.logicalPageIndex == 3)
        #expect(backPage.globalPageIndex == 4)
        #expect(backPage.coreTextReadingPosition == position)
    }

    @Test("session store keeps reader presentation state as a single update surface")
    func sessionStoreUpdatesPresentationState() {
        let appearance = ReaderAppearance(
            theme: .sepia,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 2,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 24,
            marginV: 28,
            footerHeight: 20,
            writingMode: .horizontal
        )
        let store = ReaderSessionStore(
            initialState: ReaderPresentationState(
                location: .chapterStart(0),
                direction: .ltr,
                spreadMode: .singlePage,
                viewportSize: CGSize(width: 320, height: 480),
                appearance: appearance,
                pagingStyle: .slide
            )
        )

        store.move(to: ReaderLocation(spineIndex: 3, charOffset: 42))
        store.switchPagingStyle(.curl)
        store.updateDirection(.rtl)
        store.updateViewport(CGSize(width: 390, height: 844))

        #expect(store.state.location == ReaderLocation(spineIndex: 3, charOffset: 42))
        #expect(store.state.pagingStyle == .curl)
        #expect(store.state.direction == .rtl)
        #expect(store.state.viewportSize == CGSize(width: 390, height: 844))
    }

    @Test("reader location decodes v1 persisted payloads without metadata")
    func readerLocationDecodesLegacyPayload() throws {
        let data = try #require(#"{"spineIndex":2,"charOffset":128}"#.data(using: .utf8))
        let location = try JSONDecoder().decode(ReaderLocation.self, from: data)

        #expect(location.spineIndex == 2)
        #expect(location.charOffset == 128)
        #expect(location.source == nil)
        #expect(location.isEstimated == false)
        #expect(location.progression == nil)
    }

    @Test("navigator owns live location and persists only through its store")
    func navigatorOwnsLiveLocation() async {
        let positionStore = InMemoryReadingPositionStore()
        let navigator = ReaderNavigator(
            initialState: ReaderPresentationState(
                location: .chapterStart(0),
                direction: .ltr,
                spreadMode: .singlePage,
                viewportSize: CGSize(width: 320, height: 480),
                appearance: ReaderAppearance(
                    theme: .sepia,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 2,
                    paragraphSpacing: 6,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 28,
                    footerHeight: 20,
                    writingMode: .horizontal
                ),
                pagingStyle: .slide
            ),
            positionStore: positionStore,
            bookId: "navigator-test"
        )

        navigator.jump(
            to: CoreTextReadingPosition(spineIndex: 4, charOffset: 96),
            pageIndex: 12,
            totalPages: 120
        )
        await navigator.flush()

        #expect(navigator.state.location == ReaderLocation(
            CoreTextReadingPosition(spineIndex: 4, charOffset: 96),
            source: .jump,
            progression: ReaderLocation.Progression(pageIndex: 12, totalPages: 120, fraction: 12.0 / 119.0)
        ))
        #expect(await positionStore.load(for: "navigator-test") == CoreTextReadingPosition(spineIndex: 4, charOffset: 96))
    }

    @Test("session coordinator owns transition queue and page-turn effects")
    func sessionCoordinatorOwnsTransitionQueue() {
        let coordinator = makeSessionCoordinator(bookId: "coordinator-transition")

        let first = coordinator.send(.pageTurnRequested(targetPage: 11, visiblePage: 10))
        #expect(first == [.requestPageTransition(targetPage: 11)])
        #expect(coordinator.isPageTransitioning)

        let second = coordinator.send(.pageTurnRequested(targetPage: 12, visiblePage: 10))
        #expect(second.isEmpty)

        let settled = coordinator.send(.pageTransitionSettled(visiblePage: 11))
        #expect(settled == [
            .warmUpNext(currentGlobalPage: 11),
            .requestPageTransition(targetPage: 12)
        ])
        #expect(!coordinator.isPageTransitioning)

        #expect(coordinator.send(.warmUpNext(currentGlobalPage: 12)) == [
            .warmUpNext(currentGlobalPage: 12)
        ])
    }

    @Test("session coordinator routes location actions through navigator")
    func sessionCoordinatorRoutesLocationActions() async {
        let store = InMemoryReadingPositionStore()
        let coordinator = makeSessionCoordinator(bookId: "coordinator-location", positionStore: store)
        let position = CoreTextReadingPosition(spineIndex: 2, charOffset: 64)

        let effects = coordinator.send(.jumpToPosition(
            position: position,
            pageIndex: 5,
            totalPages: 40,
            isEstimated: false
        ))
        #expect(effects == [.persistPosition(position)])

        await coordinator.navigator.flush()

        #expect(coordinator.state.location == ReaderLocation(
            position,
            source: .jump,
            progression: ReaderLocation.Progression(pageIndex: 5, totalPages: 40, fraction: 5.0 / 39.0)
        ))
        #expect(await store.load(for: "coordinator-location") == position)
    }

    private func makeSessionCoordinator(
        bookId: String,
        positionStore: InMemoryReadingPositionStore = InMemoryReadingPositionStore()
    ) -> ReaderSessionCoordinator {
        ReaderSessionCoordinator(navigator: ReaderNavigator(
            initialState: ReaderPresentationState(
                location: .chapterStart(0),
                direction: .ltr,
                spreadMode: .singlePage,
                viewportSize: CGSize(width: 320, height: 480),
                appearance: ReaderAppearance(
                    theme: .sepia,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 2,
                    paragraphSpacing: 6,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 28,
                    footerHeight: 20,
                    writingMode: .horizontal
                ),
                pagingStyle: .slide
            ),
            positionStore: positionStore,
            bookId: bookId
        ))
    }
}

private final class InMemoryReadingPositionStore: ReadingPositionStore, @unchecked Sendable {
    private var storage: [String: CoreTextReadingPosition] = [:]

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        storage[bookId] = position
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        storage[bookId]
    }

    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        storage[bookId]
    }

    func flush(for bookId: String) async {
    }
}
