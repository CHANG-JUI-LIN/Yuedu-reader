import UIKit

final class InteractionOverlayView: UIView {
    var fillColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.20) {
        didSet { setNeedsDisplay() }
    }

    var handleColor: UIColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    var showsHandles: Bool = true {
        didSet { setNeedsDisplay() }
    }

    var underlineColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.85) {
        didSet { setNeedsDisplay() }
    }

    var underlineRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var selectionRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var startHandlePoint: CGPoint? {
        didSet { setNeedsDisplay() }
    }

    var endHandlePoint: CGPoint? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(fillColor.cgColor)
        for selectionRect in selectionRects {
            ctx.fill(selectionRect)
        }

        if !underlineRects.isEmpty {
            ctx.setStrokeColor(underlineColor.cgColor)
            ctx.setLineCap(.round)
            for rect in underlineRects {
                let y = max(rect.minY, rect.maxY - 2)
                ctx.setLineWidth(max(2, min(4, rect.height * 0.08)))
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                ctx.strokePath()
            }
        }

        guard showsHandles else { return }
        let handleRadius: CGFloat = 6
        let stemLength: CGFloat = 24
        ctx.setStrokeColor(handleColor.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        ctx.setFillColor(handleColor.cgColor)
        if let startHandlePoint {
            ctx.move(to: startHandlePoint)
            ctx.addLine(to: CGPoint(x: startHandlePoint.x, y: startHandlePoint.y + stemLength))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(
                x: startHandlePoint.x - handleRadius,
                y: startHandlePoint.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            ))
        }
        if let endHandlePoint {
            ctx.move(to: CGPoint(x: endHandlePoint.x, y: endHandlePoint.y - stemLength))
            ctx.addLine(to: endHandlePoint)
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(
                x: endHandlePoint.x - handleRadius,
                y: endHandlePoint.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            ))
        }
    }

    func clearSelection() {
        selectionRects = []
        underlineRects = []
        startHandlePoint = nil
        endHandlePoint = nil
    }
}
