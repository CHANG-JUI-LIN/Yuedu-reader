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

    @Test("screen center snapping resolves axes independently")
    func screenCenterSnappingResolvesAxesIndependently() {
        let vertical = resolve(
            proposedCenter: CGPoint(x: 194, y: 410),
            componentSize: CGSize(width: 80, height: 24)
        )
        let horizontal = resolve(
            proposedCenter: CGPoint(x: 120, y: 421),
            componentSize: CGSize(width: 80, height: 24)
        )

        #expect(vertical.center == CGPoint(x: 195, y: 410))
        #expect(vertical.guides == [.vertical(x: 195), .horizontal(y: 422)])
        #expect(horizontal.center == CGPoint(x: 120, y: 422))
        #expect(horizontal.guides == [.horizontal(y: 422)])
    }

    @Test("canvas minimum and maximum edges accept component edge alignment")
    func canvasMinAndMaxEdgesSnap() {
        let minimum = resolve(
            proposedCenter: CGPoint(x: 42, y: 34),
            componentSize: CGSize(width: 80, height: 64),
            threshold: 3
        )
        let maximum = resolve(
            proposedCenter: CGPoint(x: 348, y: 810),
            componentSize: CGSize(width: 80, height: 64),
            threshold: 3
        )

        #expect(minimum.center == CGPoint(x: 40, y: 32))
        #expect(minimum.guides == [.vertical(x: 0), .horizontal(y: 0)])
        #expect(maximum.center == CGPoint(x: 350, y: 812))
        #expect(maximum.guides == [.vertical(x: 390), .horizontal(y: 844)])
    }

    @Test("safe area minimum and maximum edges use the canvas intersection")
    func safeAreaEdgesUseCanvasIntersection() {
        let safeArea = CGRect(x: 20, y: 44, width: 350, height: 766)
        let minimum = resolve(
            proposedCenter: CGPoint(x: 42, y: 56),
            componentSize: CGSize(width: 40, height: 20),
            safeArea: safeArea,
            threshold: 3
        )
        let maximum = resolve(
            proposedCenter: CGPoint(x: 348, y: 798),
            componentSize: CGSize(width: 40, height: 20),
            safeArea: safeArea,
            threshold: 3
        )

        #expect(minimum.center == CGPoint(x: 40, y: 54))
        #expect(minimum.guides == [.vertical(x: 20), .horizontal(y: 44)])
        #expect(maximum.center == CGPoint(x: 350, y: 800))
        #expect(maximum.guides == [.vertical(x: 370), .horizontal(y: 810)])
    }

    @Test("safe area targets are calculated after clipping to the canvas")
    func safeAreaTargetsUseClippedRect() {
        let result = resolve(
            proposedCenter: CGPoint(x: 39, y: 100),
            componentSize: .zero,
            safeArea: CGRect(x: -20, y: 80, width: 100, height: 100),
            threshold: 2
        )

        #expect(result.center == CGPoint(x: 40, y: 100))
        #expect(result.guides == [.vertical(x: 40)])
    }

    @Test("peer minimum midpoint and maximum lines snap both component axes")
    func peerLinesSnapBothAxes() {
        let peer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: 100, y: 200, width: 100, height: 80)
        )
        let minimum = resolve(
            proposedCenter: CGPoint(x: 121, y: 211),
            componentSize: CGSize(width: 40, height: 20),
            peers: [peer],
            threshold: 3
        )
        let midpoint = resolve(
            proposedCenter: CGPoint(x: 149, y: 239),
            componentSize: CGSize(width: 40, height: 20),
            peers: [peer],
            threshold: 3
        )
        let maximum = resolve(
            proposedCenter: CGPoint(x: 179, y: 269),
            componentSize: CGSize(width: 40, height: 20),
            peers: [peer],
            threshold: 3
        )

        #expect(minimum.center == CGPoint(x: 120, y: 210))
        #expect(minimum.guides == [.vertical(x: 100), .horizontal(y: 200)])
        #expect(midpoint.center == CGPoint(x: 150, y: 240))
        #expect(midpoint.guides == [.vertical(x: 150), .horizontal(y: 240)])
        #expect(maximum.center == CGPoint(x: 180, y: 270))
        #expect(maximum.guides == [.vertical(x: 200), .horizontal(y: 280)])
    }

    @Test("candidates outside the threshold do not snap")
    func candidatesOutsideThresholdDoNotSnap() {
        let result = resolve(
            proposedCenter: CGPoint(x: 100, y: 100),
            componentSize: CGSize(width: 40, height: 20),
            threshold: 1
        )

        #expect(result.center == CGPoint(x: 100, y: 100))
        #expect(result.guides.isEmpty)
    }

    @Test("the nearest candidate wins before priority tie breakers")
    func nearestCandidateWins() {
        let result = resolve(
            proposedCenter: CGPoint(x: 134, y: 33),
            componentSize: CGSize(width: 20, height: 0),
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: 100, y: 150, width: 60, height: 20)
                ),
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(2),
                    frame: CGRect(x: 135, y: 150, width: 50, height: 20)
                )
            ],
            threshold: 10
        )

        #expect(result.center.x == 135)
        #expect(verticalGuides(in: result) == [.vertical(x: 135)])
    }

    @Test("exact source ties prefer peer then safe area then canvas")
    func sourceTiePriorityIsDeterministic() {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 200)
        let safeArea = CGRect(x: 20, y: 20, width: 180, height: 160)
        let safeOverCanvas = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: 105, y: 33),
            componentSize: .zero,
            canvas: canvas,
            safeArea: safeArea,
            peers: [],
            threshold: 5
        )
        let peerOverSafe = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: 105, y: 33),
            componentSize: .zero,
            canvas: canvas,
            safeArea: safeArea,
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: 90, y: 150, width: 10, height: 20)
                )
            ],
            threshold: 5
        )

        #expect(verticalGuides(in: safeOverCanvas) == [.vertical(x: 110)])
        #expect(verticalGuides(in: peerOverSafe) == [.vertical(x: 100)])
    }

    @Test("exact dragged alignment ties prefer center then minimum then maximum edge")
    func draggedAlignmentTiePriorityIsDeterministic() {
        let centerWins = resolve(
            proposedCenter: CGPoint(x: 100, y: 33),
            componentSize: CGSize(width: 20, height: 0),
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: 85, y: 150, width: 20, height: 20)
                )
            ],
            threshold: 5
        )
        let minimumWins = resolve(
            proposedCenter: CGPoint(x: 100, y: 33),
            componentSize: CGSize(width: 20, height: 0),
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(2),
                    frame: CGRect(x: 65, y: 150, width: 20, height: 20)
                ),
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: 115, y: 150, width: 20, height: 20)
                )
            ],
            threshold: 5
        )

        #expect(verticalGuides(in: centerWins) == [.vertical(x: 95)])
        #expect(verticalGuides(in: minimumWins) == [.vertical(x: 85)])
    }

    @Test("exact target line ties use minimum midpoint maximum ordering")
    func targetLineTiePriorityIsStable() {
        let result = resolve(
            proposedCenter: CGPoint(x: 100, y: 33),
            componentSize: .zero,
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: 85, y: 150, width: 20, height: 20)
                )
            ],
            threshold: 5
        )

        #expect(verticalGuides(in: result) == [.vertical(x: 95)])
    }

    @Test("peer UUID ordering makes exact ties independent of input order")
    func peerUUIDOrderingIsDeterministic() {
        let lowerIDPeer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: 60, y: 150, width: 100, height: 20)
        )
        let higherIDPeer = ReaderOverlayPeerFrame(
            id: fixtureUUID(2),
            frame: CGRect(x: 40, y: 150, width: 100, height: 20)
        )
        let forward = resolve(
            proposedCenter: CGPoint(x: 100, y: 33),
            componentSize: .zero,
            peers: [lowerIDPeer, higherIDPeer],
            threshold: 10
        )
        let reversed = resolve(
            proposedCenter: CGPoint(x: 100, y: 33),
            componentSize: .zero,
            peers: [higherIDPeer, lowerIDPeer],
            threshold: 10
        )

        #expect(verticalGuides(in: forward) == [.vertical(x: 110)])
        #expect(reversed == forward)
    }

    @Test("snapping always returns a fully visible component frame")
    func snappingReturnsFullyVisibleFrame() {
        let size = CGSize(width: 80, height: 64)
        let result = resolve(
            proposedCenter: CGPoint(x: 194, y: 421),
            componentSize: size
        )
        let frame = CGRect(
            x: result.center.x - size.width / 2,
            y: result.center.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        #expect(canvas.contains(frame))
    }

    @Test("clamping removes an impossible snapped guide")
    func clampingRemovesImpossibleGuide() {
        let result = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: 5, y: 47),
            componentSize: CGSize(width: 80, height: 20),
            canvas: CGRect(x: 0, y: 0, width: 100, height: 100),
            safeArea: .null,
            peers: [
                ReaderOverlayPeerFrame(
                    id: fixtureUUID(1),
                    frame: CGRect(x: 5, y: 70, width: 10, height: 10)
                )
            ],
            threshold: 0
        )

        #expect(result.center == CGPoint(x: 40, y: 47))
        #expect(result.guides.isEmpty)
    }

    @Test("guides are limited to one per axis in vertical horizontal order")
    func guideCountAndOrderAreStable() {
        let result = resolve(
            proposedCenter: CGPoint(x: 194, y: 421),
            componentSize: CGSize(width: 40, height: 20)
        )

        #expect(result.guides == [.vertical(x: 195), .horizontal(y: 422)])
        #expect(result.guides.count == 2)
    }

    @Test("invalid frames and thresholds are ignored without nonfinite output")
    func invalidInputsAreIgnoredSafely() {
        let invalidPeer = ReaderOverlayPeerFrame(
            id: fixtureUUID(1),
            frame: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)
        )
        let result = ReaderOverlaySnapEngine.resolve(
            proposedCenter: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            componentSize: CGSize(width: -10, height: CGFloat.nan),
            canvas: CGRect(x: 0, y: 0, width: -100, height: 0),
            safeArea: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            peers: [invalidPeer],
            threshold: CGFloat.infinity
        )

        #expect(result.center.x.isFinite)
        #expect(result.center.y.isFinite)
        #expect(result.guides.isEmpty)

        let nonfiniteThreshold = resolve(
            proposedCenter: CGPoint(x: 194, y: 409),
            componentSize: CGSize(width: 80, height: 24),
            threshold: CGFloat.nan
        )
        #expect(nonfiniteThreshold.center == CGPoint(x: 194, y: 409))
        #expect(nonfiniteThreshold.guides.isEmpty)
    }

    @Test("negative thresholds behave as zero")
    func negativeThresholdBehavesAsZero() {
        let exact = resolve(
            proposedCenter: CGPoint(x: 195, y: 409),
            componentSize: CGSize(width: 80, height: 24),
            threshold: -8
        )
        let inexact = resolve(
            proposedCenter: CGPoint(x: 194, y: 409),
            componentSize: CGSize(width: 80, height: 24),
            threshold: -8
        )

        #expect(exact.guides == [.vertical(x: 195)])
        #expect(inexact.guides.isEmpty)
    }

    private func resolve(
        proposedCenter: CGPoint,
        componentSize: CGSize,
        safeArea: CGRect = .null,
        peers: [ReaderOverlayPeerFrame] = [],
        threshold: CGFloat = 8
    ) -> ReaderOverlaySnapResult {
        ReaderOverlaySnapEngine.resolve(
            proposedCenter: proposedCenter,
            componentSize: componentSize,
            canvas: canvas,
            safeArea: safeArea,
            peers: peers,
            threshold: threshold
        )
    }

    private func verticalGuides(in result: ReaderOverlaySnapResult) -> [ReaderOverlayGuide] {
        result.guides.filter {
            if case .vertical = $0 { return true }
            return false
        }
    }

    private func fixtureUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
