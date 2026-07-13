import Testing
import Foundation
import CoreGraphics
import SwiftUI
import UIKit
@testable import yuedu_app

@Suite("ReaderCardTransitionMath", .serialized)
struct ReaderCardTransitionMathTests {

    // MARK: Progress clamping & conversion

    @Test("pop percentage converts to open-state progress and back")
    func popPercentageRoundTrip() {
        // pop 0  = reader fully open  -> progress 1
        // pop 1  = reader fully closed -> progress 0
        #expect(ReaderCardTransitionMath.openProgress(fromPopPercentage: 0) == 1)
        #expect(ReaderCardTransitionMath.openProgress(fromPopPercentage: 1) == 0)
        #expect(ReaderCardTransitionMath.openProgress(fromPopPercentage: 0.5) == 0.5)

        // The inverse is symmetric.
        #expect(ReaderCardTransitionMath.popPercentage(fromOpenProgress: 1) == 0)
        #expect(ReaderCardTransitionMath.popPercentage(fromOpenProgress: 0) == 1)
    }

    @Test("out-of-range values are clamped to 0...1")
    func clampsOutOfRange() {
        #expect(ReaderCardTransitionMath.openProgress(fromPopPercentage: -0.4) == 1)
        #expect(ReaderCardTransitionMath.openProgress(fromPopPercentage: 1.7) == 0)
        #expect(ReaderCardTransitionMath.clampProgress(1.5) == 1)
        #expect(ReaderCardTransitionMath.clampProgress(-0.2) == 0)
    }

    // MARK: Finish / cancel decisions

