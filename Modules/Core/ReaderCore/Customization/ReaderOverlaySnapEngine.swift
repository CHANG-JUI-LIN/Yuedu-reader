import CoreGraphics
import Foundation

enum ReaderOverlayGuide: Equatable, Sendable {
    case vertical(x: Double)
    case horizontal(y: Double)
}

struct ReaderOverlayPeerFrame: Equatable, Sendable {
    let id: UUID
    let frame: CGRect
}

struct ReaderOverlaySnapResult: Equatable, Sendable {
    let center: CGPoint
    let guides: [ReaderOverlayGuide]
}

struct ReaderOverlaySnapSession: Equatable, Sendable {
    fileprivate var xLatch: ReaderOverlaySnapLatch?
    fileprivate var yLatch: ReaderOverlaySnapLatch?

    init() {}

    mutating func reset() {
        xLatch = nil
        yLatch = nil
    }
}

enum ReaderOverlayBodyFramePolicy {
    static func frame(
        in canvas: CGRect,
        horizontalPageMargin: CGFloat,
        topReservation: CGFloat,
        bottomReservation: CGFloat
    ) -> CGRect {
        guard ReaderOverlaySnapEngine.isUsable(canvas) else { return .null }

        let margin = min(
            ReaderOverlaySnapEngine.sanitizedDistance(horizontalPageMargin),
            canvas.width / 2
        )
        let top = min(
            ReaderOverlaySnapEngine.sanitizedDistance(topReservation),
            canvas.height
        )
        let bottom = min(
            ReaderOverlaySnapEngine.sanitizedDistance(bottomReservation),
            canvas.height - top
        )

        return CGRect(
            x: canvas.minX + margin,
            y: canvas.minY + top,
            width: max(canvas.width - margin * 2, 0),
            height: max(canvas.height - top - bottom, 0)
        )
    }
}

enum ReaderOverlaySnapEngine {
    static let defaultAcquireDistance: CGFloat = 6
    static let defaultReleaseDistance: CGFloat = 12

    static func resolve(
        proposedCenter: CGPoint,
        componentSize: CGSize,
        canvas: CGRect,
        bodyFrame: CGRect,
        peers: [ReaderOverlayPeerFrame],
        session: inout ReaderOverlaySnapSession,
        acquireDistance: CGFloat = defaultAcquireDistance,
        releaseDistance: CGFloat = defaultReleaseDistance
    ) -> ReaderOverlaySnapResult {
        let canvasIsUsable = isUsable(canvas)
        let fallbackCenter = canvasIsUsable
            ? CGPoint(x: canvas.midX, y: canvas.midY)
            : .zero
        let proposed = CGPoint(
            x: proposedCenter.x.isFinite ? proposedCenter.x : fallbackCenter.x,
            y: proposedCenter.y.isFinite ? proposedCenter.y : fallbackCenter.y
        )
        let size = CGSize(
            width: sanitizedExtent(componentSize.width),
            height: sanitizedExtent(componentSize.height)
        )

        guard canvasIsUsable else {
            session.reset()
            return ReaderOverlaySnapResult(
                center: ReaderOverlayGeometry.clamp(
                    center: proposed,
                    size: size,
                    to: canvas
                ),
                guides: []
            )
        }

        let acquire = sanitizedDistance(acquireDistance)
        let release = max(acquire, sanitizedDistance(releaseDistance))
        let targets = makeCandidates(
            proposedCenter: proposed,
            componentSize: size,
            bodyFrame: bodyFrame,
            peers: peers
        )
        let xCandidate = resolveAxis(
            proposed: proposed.x,
            candidates: targets.x,
            latch: &session.xLatch,
            acquireDistance: acquire,
            releaseDistance: release
        )
        let yCandidate = resolveAxis(
            proposed: proposed.y,
            candidates: targets.y,
            latch: &session.yLatch,
            acquireDistance: acquire,
            releaseDistance: release
        )
        let snapped = CGPoint(
            x: xCandidate?.requiredCenter ?? proposed.x,
            y: yCandidate?.requiredCenter ?? proposed.y
        )
        let clamped = ReaderOverlayGeometry.clamp(center: snapped, size: size, to: canvas)

        var guides: [ReaderOverlayGuide] = []
        if let xCandidate, approximatelyEqual(clamped.x, xCandidate.requiredCenter) {
            guides.append(.vertical(x: Double(xCandidate.guideCoordinate)))
        } else {
            session.xLatch = nil
        }
        if let yCandidate, approximatelyEqual(clamped.y, yCandidate.requiredCenter) {
            guides.append(.horizontal(y: Double(yCandidate.guideCoordinate)))
        } else {
            session.yLatch = nil
        }

        return ReaderOverlaySnapResult(center: clamped, guides: guides)
    }

    fileprivate static func sanitizedDistance(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    fileprivate static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }

