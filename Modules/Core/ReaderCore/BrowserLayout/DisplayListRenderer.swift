import CoreGraphics
import Foundation
import UIKit

/// Renders a single-page DisplayList into a UIImage. Coordinates are page
/// canvas-local; the renderer owns no layout state. Glyph drawing goes through
/// UIKit text drawing (shaped by the item's font) — CoreText shaping happened
/// earlier.
///
/// `DisplayListDrawer.draw(_:in:)` is the CGContext core shared with
/// `BrowserLayoutPageView` (direct page drawing — no intermediate UIImage).
/// Phase 2C: a border box paints its FULL representation — background fill
/// (with radius), then each of the four border edges with its own style
/// (solid / dotted / dashed), clipped to the box.
enum DisplayListRenderer {

    static func render(
        _ list: DisplayList,
        size: CGSize,
        backgroundColor: UIColor = .white
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            DisplayListDrawer.draw(list, in: context.cgContext)
        }
    }
}

enum DisplayListDrawer {
    /// Draws the list into the CURRENT context. The caller owns the background.
    static func draw(_ list: DisplayList, in context: CGContext) {
        for item in list.items {
            switch item {
            case .fill(let f):
                drawFill(f, in: context)
            case .text(let t):
                drawText(t)
            case .image(let i):
                if let image = i.image {
                    image.draw(in: i.rect.rawValue)
                } else {
                    UIColor.lightGray.setFill()
                    context.fill(i.rect.rawValue)
                }
            }
        }
    }

    /// One bordered box: background (clipped to radius) + four border edges.
    private static func drawFill(_ item: DisplayFillItem, in context: CGContext) {
        let rect = item.rect.rawValue
        guard !rect.isEmpty else { return }
        let radius = min(item.cornerRadius, rect.width / 2, rect.height / 2)

        let borderPath = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        // Background fill (respects alpha — rgba(255,255,255,0.7) shows the
        // authored background through).
        if item.color != .clear {
            context.saveGState()
            borderPath.addClip()
            item.color.setFill()
            context.fill(rect)
            context.restoreGState()
        }
        guard item.hasVisibleBorder else { return }

        // Border: stroke the same rounded path at half the max width so the
        // corner join is correct; then re-stroke thinner per-edge segments is
        // overkill — a single stroked rounded path with per-side widths is
        // approximated by stroking the full path at the max width for each
        // visible style band.
        let maxWidth = max(item.borderTop.width, item.borderBottom.width,
                           item.borderLeft.width, item.borderRight.width)
        guard maxWidth > 0 else { return }

        // Draw each visible edge as a separate line so dotted/dashed styles
        // apply per edge. Edges are drawn on the border box boundary.
        context.saveGState()
        context.setLineCap(.square)

        func strokeEdge(from start: CGPoint, to end: CGPoint, width: CGFloat, style: BorderStyle, color: UIColor) {
            guard width > 0, style != .none else { return }
            color.setStroke()
            context.setLineWidth(width)
            // Dotted: round dots. Dashed: short dashes.
            switch style {
            case .solid, .none:
                context.setLineDash(phase: 0, lengths: [])
            case .dotted:
                // Visible dots: a 1×-width solid dot with a 2.5× gap. A
                // 0.1pt dash anti-aliased into near-invisible gray on device.
                context.setLineDash(phase: 0, lengths: [width, width * 2.5])
                context.setLineCap(.round)
            case .dashed:
                context.setLineDash(phase: 0, lengths: [width * 3, width * 2])
            }
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.square)
        }