    @Test("release before twenty-percent close progress restores the open reader")
    func releaseBeforeThresholdCancels() {
        #expect(!ReaderCardTransitionMath.shouldFinishClose(
            closeProgress: 0.19,
            velocity: 0
        ))
    }

    @Test("release at twenty-percent close progress commits the close")
    func releaseAtThresholdFinishes() {
        #expect(ReaderCardTransitionMath.shouldFinishClose(
            closeProgress: 0.20,
            velocity: 0
        ))
    }

    @Test("fast outward flick commits before the distance threshold")
    func outwardVelocityFinishes() {
        #expect(ReaderCardTransitionMath.shouldFinishClose(
            closeProgress: 0.05,
            velocity: ReaderCardTransitionMath.closeVelocityThreshold
        ))
    }

    @Test("fast reverse flick restores even after the distance threshold")
    func reverseVelocityCancels() {
        #expect(!ReaderCardTransitionMath.shouldFinishClose(
            closeProgress: 0.40,
            velocity: -ReaderCardTransitionMath.closeVelocityThreshold
        ))
    }

    @Test("a small cancellation remains visible for the minimum settle duration")
    func smallCancellationUsesMinimumSettleDuration() {
        let transitionDuration: TimeInterval = 0.62
        let minimumSettleDuration: TimeInterval = 0.20
        let closeProgress: CGFloat = 0.05
        let speed = ReaderCardTransitionMath.cancellationCompletionSpeed(
            closeProgress: closeProgress,
            transitionDuration: transitionDuration,
            minimumSettleDuration: minimumSettleDuration
        )
        let resultingDuration = transitionDuration * Double(closeProgress / speed)

        #expect(abs(resultingDuration - minimumSettleDuration) < 0.001)
    }

    @Test("cancel settle replays the open-book timeline back to fully open")
    func cancellationSettleReturnsToOpen() {
        let startOpenProgress: CGFloat = 0.81

        let start = ReaderCardTransitionMath.cancellationOpenProgress(
            from: startOpenProgress,
            timeFraction: 0
        )
        let middle = ReaderCardTransitionMath.cancellationOpenProgress(
            from: startOpenProgress,
            timeFraction: 0.5
        )
        let end = ReaderCardTransitionMath.cancellationOpenProgress(
            from: startOpenProgress,
            timeFraction: 1
        )

        #expect(start == startOpenProgress)
        #expect(middle > ReaderCardTransitionMath.lerp(startOpenProgress, 1, 0.5))
        #expect(end == 1)
    }

    // MARK: Edge start region

    @Test("first touches inside the edge strip are accepted")
    func edgeStartAccepts() {
        let width: CGFloat = 390
        #expect(ReaderCardTransitionMath.isWithinEdgeStart(pointX: 0, containerWidth: width))
        #expect(ReaderCardTransitionMath.isWithinEdgeStart(pointX: 5, containerWidth: width))
        // A finger entering from the bezel is first sampled well inside the
        // screen; observed legitimate swipes reported 8–18pt.
        #expect(ReaderCardTransitionMath.isWithinEdgeStart(pointX: 18, containerWidth: width))
        #expect(ReaderCardTransitionMath.isWithinEdgeStart(
            pointX: ReaderCardTransitionMath.edgeStartWidth,
            containerWidth: width
        ))
    }

    @Test("points beyond the edge strip are rejected")
    func edgeStartRejects() {
        let width: CGFloat = 390
        #expect(!ReaderCardTransitionMath.isWithinEdgeStart(
            pointX: ReaderCardTransitionMath.edgeStartWidth + 1,
            containerWidth: width
        ))
        #expect(!ReaderCardTransitionMath.isWithinEdgeStart(pointX: 100, containerWidth: width))
        // Negative / before-edge touches are also rejected.
        #expect(!ReaderCardTransitionMath.isWithinEdgeStart(pointX: -1, containerWidth: width))
        // A non-positive container width rejects everything.
        #expect(!ReaderCardTransitionMath.isWithinEdgeStart(pointX: 5, containerWidth: 0))
    }

    // MARK: Phase interpolation

    @Test("phase ramps inside its range and clamps outside")
    func phaseRamp() {
        #expect(ReaderCardTransitionMath.phase(-0.2, in: 0.15...0.70) == 0)
        #expect(ReaderCardTransitionMath.phase(0.15, in: 0.15...0.70) == 0)
        #expect(ReaderCardTransitionMath.phase(0.425, in: 0.15...0.70) == 0.5)
        #expect(ReaderCardTransitionMath.phase(0.70, in: 0.15...0.70) == 1)
        #expect(ReaderCardTransitionMath.phase(0.9, in: 0.15...0.70) == 1)
        // Degenerate range collapses to a step at the upper bound.
        #expect(ReaderCardTransitionMath.phase(0.3, in: 0.3...0.3) == 1)
        #expect(ReaderCardTransitionMath.phase(0.2, in: 0.3...0.3) == 0)
    }

    @Test("lerp clamps the parameter")
    func lerpClamps() {
        #expect(ReaderCardTransitionMath.lerp(0, 100, 0.5) == 50)
        #expect(ReaderCardTransitionMath.lerp(0, 100, -1) == 0)
        #expect(ReaderCardTransitionMath.lerp(0, 100, 2) == 100)
    }

    @Test("rect lerp interpolates each component and clamps")
    func rectLerp() {
        let a = CGRect(x: 10, y: 20, width: 30, height: 40)
        let b = CGRect(x: 0, y: 0, width: 390, height: 844)
        let mid = ReaderCardTransitionMath.lerp(a, b, 0.5)
        #expect(mid.minX == 5)
        #expect(mid.minY == 10)
        #expect(mid.width == 210)
        #expect(mid.height == 442)
        let over = ReaderCardTransitionMath.lerp(a, b, 1.5)
        #expect(over == b)
    }

    // MARK: Visual state interpolation

    @Test("visual state interpolates frame and radius across the transition")
    func visualStateFrameAndRadius() {
        let sourceFrame = CGRect(x: 16, y: 100, width: 90, height: 135)
        let destFrame   = CGRect(x: 0, y: 0, width: 390, height: 844)
        let source = ReaderCardGeometry(frame: sourceFrame, cornerRadius: 8)
        let dest   = ReaderCardGeometry(frame: destFrame, cornerRadius: 0)

        let s0 = ReaderCardVisualState.interpolate(progress: 0, source: source, destination: dest)
        // Closed: at source geometry, no reader content visible.
        #expect(s0.frame == sourceFrame)
        #expect(s0.cornerRadius == 8)
        #expect(s0.contentOpacity == 0)

        let s1 = ReaderCardVisualState.interpolate(progress: 1, source: source, destination: dest)
        // Open: full-screen, no rounding, reader content fully revealed.
        #expect(s1.frame == destFrame)
        #expect(s1.cornerRadius == 0)
        #expect(s1.contentOpacity == 1)

        // Reader content only appears in the final phase (>= 0.55).
        let early = ReaderCardVisualState.interpolate(progress: 0.4, source: source, destination: dest)
        #expect(early.contentOpacity == 0)
    }

    @Test("visual state is continuous under reversal")
    func visualStateContinuous() {
        let source = ReaderCardGeometry(frame: CGRect(x: 0, y: 0, width: 50, height: 70), cornerRadius: 10)
        let dest   = ReaderCardGeometry(frame: CGRect(x: 0, y: 0, width: 400, height: 800), cornerRadius: 0)

        // Stepping forward and backward should produce monotonic frame widths
        // (no discontinuity) and matching values at symmetric progress points.
        let forward = ReaderCardVisualState.interpolate(progress: 0.6, source: source, destination: dest)
        let reverse = ReaderCardVisualState.interpolate(progress: 0.6, source: dest, destination: source)
        // 0.6 into source->dest == 0.6 into dest->source only for frame lerp;
        // other properties use absolute progress so they should still equal.
        #expect(forward.contentOpacity == reverse.contentOpacity)
        #expect(forward.shadowOpacity == reverse.shadowOpacity)
    }

    // MARK: Predominantly-horizontal gate

    @Test("vertical-dominant drags fail the horizontal gate")
    func verticalGate() {
        #expect(ReaderCardTransitionMath.isPredominantlyHorizontal(dx: 40, dy: 10))
        #expect(!ReaderCardTransitionMath.isPredominantlyHorizontal(dx: 5, dy: 60))
        #expect(ReaderCardTransitionMath.isPredominantlyHorizontal(dx: 30, dy: 30))
    }

    @Test("edge swipe begins only for a rightward horizontal drag started at the edge")
    func edgeSwipePolicy() {
        let width: CGFloat = 390

        #expect(ReaderCardTransitionMath.shouldBeginEdgeSwipe(
            initialX: 6,
            translationX: 18,
            translationY: 3,
            containerWidth: width
        ))
        // A screen-edge recognizer asks its delegate before any translation
        // accumulates; the system edge decision stands in for direction.
        #expect(ReaderCardTransitionMath.shouldBeginEdgeSwipe(
            initialX: 8,
            translationX: 0,
            translationY: 0,
            containerWidth: width
        ))
        #expect(!ReaderCardTransitionMath.shouldBeginEdgeSwipe(
            initialX: ReaderCardTransitionMath.edgeStartWidth + 1,
            translationX: 18,
            translationY: 3,
            containerWidth: width
        ))
        #expect(!ReaderCardTransitionMath.shouldBeginEdgeSwipe(
            initialX: 6,
            translationX: -18,
            translationY: 3,
            containerWidth: width
        ))
        #expect(!ReaderCardTransitionMath.shouldBeginEdgeSwipe(
            initialX: 6,
            translationX: 8,
            translationY: 20,
            containerWidth: width
        ))
    }

    @Test("rightward translation produces clamped interactive-pop progress")
    func edgeSwipeProgress() {
        #expect(ReaderCardTransitionMath.popProgress(translationX: 0, containerWidth: 400) == 0)
        #expect(ReaderCardTransitionMath.popProgress(translationX: 100, containerWidth: 400) == 0.25)
        #expect(ReaderCardTransitionMath.popProgress(translationX: 500, containerWidth: 400) == 1)
        #expect(ReaderCardTransitionMath.popProgress(translationX: -40, containerWidth: 400) == 0)
        #expect(ReaderCardTransitionMath.popProgress(translationX: 40, containerWidth: 0) == 0)
    }

    // MARK: Source geometry resolution

    @Test("transition source resolves geometry or returns nil for fallback")
    func sourceGeometryResolution() {
        let source = ReaderTransitionSource(
            bookID: UUID(),
            cornerRadius: 8,
            frame: CGRect(x: 0, y: 0, width: 90, height: 135)
        )
        #expect(source.hasGeometry)
        let geo = source.resolveGeometry()
        #expect(geo != nil)
        #expect(geo?.cornerRadius == 8)

        let fallback = ReaderTransitionSource.fallback(bookID: UUID())
        #expect(!fallback.hasGeometry)
        #expect(fallback.resolveGeometry() == nil)
    }

    @Test("live source frame wins over the tap-time fallback frame")
    @MainActor
    func liveSourceFrameResolution() {
        var currentFrame: CGRect? = CGRect(x: 20, y: 40, width: 90, height: 135)
        let fallbackFrame = CGRect(x: 8, y: 12, width: 45, height: 65)
        let source = ReaderTransitionSource(
            bookID: UUID(),
            frame: fallbackFrame,
            frameProvider: { currentFrame }
        )

        #expect(source.resolvedFrame() == currentFrame)
        currentFrame = CGRect(x: 120, y: 70, width: 90, height: 135)
        #expect(source.resolvedFrame() == currentFrame)
        currentFrame = nil
        #expect(source.resolvedFrame(allowingTapFallback: false) == nil)
        #expect(source.resolvedFrame(allowingTapFallback: true) == fallbackFrame)
    }
}

