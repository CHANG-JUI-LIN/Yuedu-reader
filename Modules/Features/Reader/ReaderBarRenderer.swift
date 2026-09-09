import CoreText
import UIKit

// MARK: - Model

/// One bar's content, fully resolved: every value already formatted, every image
/// already rasterized.
///
/// Deliberately holds no SwiftUI, no reader state and no asset store, because the
/// same value has to be drawable from two very different places — the live page on
/// the main thread, and `CoreTextPageEngine.renderImage` on a detached snapshot
/// thread. Resolving (which needs the presentation resolver and the battery
/// rasterizer) happens once, up front, in `ReaderBarRenderModelBuilder`.
struct ReaderBarRenderModel: Equatable {
    /// Leading / centre / trailing. Always three, even when empty — the renderer
    /// indexes them positionally.
    static let slotCount = 3

    enum Field: Equatable {
        case text(String)
        case progress(Double)
        /// Battery, either the system symbol or an imported template, already
        /// rendered to an image and tinted.
        case image(UIImage, percentage: String?)
    }

    var bar: ReaderBar
    var slots: [[Field]]
    var font: UIFont
    var color: UIColor
    var opacity: Double
    var horizontalPadding: CGFloat
    var showsDivider: Bool
    /// "章節名 第一回、總進度 42%" — label/value pairs in slot order, so the spoken
    /// form matches the visual one. Carried on the model because a bar drawn into
    /// a CoreText page has no view hierarchy for VoiceOver to walk.
    var accessibilityValue: String

    var isEmpty: Bool { slots.allSatisfy(\.isEmpty) }
}

// MARK: - Renderer

/// Draws a bar into a `CGContext`.
///
/// This is the only place a bar is turned into pixels. Paged mode draws it inside
/// `CoreTextPageView.renderPage`, so the bar automatically appears on the live
/// page, on curl back-pages, on cover-transition snapshots and on the auto-read
/// reveal image — all four of those are `UIImage`s produced by that one function,
/// which is why a UIKit subview on the page controller would have been invisible
/// on three of them.
enum ReaderBarRenderer {

    /// 0.5pt, matching the SwiftUI bar and legado's `view_book_page.xml`.
    static let dividerHeight: CGFloat = 0.5

    /// legado's floor for a tip row. See `rowHeight`.
    private static let minimumLineHeightMultiple: CGFloat = 1.6

    private static let separator = "·"

    // MARK: Metrics

    /// The height of the bar's text row, dividers excluded.
    ///
    /// Computed rather than the flat 16pt the bars used to assume. The bar's font
    /// is user-adjustable from 8 to 16pt, and a 16pt face does not fit inside a
    /// 16pt row — the descenders were being clipped.
    ///
    /// The floor stays in place even when every slot is empty. A bar that
    /// collapsed to nothing would hand its height to the text area, which
    /// repaginates, which changes what the bar says, which can change its height
    /// again; legado's own Compose port carries the same guard for the same
    /// reason (`legado-upstream/.../PageViewComposable.kt:419`).
    nonisolated static func rowHeight(fontSize: CGFloat) -> CGFloat {
        let size = max(1, fontSize)
        let line = UIFont.systemFont(ofSize: size).lineHeight
        return ceil(max(size * minimumLineHeightMultiple, line))
    }

    /// The whole band: text row plus the divider, when one is shown.
    nonisolated static func extent(fontSize: CGFloat, showsDivider: Bool) -> CGFloat {
        rowHeight(fontSize: fontSize) + (showsDivider ? dividerHeight : 0)
    }

    // MARK: Drawing

    /// - Parameters:
    ///   - rect: the whole band, in UIKit coordinates (origin top-left).
    ///   - canvasHeight: height of the surface `ctx` is drawing into, used to flip
    ///     into CoreText's y-up space for text. Same contract as
    ///     `CoreTextPageView.drawBlockRenderableText`.
    nonisolated static func draw(
        _ model: ReaderBarRenderModel,
        in rect: CGRect,
        canvasHeight: CGFloat,
        context ctx: CGContext
    ) {
        guard rect.width > 0, rect.height > 0, !model.isEmpty || model.showsDivider else { return }

        let color = model.color.withAlphaComponent(
            model.color.cgColor.alpha * CGFloat(max(0, min(1, model.opacity)))
        )

        var rowRect = rect
        if model.showsDivider {
            let dividerRect: CGRect
            switch model.bar {
            case .header:
                dividerRect = CGRect(x: rect.minX, y: rect.maxY - dividerHeight,
                                     width: rect.width, height: dividerHeight)
                rowRect.size.height -= dividerHeight
            case .footer:
                dividerRect = CGRect(x: rect.minX, y: rect.minY,
                                     width: rect.width, height: dividerHeight)
                rowRect.origin.y += dividerHeight
                rowRect.size.height -= dividerHeight
            }
            ctx.setFillColor(color.withAlphaComponent(color.cgColor.alpha * 0.25).cgColor)
            ctx.fill(dividerRect.insetBy(dx: model.horizontalPadding, dy: 0))
        }

        let contentRect = rowRect.insetBy(dx: model.horizontalPadding, dy: 0)
        guard contentRect.width > 0 else { return }

        let groups = model.slots.map { measure($0, model: model) }
        let origins = slotOrigins(groups.map(\.width), in: contentRect)

        for (index, group) in groups.enumerated() where !group.elements.isEmpty {
            drawGroup(
                group,
                at: origins[index],
                midY: contentRect.midY,
                color: color,
                imageAlpha: CGFloat(max(0, min(1, model.opacity))),
                font: model.font,
                canvasHeight: canvasHeight,
                context: ctx
            )
        }
    }

