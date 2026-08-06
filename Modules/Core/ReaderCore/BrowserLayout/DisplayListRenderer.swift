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

        let halfW = maxWidth / 2
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