@Suite("EPUBOpeningFlow", .serialized)
struct EPUBOpeningFlowTests {
    @Test("CSS-only vertical writing mode is detected before opening")
    func detectsVerticalCSS() {
        #expect(EPUBOpeningFlow.containsVerticalWritingModeDeclaration(
            in: "body { writing-mode: vertical-rl; }"
        ))
        #expect(EPUBOpeningFlow.containsVerticalWritingModeDeclaration(
            in: ".book { -webkit-writing-mode: vertical-rl }"
        ))
        #expect(!EPUBOpeningFlow.containsVerticalWritingModeDeclaration(
            in: "body { writing-mode: horizontal-tb; }"
        ))
    }
}

@Suite("ReaderBookOpeningDirection", .serialized)
struct ReaderBookOpeningDirectionTests {
    @Test("writing direction resolves to the physical spine side")
    func resolvesSpineSide() {
        #expect(ReaderBookOpeningDirection.resolve(
            writingMode: .horizontal,
            pageProgressionIsRTL: false
        ) == .leftSpine)
        #expect(ReaderBookOpeningDirection.resolve(
            writingMode: .horizontal,
            pageProgressionIsRTL: true
        ) == .rightSpine)
        #expect(ReaderBookOpeningDirection.resolve(
            writingMode: .verticalRTL,
            pageProgressionIsRTL: false
        ) == .rightSpine)
    }

    @Test("left-spine and right-spine opening poses are mirrored")
    func mirroredOpeningPoses() {
        let left = ReaderBookOpeningPose.interpolate(progress: 0.55, direction: .leftSpine)
        let right = ReaderBookOpeningPose.interpolate(progress: 0.55, direction: .rightSpine)

        #expect(left.coverAnchorX == 0)
        #expect(right.coverAnchorX == 1)
        #expect(left.coverRotationY == -right.coverRotationY)
        // Left spine hinges the cover leftward (negative Y rotation).
        #expect(left.coverRotationY < 0)
    }

    @Test("mid-opening pose reads as a physical book")
    func physicalBookPoseAtMidOpening() {
        let pose = ReaderBookOpeningPose.interpolate(progress: 0.55, direction: .leftSpine)

        // The cover is clearly lifting but has not yet passed perpendicular —
        // it stays visible through most of the motion.
        #expect(abs(pose.coverRotationY) > .pi / 5)
        #expect(abs(pose.coverRotationY) < .pi / 2)
        #expect(pose.coverOpacity == 1)
        #expect(pose.spineShadowOpacity > 0)
    }

    @Test("spine shadow fades at both endpoints and mirrors across directions")
    func spineShadowEndpointsAndDirection() {
        let closed = ReaderBookOpeningPose.interpolate(progress: 0, direction: .leftSpine)
        let open = ReaderBookOpeningPose.interpolate(progress: 1, direction: .leftSpine)
        let left = ReaderBookOpeningPose.interpolate(progress: 0.55, direction: .leftSpine)
        let right = ReaderBookOpeningPose.interpolate(progress: 0.55, direction: .rightSpine)

        #expect(closed.spineShadowOpacity == 0)
        #expect(open.spineShadowOpacity == 0)
        #expect(left.spineShadowOpacity > 0)
        #expect(left.spineShadowOpacity == right.spineShadowOpacity)
    }

    @Test("book pose moves continuously from closed to fully open")
    func bookPoseEndpoints() {
        let closed = ReaderBookOpeningPose.interpolate(progress: 0, direction: .leftSpine)
        let open = ReaderBookOpeningPose.interpolate(progress: 1, direction: .leftSpine)

        #expect(closed.coverRotationY == 0)
        #expect(closed.coverOpacity == 1)
        // Fully open: the cover has swung just past perpendicular and has
        // faded out entirely.
        #expect(abs(open.coverRotationY) > .pi / 2)
        #expect(open.coverOpacity == 0)
    }
}

