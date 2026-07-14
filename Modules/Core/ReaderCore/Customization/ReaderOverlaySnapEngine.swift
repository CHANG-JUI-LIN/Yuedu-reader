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

enum ReaderOverlaySnapEngine {
    static let defaultThreshold: CGFloat = 8
    private static let comparisonULPFactor: CGFloat = 8

    static func resolve(
        proposedCenter: CGPoint,
        componentSize: CGSize,
        canvas: CGRect,
        safeArea: CGRect,
        peers: [ReaderOverlayPeerFrame],
        threshold: CGFloat = defaultThreshold
    ) -> ReaderOverlaySnapResult {
        let canvasIsUsable = isUsable(canvas)
        let fallbackCenter = canvasIsUsable
            ? CGPoint(x: canvas.midX, y: canvas.midY)
            : .zero
        let proposed = CGPoint(
            x: proposedCenter.x.isFinite ? proposedCenter.x : fallbackCenter.x,
            y: proposedCenter.y.isFinite ? proposedCenter.y : fallbackCenter.y
        )
        let componentWidth = sanitizedExtent(componentSize.width)
        let componentHeight = sanitizedExtent(componentSize.height)
        let threshold = threshold.isFinite ? max(threshold, 0) : 0

        guard canvasIsUsable else {
            return ReaderOverlaySnapResult(
                center: ReaderOverlayGeometry.clamp(
                    center: proposed,
                    size: CGSize(width: componentWidth, height: componentHeight),
                    to: canvas
                ),
                guides: []
            )
        }

        let targets = makeTargets(canvas: canvas, safeArea: safeArea, peers: peers)
        let xCandidate = bestCandidate(
            proposed: proposed.x,
            componentExtent: componentWidth,
            targets: targets.x,
            threshold: threshold
        )
        let yCandidate = bestCandidate(
            proposed: proposed.y,
            componentExtent: componentHeight,
            targets: targets.y,
            threshold: threshold
        )
        let snapped = CGPoint(
            x: xCandidate?.requiredCenter ?? proposed.x,
            y: yCandidate?.requiredCenter ?? proposed.y
        )
        let clamped = ReaderOverlayGeometry.clamp(
            center: snapped,
            size: CGSize(width: componentWidth, height: componentHeight),
            to: canvas
        )

        var guides: [ReaderOverlayGuide] = []
        if let xCandidate,
           xCandidate.remainsAligned(center: clamped.x, componentExtent: componentWidth) {
            guides.append(.vertical(x: Double(xCandidate.target.value)))
        }
        if let yCandidate,
           yCandidate.remainsAligned(center: clamped.y, componentExtent: componentHeight) {
            guides.append(.horizontal(y: Double(yCandidate.target.value)))
        }

        return ReaderOverlaySnapResult(center: clamped, guides: guides)
    }

    private static func makeTargets(
        canvas: CGRect,
        safeArea: CGRect,
        peers: [ReaderOverlayPeerFrame]
    ) -> (x: [Target], y: [Target]) {
        var xTargets = targets(for: canvas, axis: .x, source: .canvas, peerID: nil)
        var yTargets = targets(for: canvas, axis: .y, source: .canvas, peerID: nil)

        if isUsable(safeArea) {
            let intersection = safeArea.intersection(canvas)
            if isUsable(intersection) {
                xTargets += targets(
                    for: intersection,
                    axis: .x,
                    source: .safeArea,
                    peerID: nil
                )
                yTargets += targets(
                    for: intersection,
                    axis: .y,
                    source: .safeArea,
                    peerID: nil
                )
            }
        }

        for peer in peers.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where isUsable(peer.frame) {
            xTargets += targets(
                for: peer.frame,
                axis: .x,
                source: .peer,
                peerID: peer.id.uuidString
            )
            yTargets += targets(
                for: peer.frame,
                axis: .y,
                source: .peer,
                peerID: peer.id.uuidString
            )
        }

        return (xTargets, yTargets)
    }

    private static func targets(
        for rect: CGRect,
        axis: Axis,
        source: TargetSource,
        peerID: String?
    ) -> [Target] {
        let values: [CGFloat]
        switch axis {
        case .x:
            values = [rect.minX, rect.midX, rect.maxX]
        case .y:
            values = [rect.minY, rect.midY, rect.maxY]
        }

        return zip(TargetLineKind.allCases, values).map { lineKind, value in
            Target(
                value: value,
                source: source,
                lineKind: lineKind,
                peerID: peerID
            )
        }
    }

