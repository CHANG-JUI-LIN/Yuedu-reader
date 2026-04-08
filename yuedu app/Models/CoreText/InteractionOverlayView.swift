import UIKit

final class InteractionOverlayView: UIView {
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

        let fillColor = UIColor.systemBlue.withAlphaComponent(0.20)
        ctx.setFillColor(fillColor.cgColor)
        for selectionRect in selectionRects {
            ctx.fill(selectionRect)
        }

        let handleRadius: CGFloat = 5
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        if let startHandlePoint {
            ctx.fillEllipse(in: CGRect(
                x: startHandlePoint.x - handleRadius,
                y: startHandlePoint.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            ))
        }
        if let endHandlePoint {
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
        startHandlePoint = nil
        endHandlePoint = nil
    }
}