@Suite("BookCardNavigationGate", .serialized)
struct BookCardNavigationGateTests {
    @Test("text/epub/html kinds are eligible for the card push path")
    func eligibleKinds() {
        #expect(BookCardNavigationGate.shouldUseCardTransition(for: Self.make(kind: .epub), idiom: .phone))
        #expect(BookCardNavigationGate.shouldUseCardTransition(for: Self.make(kind: .txt), idiom: .phone))
        #expect(BookCardNavigationGate.shouldUseCardTransition(for: Self.make(kind: .html), idiom: .phone))
    }

    @Test("audiobook, manga, and fixed-page stay on the modal path")
    func ineligibleKinds() {
        #expect(!BookCardNavigationGate.shouldUseCardTransition(for: Self.make(kind: .audio), idiom: .phone))
        #expect(!BookCardNavigationGate.shouldUseCardTransition(for: Self.make(kind: .manga), idiom: .phone))
        #expect(!BookCardNavigationGate.shouldUseCardTransition(for: Self.make(kind: .fixedPage), idiom: .phone))
    }

    @Test("iPad keeps the existing modal reader presentation")
    func iPadStaysModal() {
        #expect(!BookCardNavigationGate.shouldUseCardTransition(
            for: Self.make(kind: .epub),
            idiom: .pad
        ))
    }

    private static func make(kind: BookPipelineKind) -> ReadingBook {
        var book = ReadingBook(
            title: "T",
            author: "A",
            source: "local",
            contentFilename: "book"
        )
        book.isOnline = (kind == .html)
        book.contentPipelineKind = kind
        return book
    }
}