    private static func makeCandidates(
        proposedCenter: CGPoint,
        componentSize: CGSize,
        bodyFrame: CGRect,
        peers: [ReaderOverlayPeerFrame]
    ) -> (x: [ReaderOverlaySnapCandidate], y: [ReaderOverlaySnapCandidate]) {
        let halfWidth = componentSize.width / 2
        let halfHeight = componentSize.height / 2
        var xCandidates: [ReaderOverlaySnapCandidate] = []
        var yCandidates: [ReaderOverlaySnapCandidate] = []

        if isUsable(bodyFrame) {
            xCandidates.append(contentsOf: [
                candidate(
                    proposed: proposedCenter.x,
                    requiredCenter: bodyFrame.minX + halfWidth,
                    guideCoordinate: bodyFrame.minX,
                    identity: .bodyMinimum,
                    priority: 0,
                    stableKey: "0-min"
                ),
                candidate(
                    proposed: proposedCenter.x,
                    requiredCenter: bodyFrame.maxX - halfWidth,
                    guideCoordinate: bodyFrame.maxX,
                    identity: .bodyMaximum,
                    priority: 0,
                    stableKey: "0-max"
                )
            ])
            yCandidates.append(contentsOf: [
                candidate(
                    proposed: proposedCenter.y,
                    requiredCenter: bodyFrame.minY + halfHeight,
                    guideCoordinate: bodyFrame.minY,
                    identity: .bodyMinimum,
                    priority: 0,
                    stableKey: "0-min"
                ),
                candidate(
                    proposed: proposedCenter.y,
                    requiredCenter: bodyFrame.maxY - halfHeight,
                    guideCoordinate: bodyFrame.maxY,
                    identity: .bodyMaximum,
                    priority: 0,
                    stableKey: "0-max"
                )
            ])
        }

        for peer in peers.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where isUsable(peer.frame) {
            xCandidates.append(contentsOf: peerCandidates(
                proposed: proposedCenter.x,
                draggedHalfExtent: halfWidth,
                peerMinimum: peer.frame.minX,
                peerMidpoint: peer.frame.midX,
                peerMaximum: peer.frame.maxX,
                peerID: peer.id
            ))
            yCandidates.append(contentsOf: peerCandidates(
                proposed: proposedCenter.y,
                draggedHalfExtent: halfHeight,
                peerMinimum: peer.frame.minY,
                peerMidpoint: peer.frame.midY,
                peerMaximum: peer.frame.maxY,
                peerID: peer.id
            ))
        }

        return (xCandidates, yCandidates)
    }

    private static func peerCandidates(
        proposed: CGFloat,
        draggedHalfExtent: CGFloat,
        peerMinimum: CGFloat,
        peerMidpoint: CGFloat,
        peerMaximum: CGFloat,
        peerID: UUID
    ) -> [ReaderOverlaySnapCandidate] {
        ReaderOverlayMatchedAlignment.allCases.map { alignment in
            let line: CGFloat
            let requiredCenter: CGFloat
            switch alignment {
            case .minimum:
                line = peerMinimum
                requiredCenter = peerMinimum + draggedHalfExtent
            case .midpoint:
                line = peerMidpoint
                requiredCenter = peerMidpoint
            case .maximum:
                line = peerMaximum
                requiredCenter = peerMaximum - draggedHalfExtent
            }
            return candidate(
                proposed: proposed,
                requiredCenter: requiredCenter,
                guideCoordinate: line,
                identity: .peer(peerID, alignment),
                priority: alignment == .midpoint ? 1 : 2,
                stableKey: "1-\(peerID.uuidString)-\(alignment.rawValue)"
            )
        }
    }

    private static func candidate(
        proposed: CGFloat,
        requiredCenter: CGFloat,
        guideCoordinate: CGFloat,
        identity: ReaderOverlaySnapTargetIdentity,
        priority: Int,
        stableKey: String
    ) -> ReaderOverlaySnapCandidate {
        ReaderOverlaySnapCandidate(
            requiredCenter: requiredCenter,
            guideCoordinate: guideCoordinate,
            distance: abs(proposed - requiredCenter),
            identity: identity,
            priority: priority,
            stableKey: stableKey
        )
    }

    private static func resolveAxis(
        proposed: CGFloat,
        candidates: [ReaderOverlaySnapCandidate],
        latch: inout ReaderOverlaySnapLatch?,
        acquireDistance: CGFloat,
        releaseDistance: CGFloat
    ) -> ReaderOverlaySnapCandidate? {
        if let currentLatch = latch,
           let retained = candidates.first(where: { $0.identity == currentLatch.identity }),
           abs(proposed - retained.requiredCenter) <= releaseDistance {
            return retained
        }

        latch = nil
        guard let acquired = candidates
            .filter({ $0.distance <= acquireDistance })
            .min(by: { $0.isPreferred(over: $1) }) else {
            return nil
        }
        latch = ReaderOverlaySnapLatch(identity: acquired.identity)
        return acquired
    }

    private static func sanitizedExtent(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= max(lhs.ulp, rhs.ulp) * 8
    }
}

private struct ReaderOverlaySnapCandidate {
    let requiredCenter: CGFloat
    let guideCoordinate: CGFloat
    let distance: CGFloat
    let identity: ReaderOverlaySnapTargetIdentity
    let priority: Int
    let stableKey: String

    func isPreferred(over other: Self) -> Bool {
        if distance != other.distance { return distance < other.distance }
        if priority != other.priority { return priority < other.priority }
        return stableKey < other.stableKey
    }
}

fileprivate struct ReaderOverlaySnapLatch: Equatable, Sendable {
    let identity: ReaderOverlaySnapTargetIdentity
}

fileprivate enum ReaderOverlaySnapTargetIdentity: Equatable, Sendable {
    case bodyMinimum
    case bodyMaximum
    case peer(UUID, ReaderOverlayMatchedAlignment)
}

fileprivate enum ReaderOverlayMatchedAlignment: Int, CaseIterable, Equatable, Sendable {
    case minimum
    case midpoint
    case maximum
}