    // MARK: Measurement

    private struct Element {
        enum Content {
            case line(CTLine)
            case progress(Double)
            case image(UIImage)
        }
        var content: Content
        var width: CGFloat
    }

    private struct Group {
        var elements: [Element]
        var width: CGFloat
    }

    private nonisolated static func measure(
        _ fields: [ReaderBarRenderModel.Field],
        model: ReaderBarRenderModel
    ) -> Group {
        var elements: [Element] = []
        for (index, field) in fields.enumerated() {
            if index > 0, let dot = makeLine(separator, font: model.font) {
                elements.append(dot)
            }
            switch field {
            case .text(let value):
                guard !value.isEmpty, let line = makeLine(value, font: model.font) else { continue }
                elements.append(line)
            case .progress(let value):
                elements.append(Element(content: .progress(value), width: progressWidth(font: model.font)))
            case .image(let image, let percentage):
                let size = imageSize(font: model.font)
                elements.append(Element(content: .image(image), width: size.width))
                if let percentage, !percentage.isEmpty, let line = makeLine(percentage, font: model.font) {
                    elements.append(line)
                }
            }
        }
        guard !elements.isEmpty else { return Group(elements: [], width: 0) }
        let spacing = DSSpacing.xs * CGFloat(elements.count - 1)
        return Group(elements: elements, width: elements.reduce(0) { $0 + $1.width } + spacing)
    }