@Suite("ReaderNavigationCoordinator", .serialized)
@MainActor
struct ReaderNavigationCoordinatorTests {
    @Test("open queues its destination factory until the navigation controller attaches")
    func openQueuesUntilAttachment() {
        let coordinator = ReaderNavigationCoordinator()
        let id = UUID()
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        var destinationCreationCount = 0

        coordinator.open(
            bookID: id,
            source: ReaderTransitionSource(bookID: id),
            destination: {
                destinationCreationCount += 1
                return destination
            }
        )

        #expect(destinationCreationCount == 0)
        #expect(coordinator.activeBookID == id)
        #expect(!coordinator.isReaderPresented)

        coordinator.attach(to: navigationController)

        #expect(destinationCreationCount == 1)
        #expect(navigationController.topViewController === destination)
        #expect(navigationController.viewControllers.count == 2)
        #expect(coordinator.isReaderPresented)

        coordinator.attach(to: navigationController)
        #expect(destinationCreationCount == 1)
        coordinator.detachNavigationController()
    }

    @Test("clearSource keeps the reader mounted")
    func clearSourceKeepsReader() {
        let coordinator = ReaderNavigationCoordinator()
        let id = UUID()
        let navigationController = UINavigationController(
            rootViewController: UIViewController()
        )
        coordinator.attach(to: navigationController)
        coordinator.open(
            bookID: id,
            source: ReaderTransitionSource(bookID: id),
            destination: { UIViewController() }
        )
        coordinator.clearSource()
        #expect(coordinator.activeBookID == id)
        #expect(coordinator.isReaderPresented)
        coordinator.detachNavigationController()
    }

