import SwiftUI

struct ReaderOverlayAlignmentGuidesView: View {
    let guides: [ReaderOverlayGuide]

    var body: some View {
        Canvas { context, size in
            for guide in guides {
                var path = Path()
                switch guide {
                case .vertical(let rawX):
                    let x = CGFloat(rawX)
                    guard x.isFinite else { continue }
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                case .horizontal(let rawY):
                    let y = CGFloat(rawY)
                    guard y.isFinite else { continue }
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(
                    path,
                    with: .color(DSColor.accent),
                    style: StrokeStyle(
                        lineWidth: DSLayout.readerOverlayGuideLineWidth,
                        dash: [DSLayout.readerOverlayGuideDashLength]
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

enum ReaderOverlayEditorGeometry {
    static let snapAcquireDistance = DSLayout.readerOverlaySnapAcquireDistance
    static let snapReleaseDistance = DSLayout.readerOverlaySnapReleaseDistance

    static func chromeAvoidingSafeArea(
        safeArea: CGRect,
        canvas: CGRect,
        topChromeFrame: CGRect,
        bottomChromeFrame: CGRect,
        gap: CGFloat
    ) -> CGRect {
        let usable = usableRect(safeArea: safeArea, canvas: canvas)
        guard usable.width > 0, usable.height > 0 else { return .zero }
        let gap = sanitizedInset(gap)
        let topChromeMaxY = clipped(topChromeFrame, to: canvas)?.maxY ?? usable.minY
        let bottomChromeMinY = clipped(bottomChromeFrame, to: canvas)?.minY ?? usable.maxY
        let minY = min(max(usable.minY, topChromeMaxY + gap), usable.maxY)
        let maxY = max(min(usable.maxY, bottomChromeMinY - gap), minY)
        return CGRect(
            x: usable.minX,
            y: minY,
            width: usable.width,
            height: maxY - minY
        )
    }

    static func actionMenuCenter(
        componentFrame: CGRect,
        menuSize: CGSize,
        canvas: CGRect,
        safeArea: CGRect,
        gap: CGFloat
    ) -> CGPoint {
        let usable = usableRect(safeArea: safeArea, canvas: canvas)
        guard usable.width > 0, usable.height > 0 else {
            return CGPoint(x: canvas.midX, y: canvas.midY)
        }

        let halfWidth = min(max(menuSize.width, 0), usable.width) / 2
        let halfHeight = min(max(menuSize.height, 0), usable.height) / 2
        let minimumX = usable.minX + halfWidth
        let maximumX = usable.maxX - halfWidth
        let x = min(max(componentFrame.midX, minimumX), maximumX)

        let below = componentFrame.maxY + gap + halfHeight
        let above = componentFrame.minY - gap - halfHeight
        let y: CGFloat
        if below <= usable.maxY {
            y = max(below, usable.minY + halfHeight)
        } else if above >= usable.minY {
            y = min(above, usable.maxY - halfHeight)
        } else {
            y = min(
                max(componentFrame.midY, usable.minY + halfHeight),
                usable.maxY - halfHeight
            )
        }
        return CGPoint(x: x, y: y)
    }

    private static func usableRect(safeArea: CGRect, canvas: CGRect) -> CGRect {
        guard isUsable(canvas) else { return .zero }
        guard isUsable(safeArea) else { return canvas }
        let intersection = safeArea.intersection(canvas)
        return isUsable(intersection) ? intersection : canvas
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

    private static func sanitizedInset(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }

    private static func clipped(_ rect: CGRect, to bounds: CGRect) -> CGRect? {
        guard isUsable(rect), isUsable(bounds) else { return nil }
        let intersection = rect.intersection(bounds)
        return isUsable(intersection) ? intersection : nil
    }
}