    private nonisolated static func makeLine(_ text: String, font: UIFont) -> Element? {
        guard !text.isEmpty else { return nil }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: UIColor.black]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return Element(content: .line(line), width: ceil(width))
    }

    /// Leading pinned left, trailing pinned right, centre centred — and when they
    /// would collide, laid out left to right so nothing overlaps. The SwiftUI bar
    /// got this from `maxWidth: .infinity` plus a layout priority; here it is
    /// arithmetic.
    private nonisolated static func slotOrigins(
        _ widths: [CGFloat],
        in rect: CGRect
    ) -> [CGFloat] {
        let leading = rect.minX
        let trailing = rect.maxX - widths[2]
        var centre = rect.midX - widths[1] / 2

        let leadingEnd = leading + widths[0] + (widths[0] > 0 ? DSSpacing.sm : 0)
        centre = max(centre, leadingEnd)
        if widths[1] > 0 {
            let centreEnd = centre + widths[1] + DSSpacing.sm
            if centreEnd > trailing, widths[2] > 0 {
                centre = max(leadingEnd, trailing - DSSpacing.sm - widths[1])
            }
        }
        return [leading, centre, trailing]
    }

    private nonisolated static func drawGroup(
        _ group: Group,
        at originX: CGFloat,
        midY: CGFloat,
        color: UIColor,
        imageAlpha: CGFloat,
        font: UIFont,
        canvasHeight: CGFloat,
        context ctx: CGContext
    ) {
        var x = originX
        for element in group.elements {
            switch element.content {
            case .line(let line):
                drawLine(line, x: x, midY: midY, color: color, font: font,
                         canvasHeight: canvasHeight, context: ctx)
            case .progress(let value):
                drawProgress(value, x: x, midY: midY, width: element.width,
                             color: color, font: font, context: ctx)
            case .image(let image):
                // Aspect-fit inside the slot the way `.resizable().scaledToFit()`
                // did in the SwiftUI bar — the SF battery symbol and an imported
                // template do not share an aspect ratio, and stretching either to
                // the box distorts it.
                let box = CGRect(x: x, y: midY - imageSize(font: font).height / 2,
                                 width: element.width, height: imageSize(font: font).height)
                image.draw(in: aspectFit(image.size, in: box), blendMode: .normal, alpha: imageAlpha)
            }
            x += element.width + DSSpacing.xs
        }
    }

    private nonisolated static func drawLine(
        _ line: CTLine,
        x: CGFloat,
        midY: CGFloat,
        color: UIColor,
        font: UIFont,
        canvasHeight: CGFloat,
        context ctx: CGContext
    ) {
        // Centre the cap-to-descender box on the row, not the full line box: a
        // font's leading is asymmetric and centring on it makes the text sit low.
        let baselineY = midY + (font.capHeight / 2)
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: canvasHeight - baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private nonisolated static func drawProgress(
        _ value: Double,
        x: CGFloat,
        midY: CGFloat,
        width: CGFloat,
        color: UIColor,
        font: UIFont,
        context ctx: CGContext
    ) {
        let height = max(2, (font.pointSize / 4).rounded())
        let track = CGRect(x: x, y: midY - height / 2, width: width, height: height)
        let radius = height / 2
        ctx.saveGState()
        ctx.setFillColor(color.withAlphaComponent(color.cgColor.alpha * 0.25).cgColor)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        let filledWidth = width * CGFloat(max(0, min(1, value)))
        if filledWidth > 0 {
            let filled = CGRect(x: track.minX, y: track.minY, width: max(height, filledWidth), height: height)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: filled, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: Shared sizing (kept identical to the SwiftUI field view it replaces)

    nonisolated static func imageSize(font: UIFont) -> CGSize {
        let height = font.lineHeight
        return CGSize(width: height * DSLayout.readerOverlayBatteryAspectRatio, height: height)
    }

    private nonisolated static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: box.midX - fitted.width / 2,
            y: box.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    nonisolated static func progressWidth(font: UIFont) -> CGFloat {
        min(
            max(
                DSLayout.readerOverlayProgressMinimumWidth,
                font.lineHeight * DSLayout.readerOverlayProgressWidthScale
            ),
            DSLayout.readerOverlayProgressMaximumWidth
        )
    }
}

// MARK: - One page's bars

/// The two bars as they belong to a single page, positioned in that page's own
/// coordinate space.
///
/// Paged mode hands this to `CoreTextPageView.renderPage`, which is what makes the
/// bars part of the page: they turn, curl and slide with it, and the incoming page
/// brings its own — the same thing legado gets for free by putting `ll_header` /
/// `ll_footer` inside `PageView` and snapshotting the whole view.
struct ReaderPageBars: Equatable {
    var header: ReaderBarRenderModel?
    var footer: ReaderBarRenderModel?
    /// Page top edge → header band top edge.
    var headerTopOffset: CGFloat
    /// Page bottom edge → footer band bottom edge.
    var footerBottomOffset: CGFloat

    var isEmpty: Bool { header == nil && footer == nil }

    static func extent(of model: ReaderBarRenderModel?) -> CGFloat {
        guard let model else { return 0 }
        return ReaderBarRenderer.extent(
            fontSize: model.font.pointSize,
            showsDivider: model.showsDivider
        )
    }

    /// - Parameter bounds: the page, in UIKit coordinates (origin top-left).
    func draw(in bounds: CGRect, context ctx: CGContext) {
        if let header {
            let extent = Self.extent(of: header)
            ReaderBarRenderer.draw(
                header,
                in: CGRect(
                    x: bounds.minX,
                    y: bounds.minY + headerTopOffset,
                    width: bounds.width,
                    height: extent
                ),
                canvasHeight: bounds.height,
                context: ctx
            )
        }
        if let footer {
            let extent = Self.extent(of: footer)
            ReaderBarRenderer.draw(
                footer,
                in: CGRect(
                    x: bounds.minX,
                    y: bounds.maxY - footerBottomOffset - extent,
                    width: bounds.width,
                    height: extent
                ),
                canvasHeight: bounds.height,
                context: ctx
            )
        }
    }
}

// MARK: - Scroll mode geometry

/// How the scrolling text area is cut to make room for the two fixed bars.
///
/// Scroll mode is the one place the bars are *not* part of the page: there is no
/// page, the text runs continuously, and the bars stay put while it moves. legado
/// does this by making its `ContentTextView` a layout sibling constrained between
/// the two dividers, so Android's own child clipping keeps the text out of the tip
/// rows; md3 states it as a policy (`ReaderViewportLayerPolicy`: in scroll mode the
/// background and the chrome belong to the viewport, not the page).
///
/// The band is taken out of the scroll view's *frame*, which is what produces the
/// hard cut — text that scrolls up disappears at the header's lower edge instead of
/// sliding through it. `contentInset` alone only pads the ends of the content; it
/// does not clip, which is why the text used to run straight over the bars.
struct ReaderScrollBarInsets: Equatable {
    /// Screen top edge → header band's lower edge. Clipped away.
    var topBand: CGFloat = 0
    /// Screen bottom edge → footer band's upper edge. Clipped away.
    var bottomBand: CGFloat = 0
    /// 上下邊距, inside what is left.
    var topMargin: CGFloat = 0
    var bottomMargin: CGFloat = 0

    static let zero = ReaderScrollBarInsets()
}