    @Test("open without geometry retains a centered transition source")
    func openWithoutSource() {
        let coordinator = ReaderNavigationCoordinator()
        let id = UUID()
        coordinator.open(bookID: id, destination: { UIViewController() })
        #expect(coordinator.activeBookID == id)
        #expect(coordinator.source?.bookID == id)
    }

    @Test("close before a queued push starts does not pretend the reader was popped")
    func closeBeforeAttachmentRetainsQueuedReader() {
        let coordinator = ReaderNavigationCoordinator()
        let id = UUID()
        coordinator.open(
            bookID: id,
            source: ReaderTransitionSource(
                bookID: id,
                frame: CGRect(x: 20, y: 40, width: 90, height: 135)
            ),
            destination: { UIViewController() }
        )
        coordinator.close()

        #expect(coordinator.activeBookID == id)
        #expect(!coordinator.isReaderPresented)
        #expect(coordinator.source?.bookID == id)
    }

    @Test("close during a driver-owned opening keeps the reader until push completion")
    func closeDuringPushRetainsReader() {
        let coordinator = ReaderNavigationCoordinator()
        let navigationController = DeferredPushNavigationController(
            root: UIViewController()
        )
        coordinator.attach(to: navigationController)
        let id = UUID()
        coordinator.open(
            bookID: id,
            source: ReaderTransitionSource(bookID: id),
            destination: { UIViewController() }
        )

        coordinator.close()

        #expect(coordinator.activeBookID == id)
        #expect(coordinator.isReaderPresented)
        #expect(coordinator.source?.bookID == id)
        coordinator.detachNavigationController()
    }

    @Test("a temporarily rejected push retries the same destination without losing the book")
    func rejectedPushRetriesSameDestination() {
        let coordinator = ReaderNavigationCoordinator()
        let destination = UIViewController()
        let navigationController = UINavigationController(rootViewController: destination)
        let id = UUID()
        var destinationCreationCount = 0
        coordinator.attach(to: navigationController)

        coordinator.open(
            bookID: id,
            source: ReaderTransitionSource(bookID: id),
            destination: {
                destinationCreationCount += 1
                return destination
            }
        )

        #expect(coordinator.activeBookID == id)
        #expect(!coordinator.isReaderPresented)
        #expect(destinationCreationCount == 1)

        navigationController.setViewControllers([UIViewController()], animated: false)
        coordinator.navigationTransitionDidSettle()

        #expect(navigationController.topViewController === destination)
        #expect(coordinator.isReaderPresented)
        #expect(destinationCreationCount == 1)
        coordinator.detachNavigationController()
    }
}

@Suite("ReaderNavigationTransitionDriver", .serialized)
@MainActor
struct ReaderNavigationTransitionDriverTests {
    @Test("navigation transition readiness requires an attached settled navigation controller")
    func readinessRequiresAttachment() {
        let driver = ReaderNavigationTransitionDriver()
        #expect(!driver.canStartNavigationTransition)

        let navigationController = UINavigationController(rootViewController: UIViewController())
        driver.attach(to: navigationController)
        defer { driver.detach() }

        #expect(driver.canStartNavigationTransition)
    }

    @Test("driver announces when UIKit navigation has settled")
    func didShowAnnouncesSettledNavigation() async {
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        let driver = ReaderNavigationTransitionDriver()
        var settleCount = 0
        driver.onNavigationTransitionSettled = { settleCount += 1 }
        driver.attach(to: navigationController)
        defer { driver.detach() }

        driver.navigationController(
            navigationController,
            didShow: root,
            animated: false
        )
        await Task.yield()

        #expect(settleCount == 1)
    }

    @Test("an unattached driver rejects direct push without mutating a navigation stack")
    func unattachedDriverRejectsDirectPush() {
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        let driver = ReaderNavigationTransitionDriver()

        #expect(!driver.startPush(destination, animated: false))
        #expect(navigationController.topViewController === root)
        #expect(navigationController.viewControllers.count == 1)
    }