    private static func bestCandidate(
        proposed: CGFloat,
        componentExtent: CGFloat,
        targets: [Target],
        threshold: CGFloat
    ) -> Candidate? {
        let halfExtent = componentExtent / 2
        var best: Candidate?

        for target in targets {
            for alignment in DraggedAlignment.allCases {
                let requiredCenter = alignment.requiredCenter(
                    target: target.value,
                    halfExtent: halfExtent
                )
                guard requiredCenter.isFinite else { continue }
                let distance = abs(requiredCenter - proposed)
                let thresholdTolerance = scaledULPTolerance(
                    proposed,
                    requiredCenter,
                    target.value,
                    distance,
                    threshold
                )
                let thresholdLimit = addingTolerance(
                    thresholdTolerance,
                    to: threshold
                )
                guard distance <= thresholdLimit else { continue }

                let candidate = Candidate(
                    requiredCenter: requiredCenter,
                    distance: distance,
                    alignment: alignment,
                    target: target
                )
                if best == nil || candidate.isPreferred(over: best!) {
                    best = candidate
                }
            }
        }

        return best
    }

    private static func scaledULPTolerance(_ values: CGFloat...) -> CGFloat {
        let scale = values.reduce(CGFloat(1)) { currentScale, value in
            guard value.isFinite else { return currentScale }
            return max(currentScale, abs(value))
        }
        let tolerance = scale.ulp * comparisonULPFactor
        return tolerance.isFinite ? tolerance : 0
    }

    private static func addingTolerance(
        _ tolerance: CGFloat,
        to value: CGFloat
    ) -> CGFloat {
        guard tolerance > 0,
              tolerance.isFinite,
              value <= CGFloat.greatestFiniteMagnitude - tolerance else {
            return value
        }
        return value + tolerance
    }

    private static func sanitizedExtent(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }

    private enum Axis {
        case x
        case y
    }

    private enum TargetSource: Int {
        case peer = 0
        case safeArea = 1
        case canvas = 2
    }

    private enum TargetLineKind: Int, CaseIterable {
        case minimum = 0
        case midpoint = 1
        case maximum = 2
    }

    private enum DraggedAlignment: Int, CaseIterable {
        case center = 0
        case minimumEdge = 1
        case maximumEdge = 2

        func requiredCenter(target: CGFloat, halfExtent: CGFloat) -> CGFloat {
            switch self {
            case .center:
                return target
            case .minimumEdge:
                return target + halfExtent
            case .maximumEdge:
                return target - halfExtent
            }
        }

        func alignedCoordinate(center: CGFloat, halfExtent: CGFloat) -> CGFloat {
            switch self {
            case .center:
                return center
            case .minimumEdge:
                return center - halfExtent
            case .maximumEdge:
                return center + halfExtent
            }
        }
    }

    private struct Target {
        let value: CGFloat
        let source: TargetSource
        let lineKind: TargetLineKind
        let peerID: String?
    }

    private struct Candidate {
        private static let alignmentTolerance: CGFloat = 0.001

        let requiredCenter: CGFloat
        let distance: CGFloat
        let alignment: DraggedAlignment
        let target: Target

        func isPreferred(over other: Candidate) -> Bool {
            let distanceDifference = abs(distance - other.distance)
            let distanceTolerance = ReaderOverlaySnapEngine.scaledULPTolerance(
                requiredCenter,
                target.value,
                distance,
                other.requiredCenter,
                other.target.value,
                other.distance
            )
            if distanceDifference > distanceTolerance {
                return distance < other.distance
            }
            if target.source != other.target.source {
                return target.source.rawValue < other.target.source.rawValue
            }
            if alignment != other.alignment {
                return alignment.rawValue < other.alignment.rawValue
            }
            if target.lineKind != other.target.lineKind {
                return target.lineKind.rawValue < other.target.lineKind.rawValue
            }

            let peerID = target.peerID ?? ""
            let otherPeerID = other.target.peerID ?? ""
            if peerID != otherPeerID { return peerID < otherPeerID }
            if target.value != other.target.value { return target.value < other.target.value }
            return requiredCenter < other.requiredCenter
        }

        func remainsAligned(center: CGFloat, componentExtent: CGFloat) -> Bool {
            let coordinate = alignment.alignedCoordinate(
                center: center,
                halfExtent: componentExtent / 2
            )
            return abs(coordinate - target.value) <= Self.alignmentTolerance
        }
    }
}
