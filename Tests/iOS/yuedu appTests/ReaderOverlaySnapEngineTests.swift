import CoreGraphics
import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader overlay geometry")
struct ReaderOverlayGeometryTests {
    @Test("normalize and denormalize honor a nonzero bounds origin")
    func normalizeAndDenormalizeHonorBoundsOrigin() {
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 400)
        let normalized = ReaderOverlayNormalizedPoint(x: 0.25, y: 0.75)

        let point = ReaderOverlayGeometry.denormalize(normalized, in: bounds)

        #expect(point == CGPoint(x: 60, y: 320))
        #expect(ReaderOverlayGeometry.normalize(point, in: bounds) == normalized)
    }

    @Test("normalize falls back to center for unusable bounds")
    func normalizeFallsBackForUnusableBounds() {
        #expect(ReaderOverlayGeometry.normalize(
            CGPoint(x: 10, y: 20),
            in: CGRect(x: 10, y: 20, width: 0, height: 100)
        ) == ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5))
        #expect(ReaderOverlayGeometry.normalize(
            CGPoint(x: 10, y: 20),
            in: CGRect(x: 10, y: 20, width: 100, height: CGFloat.infinity)
        ) == ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test("normalize and denormalize round trip clamped points")
    func normalizeDenormalizeRoundTrip() {
        let bounds = CGRect(x: -80, y: 120, width: 320, height: 640)
        let normalized = ReaderOverlayNormalizedPoint(x: 1.4, y: -0.2)

        let roundTrip = ReaderOverlayGeometry.normalize(
            ReaderOverlayGeometry.denormalize(normalized, in: bounds),
            in: bounds
        )

        #expect(roundTrip == normalized.clamped)
    }

    @Test("clamp keeps every component edge inside the canvas")
    func clampKeepsEveryEdgeInsideCanvas() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 200)
        let size = CGSize(width: 20, height: 40)

        #expect(ReaderOverlayGeometry.clamp(
            center: CGPoint(x: 0, y: 0), size: size, to: bounds
        ) == CGPoint(x: 20, y: 40))
        #expect(ReaderOverlayGeometry.clamp(
            center: CGPoint(x: 200, y: 0), size: size, to: bounds
        ) == CGPoint(x: 100, y: 40))
        #expect(ReaderOverlayGeometry.clamp(
            center: CGPoint(x: 0, y: 300), size: size, to: bounds
        ) == CGPoint(x: 20, y: 200))
        #expect(ReaderOverlayGeometry.clamp(
            center: CGPoint(x: 200, y: 300), size: size, to: bounds
        ) == CGPoint(x: 100, y: 200))
    }

    @Test("oversized components center on each impossible axis")
    func oversizedComponentsCenterOnImpossibleAxes() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 200)

        #expect(ReaderOverlayGeometry.clamp(
            center: CGPoint(x: 5, y: 500),
            size: CGSize(width: 101, height: 201),
            to: bounds
        ) == CGPoint(x: 60, y: 120))
    }

    @Test("invalid clamp inputs never produce nonfinite coordinates")
    func invalidClampInputsRemainFinite() {
        let results = [
            ReaderOverlayGeometry.clamp(
                center: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                size: CGSize(width: -20, height: CGFloat.nan),
                to: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            ReaderOverlayGeometry.clamp(
                center: CGPoint(x: CGFloat.nan, y: -CGFloat.infinity),
                size: CGSize(width: CGFloat.infinity, height: -10),
                to: CGRect(
                    x: CGFloat.nan,
                    y: CGFloat.infinity,
                    width: -100,
                    height: CGFloat.nan
                )
            )
        ]

        #expect(results.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
}

@Suite("Reader overlay snap engine")
struct ReaderOverlaySnapEngineTests {
    private let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let bodyFrame = CGRect(x: 24, y: 34, width: 342, height: 778)

    @Test("body text boundaries snap component edges")
    func bodyBoundariesSnapComponentEdges() {
        var minimumSession = ReaderOverlaySnapSession()
        let minimum = resolve(
            proposedCenter: CGPoint(x: 45, y: 47),
            componentSize: CGSize(width: 40, height: 20),
            session: &minimumSession
        )
        var maximumSession = ReaderOverlaySnapSession()
        let maximum = resolve(
            proposedCenter: CGPoint(x: 345, y: 799),
            componentSize: CGSize(width: 40, height: 20),
            session: &maximumSession
        )

        #expect(minimum.center == CGPoint(x: 44, y: 44))
        #expect(minimum.guides == [.vertical(x: 24), .horizontal(y: 34)])
        #expect(maximum.center == CGPoint(x: 346, y: 802))
        #expect(maximum.guides == [.vertical(x: 366), .horizontal(y: 812)])
    }

    @Test("peer minimum midpoint and maximum lines match like alignments")
    func peerLinesMatchLikeAlignments() {
        let peer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: 100, y: 200, width: 100, height: 80)
        )
        var minimumSession = ReaderOverlaySnapSession()
        let minimum = resolve(
            proposedCenter: CGPoint(x: 121, y: 211),
            componentSize: CGSize(width: 40, height: 20),
            peers: [peer],
            session: &minimumSession
        )
        var midpointSession = ReaderOverlaySnapSession()
        let midpoint = resolve(
            proposedCenter: CGPoint(x: 149, y: 239),
            componentSize: CGSize(width: 40, height: 20),
            peers: [peer],
            session: &midpointSession
        )
        var maximumSession = ReaderOverlaySnapSession()
        let maximum = resolve(
            proposedCenter: CGPoint(x: 179, y: 269),
            componentSize: CGSize(width: 40, height: 20),
            peers: [peer],
            session: &maximumSession
        )

        #expect(minimum.center == CGPoint(x: 120, y: 210))
        #expect(minimum.guides == [.vertical(x: 100), .horizontal(y: 200)])
        #expect(midpoint.center == CGPoint(x: 150, y: 240))
        #expect(midpoint.guides == [.vertical(x: 150), .horizontal(y: 240)])
        #expect(maximum.center == CGPoint(x: 180, y: 270))
        #expect(maximum.guides == [.vertical(x: 200), .horizontal(y: 280)])
    }

    @Test("canvas and screen center are not standalone snap targets")
    func canvasAndScreenCenterAreNotTargets() {
        var session = ReaderOverlaySnapSession()
        let result = resolve(
            proposedCenter: CGPoint(x: canvas.midX, y: canvas.midY),
            componentSize: .zero,
            session: &session
        )

        #expect(result.center == CGPoint(x: canvas.midX, y: canvas.midY))
        #expect(result.guides.isEmpty)
    }

    @Test("a latched body guide remains stable while a peer becomes closer")
    func latchPreventsGuideTwitch() {
        let peer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: 31, y: 200, width: 20, height: 20)
        )
        var session = ReaderOverlaySnapSession()

        let acquired = resolve(
            proposedCenter: CGPoint(x: 24, y: 100),
            componentSize: .zero,
            peers: [peer],
            session: &session
        )
        let retained = resolve(
            proposedCenter: CGPoint(x: 31, y: 100),
            componentSize: .zero,
            peers: [peer],
            session: &session
        )

        #expect(acquired.center.x == 24)
        #expect(retained.center.x == 24)
        #expect(retained.guides == [.vertical(x: 24)])
    }

    @Test("a latch releases beyond hysteresis then acquires the nearest guide")
    func latchReleasesThenReacquires() {
        let peer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: 40, y: 200, width: 20, height: 20)
        )
        var session = ReaderOverlaySnapSession()
        _ = resolve(
            proposedCenter: CGPoint(x: 24, y: 100),
            componentSize: .zero,
            peers: [peer],
            session: &session
        )

        let result = resolve(
            proposedCenter: CGPoint(x: 40, y: 100),
            componentSize: .zero,
            peers: [peer],
            session: &session
        )

        #expect(result.center.x == 40)
        #expect(result.guides == [.vertical(x: 40)])
    }

    @Test("body boundaries win an equal-distance acquisition tie")
    func bodyBoundaryWinsTie() {
        let peer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: 30, y: 200, width: 20, height: 20)
        )
        var session = ReaderOverlaySnapSession()
        let result = resolve(
            proposedCenter: CGPoint(x: 27, y: 100),
            componentSize: .zero,
            peers: [peer],
            session: &session
        )

        #expect(result.center.x == 24)
        #expect(result.guides == [.vertical(x: 24)])
    }

    @Test("horizontal and vertical latches resolve independently")
    func axesResolveIndependently() {
        var session = ReaderOverlaySnapSession()
        let result = resolve(
            proposedCenter: CGPoint(x: 25, y: 36),
            componentSize: .zero,
            session: &session
        )

        #expect(result.center == CGPoint(x: 24, y: 34))
        #expect(result.guides == [.vertical(x: 24), .horizontal(y: 34)])
    }

    @Test("resetting a session removes the retained guide")
    func resetRemovesLatch() {
        var session = ReaderOverlaySnapSession()
        _ = resolve(
            proposedCenter: CGPoint(x: 24, y: 100),
            componentSize: .zero,
            session: &session
        )
        session.reset()

        let result = resolve(
            proposedCenter: CGPoint(x: 31, y: 100),
            componentSize: .zero,
            session: &session
        )

        #expect(result.center.x == 31)
        #expect(result.guides.isEmpty)
    }

    @Test("default snapping ignores a target four points away")
    func defaultSnappingRequiresPreciseProximity() {
        var session = ReaderOverlaySnapSession()
        let result = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: bodyFrame.minX + 4, y: 100),
            componentSize: .zero,
            canvas: canvas,
            bodyFrame: bodyFrame,
            peers: [],
            session: &session
        )

        #expect(result.center.x == bodyFrame.minX + 4)
        #expect(result.guides.isEmpty)
    }

    @Test("default latch releases after six points")
    func defaultLatchReleasesPromptly() {
        var session = ReaderOverlaySnapSession()
        _ = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: bodyFrame.minX, y: 100),
            componentSize: .zero,
            canvas: canvas,
            bodyFrame: bodyFrame,
            peers: [],
            session: &session
        )

        let result = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: bodyFrame.minX + 7, y: 100),
            componentSize: .zero,
            canvas: canvas,
            bodyFrame: bodyFrame,
            peers: [],
            session: &session
        )

        #expect(result.center.x == bodyFrame.minX + 7)
        #expect(result.guides.isEmpty)
    }

    @Test("invalid geometry never produces nonfinite output")
    func invalidGeometryIsSafe() {
        var session = ReaderOverlaySnapSession()
        let result = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            componentSize: CGSize(width: -10, height: CGFloat.nan),
            canvas: CGRect(x: 0, y: 0, width: -100, height: 0),
            bodyFrame: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20),
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)
                )
            ],
            session: &session,
            acquireDistance: CGFloat.infinity,
            releaseDistance: CGFloat.nan
        )

        #expect(result.center.x.isFinite)
        #expect(result.center.y.isFinite)
        #expect(result.guides.isEmpty)
    }

    @Test("body frame policy combines page margins and content reservations")
    func bodyFramePolicyUsesLayoutInsets() {
        let result = ReaderOverlayBodyFramePolicy.frame(
            in: canvas,
            horizontalPageMargin: 24,
            topReservation: 34,
            bottomReservation: 32
        )

        #expect(result == bodyFrame)
    }

    private func resolve(
        proposedCenter: CGPoint,
        componentSize: CGSize,
        peers: [ReaderOverlayPeerFrame] = [],
        session: inout ReaderOverlaySnapSession
    ) -> ReaderOverlaySnapResult {
        ReaderOverlaySnapEngine.resolve(
            proposedCenter: proposedCenter,
            componentSize: componentSize,
            canvas: canvas,
            bodyFrame: bodyFrame,
            peers: peers,
            session: &session,
            acquireDistance: 6,
            releaseDistance: 12
        )
    }

    private func fixtureUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