        /// One `border-radius` corner. Same per-path dash treatment as an edge.
        func strokeArc(
            center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat,
            width: CGFloat, style: BorderStyle, color: UIColor
        ) {
            guard width > 0, radius > 0, style != .none else { return }
            color.setStroke()
            context.setLineWidth(width)
            switch style {
            case .solid, .none:
                context.setLineDash(phase: 0, lengths: [])
            case .dotted:
                context.setLineDash(phase: 0, lengths: [width, width * 2.5])
                context.setLineCap(.round)
            case .dashed:
                context.setLineDash(phase: 0, lengths: [width * 3, width * 2])
            }
            context.beginPath()
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.square)
        }

        // A UNIFORM border on a rounded box is stroked as ONE rounded path.
        // The per-edge straight lines below cannot bend, so `border-radius: 12px`
        // on a bordered box (红楼梦's dotted 回目 frame, `div.k2`) drew square
        // corners while its own background fill was already clipped round —
        // the fill and the frame disagreed on the same box.
        if radius > 0, item.borderTop.isVisible,
           item.borderTop.width == item.borderBottom.width,
           item.borderTop.width == item.borderLeft.width,
           item.borderTop.width == item.borderRight.width,
           item.borderTop.style == item.borderBottom.style,
           item.borderTop.style == item.borderLeft.style,
           item.borderTop.style == item.borderRight.style,
           item.borderTop.color == item.borderBottom.color,
           item.borderTop.color == item.borderLeft.color,
           item.borderTop.color == item.borderRight.color {
            let width = item.borderTop.width
            let inset = width / 2
            let box = rect.insetBy(dx: inset, dy: inset)
            let r = max(0, min(radius - inset, box.width / 2, box.height / 2))
            let style = item.borderTop.style
            let color = item.borderTop.color

            // The four FLAT segments are stroked one path at a time, exactly as
            // the square-corner code below does — a single closed path would run
            // one continuous dash phase around the whole perimeter, which
            // changes where dots land on every edge after the first. Only the
            // corners are new geometry.
            strokeEdge(from: CGPoint(x: box.minX + r, y: box.minY),
                       to: CGPoint(x: box.maxX - r, y: box.minY),
                       width: width, style: style, color: color)
            strokeEdge(from: CGPoint(x: box.minX + r, y: box.maxY),
                       to: CGPoint(x: box.maxX - r, y: box.maxY),
                       width: width, style: style, color: color)
            strokeEdge(from: CGPoint(x: box.minX, y: box.minY + r),
                       to: CGPoint(x: box.minX, y: box.maxY - r),
                       width: width, style: style, color: color)
            strokeEdge(from: CGPoint(x: box.maxX, y: box.minY + r),
                       to: CGPoint(x: box.maxX, y: box.maxY - r),
                       width: width, style: style, color: color)
            if r > 0 {
                strokeArc(center: CGPoint(x: box.minX + r, y: box.minY + r), radius: r,
                          start: .pi, end: 1.5 * .pi, width: width, style: style, color: color)
                strokeArc(center: CGPoint(x: box.maxX - r, y: box.minY + r), radius: r,
                          start: 1.5 * .pi, end: 2 * .pi, width: width, style: style, color: color)
                strokeArc(center: CGPoint(x: box.maxX - r, y: box.maxY - r), radius: r,
                          start: 0, end: 0.5 * .pi, width: width, style: style, color: color)
                strokeArc(center: CGPoint(x: box.minX + r, y: box.maxY - r), radius: r,
                          start: 0.5 * .pi, end: .pi, width: width, style: style, color: color)
            }
            context.restoreGState()
            return
        }

        // Top edge spans the full box width; side edges start below the top
        // border width and end above the bottom border width so corners don't
        // double-stroke.
        let topInset = item.borderTop.width / 2
        let bottomInset = item.borderBottom.width / 2
        let leftInset = item.borderLeft.width / 2
        let rightInset = item.borderRight.width / 2

        strokeEdge(
            from: CGPoint(x: rect.minX + leftInset, y: rect.minY + topInset),
            to: CGPoint(x: rect.maxX - rightInset, y: rect.minY + topInset),
            width: item.borderTop.width,
            style: item.borderTop.style,
            color: item.borderTop.color
        )
        strokeEdge(
            from: CGPoint(x: rect.minX + leftInset, y: rect.maxY - bottomInset),
            to: CGPoint(x: rect.maxX - rightInset, y: rect.maxY - bottomInset),
            width: item.borderBottom.width,
            style: item.borderBottom.style,
            color: item.borderBottom.color
        )
        strokeEdge(
            from: CGPoint(x: rect.minX + leftInset, y: rect.minY + topInset),
            to: CGPoint(x: rect.minX + leftInset, y: rect.maxY - bottomInset),
            width: item.borderLeft.width,
            style: item.borderLeft.style,
            color: item.borderLeft.color
        )
        strokeEdge(
            from: CGPoint(x: rect.maxX - rightInset, y: rect.minY + topInset),
            to: CGPoint(x: rect.maxX - rightInset, y: rect.maxY - bottomInset),
            width: item.borderRight.width,
            style: item.borderRight.style,
            color: item.borderRight.color
        )
        context.restoreGState()
    }

    private static func drawText(_ item: DisplayTextItem) {
        guard !item.text.isEmpty else { return }
        let string = NSAttributedString(string: item.text, attributes: [
            .font: item.font,
            .foregroundColor: item.color,
        ])
        // Draw with the glyph top aligned to the line box top (baseline math
        // already accounts for ascent).
        let drawPoint = CGPoint(x: item.rect.minX, y: item.baselineY - item.font.ascender)
        string.draw(at: drawPoint)
    }
}