    @Test("driver-owned direct push changes the attached UIKit navigation stack")
    func directPushChangesNavigationStack() {
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        let driver = ReaderNavigationTransitionDriver()
        driver.attach(to: navigationController)
        defer { driver.detach() }

        #expect(driver.startPush(destination, animated: false))
        #expect(navigationController.topViewController === destination)
        #expect(navigationController.viewControllers.count == 2)
    }

    @Test("driver-owned programmatic pop returns the attached UIKit stack to root")
    func directProgrammaticPopReturnsToRoot() {
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(destination, animated: false)
        let driver = ReaderNavigationTransitionDriver()
        driver.attach(to: navigationController)
        defer { driver.detach() }

        #expect(driver.startProgrammaticPop(animated: false))
        #expect(navigationController.topViewController === root)
        #expect(navigationController.viewControllers.count == 1)
    }

    @Test("didShow clears a direct push when UIKit skips the custom animator callback")
    func didShowReconcilesFallbackPush() {
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = DeferredPushNavigationController(root: root)
        let driver = ReaderNavigationTransitionDriver()
        var completionCount = 0
        var completion: Bool?
        driver.onPushTransitionCompleted = {
            completionCount += 1
            completion = $0
        }
        driver.attach(to: navigationController)
        defer { driver.detach() }

        #expect(driver.startPush(destination))
        driver.navigationController(
            navigationController,
            didShow: destination,
            animated: false
        )
        driver.navigationController(
            navigationController,
            didShow: destination,
            animated: false
        )

        #expect(completion == true)
        #expect(completionCount == 1)
    }

    @Test("didShow reports a direct fallback push as cancelled when the source remains visible")
    func didShowReconcilesCancelledFallbackPush() {
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = DeferredPushNavigationController(root: root)
        let driver = ReaderNavigationTransitionDriver()
        var completion: Bool?
        driver.onPushTransitionCompleted = { completion = $0 }
        driver.attach(to: navigationController)
        defer { driver.detach() }

        #expect(driver.startPush(destination))
        driver.navigationController(
            navigationController,
            didShow: root,
            animated: false
        )

        #expect(completion == false)
    }

    @Test("edge pop stays disabled until a driver-owned opening push settles")
    func openingPushBlocksInteractivePop() {
        let root = UIViewController()
        let destination = UIViewController()
        let navigationController = DeferredPushNavigationController(root: root)
        let driver = ReaderNavigationTransitionDriver()
        driver.attach(to: navigationController)
        defer { driver.detach() }

        #expect(driver.isReadyForInteractivePop)
        #expect(driver.startPush(destination))
        #expect(!driver.isReadyForInteractivePop)
    }

    @Test("custom reader transition does not mutate UIKit system pop state")
    func systemPopGestureOwnership() {
        let navigationController = UINavigationController(
            rootViewController: UIViewController()
        )
        let destination = UIViewController()
        let driver = ReaderNavigationTransitionDriver()
        driver.attach(to: navigationController)
        let wasEnabled = navigationController.interactivePopGestureRecognizer?.isEnabled

        #expect(driver.startPush(destination, animated: false))
        #expect(navigationController.interactivePopGestureRecognizer?.isEnabled == wasEnabled)

        driver.detach()
        #expect(navigationController.interactivePopGestureRecognizer?.isEnabled == wasEnabled)
    }
}

@MainActor
private final class DeferredPushNavigationController: UINavigationController {
    private(set) var requestedDestination: UIViewController?

    init(root: UIViewController) {
        super.init(rootViewController: root)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        requestedDestination = viewController
    }
}

@Suite("ReaderHostingController", .serialized)
@MainActor
struct ReaderHostingControllerTests {
    @Test("reader hosting controller hides the outer back item and bottom tab bar")
    func hidesOuterNavigationChrome() {
        let controller = ReaderHostingController(content: AnyView(EmptyView()))

        #expect(controller.navigationItem.hidesBackButton)
        #expect(controller.hidesBottomBarWhenPushed)
    }
}
