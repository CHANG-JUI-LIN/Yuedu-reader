import UIKit

final class InteractionOverlayView: UIView {
    var fillColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.20) {
        didSet { setNeedsDisplay() }
    }

    /// When non-nil, each selection rect is drawn as a styled dialogue box (solid block
    /// or gradient pill) instead of a plain `fillColor` fill. Used by the TTS playback
    /// highlight to reuse the reader's box styles.
    var boxStyle: CoreTextDialogueBox.Style? {
        didSet { setNeedsDisplay() }
    }
    /// Base color for the styled box (only used when `boxStyle != nil`).
    var boxColor: UIColor? {
        didSet { setNeedsDisplay() }
    }

    var handleColor: UIColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    var showsHandles: Bool = true {
        didSet { setNeedsDisplay() }
    }

    var underlineColor: UIColor = .systemRed {
        didSet { setNeedsDisplay() }
    }

    var underlineRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var drawsVerticalUnderlines: Bool = false {
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

        if let boxStyle, let boxColor {
            for selectionRect in selectionRects {
                CoreTextDialogueBox.fill(rect: selectionRect, baseColor: boxColor, style: boxStyle, in: ctx)
            }
        } else {
            ctx.setFillColor(fillColor.cgColor)
            for selectionRect in selectionRects {
                ctx.fill(selectionRect)
            }
        }

        if !underlineRects.isEmpty {
            ctx.setStrokeColor(underlineColor.cgColor)
            ctx.setLineCap(.round)
            for rect in underlineRects {
                if drawsVerticalUnderlines {
                    let x = max(rect.minX, rect.maxX - 2)
                    ctx.setLineWidth(max(1, min(2, rect.width * 0.08)))
                    ctx.move(to: CGPoint(x: x, y: rect.minY))
                    ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                } else {
                    let y = max(rect.minY, rect.maxY - 2)
                    ctx.setLineWidth(max(1, min(2, rect.height * 0.05)))
                    ctx.move(to: CGPoint(x: rect.minX, y: y))
                    ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
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

    /// Configure this overlay to render a single annotation layer — the single
    /// source of truth that maps a `CoreTextAnnotationRenderer.Layer` to its
    /// visuals (highlight fill vs. red underline). Shared by the paged and
    /// scroll renderers so the mapping isn't duplicated per host.
    func apply(layer: CoreTextAnnotationRenderer.Layer, isVertical: Bool) {
        if layer.style == .highlight {
            fillColor = layer.color.uiColor.withAlphaComponent(0.25)
            selectionRects = layer.rects
            underlineRects = []
        } else {
            fillColor = .clear
            underlineColor = .systemRed
            underlineRects = layer.rects
            drawsVerticalUnderlines = isVertical
            selectionRects = []
        }
        startHandlePoint = nil
        endHandlePoint = nil
        isHidden = false
    }

    func clearSelection() {
        selectionRects = []
        underlineRects = []
        startHandlePoint = nil
        endHandlePoint = nil
    }
}
