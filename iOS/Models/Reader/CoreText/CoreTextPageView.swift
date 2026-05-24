import CoreText
import UIKit

/// Single-page CoreText rendering view.
/// Draws line-by-line using draw(_ rect:) (supporting CJK justified alignment), without snapshot caching or layer caching.
final class CoreTextPageView: UIView, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    private struct InteractionContext {
        let frame: CTFrame
        let lines: [CTLine]
        let origins: [CGPoint]
        let contentPathRect: CGRect
        let layoutSize: CGSize
        let scaleX: CGFloat
        let scaleY: CGFloat
        let writingMode: ReaderWritingMode
    }

    private var layout: CoreTextPaginator.ChapterLayout?
    private var localPageIndex: Int = 0
    private let interactor = TextSelectionInteractor()
    private let playbackOverlay = InteractionOverlayView()
    private let interactionOverlay = InteractionOverlayView()
    private var playbackHighlightText: String?
    private var textAnnotations: [CoreTextTextAnnotation] = []
    private var annotationOverlays: [LayerKey: InteractionOverlayView] = [:]

    private func annotationOverlay(for layer: CoreTextAnnotationRenderer.Layer) -> InteractionOverlayView {
        let key = LayerKey(style: layer.style, color: layer.color)
        if let existing = annotationOverlays[key] { return existing }
        let overlay = InteractionOverlayView()
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.fillColor = .clear
        overlay.showsHandles = false
        overlay.underlineColor = layer.color.uiColor.withAlphaComponent(0.85)
        if layer.style == .highlight {
            overlay.fillColor = layer.color.uiColor.withAlphaComponent(0.25)
            overlay.selectionRects = layer.rects
        } else {
            overlay.underlineRects = layer.rects
            overlay.drawsVerticalUnderlines = layout?.writingMode.isVertical ?? false
        }
        addSubview(overlay)
        annotationOverlays[key] = overlay
        return overlay
    }
    private enum SelectionDragHandle {
        case start
        case end
    }
    private var activeDragHandle: SelectionDragHandle?
    private lazy var linkTapGesture: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()
    private lazy var longPressGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        gesture.minimumPressDuration = 0.25
        return gesture
    }()
    private lazy var selectionHandlePanGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        return gesture
    }()

    var onInternalLinkTap: ((String) -> Void)?
    var onImageAttachmentTap: ((CoreTextPaginator.RenderedAttachment) -> Void)?

    private lazy var editMenuInteraction: UIEditMenuInteraction = {
        let interaction = UIEditMenuInteraction(delegate: self)
        return interaction
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        addInteraction(editMenuInteraction)
        playbackOverlay.frame = bounds
        playbackOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playbackOverlay.fillColor = UIColor.systemYellow.withAlphaComponent(0.28)
        playbackOverlay.showsHandles = false
        interactionOverlay.frame = bounds
        interactionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        interactionOverlay.fillColor = UIColor.systemYellow.withAlphaComponent(0.30)
        interactionOverlay.handleColor = UIColor(red: 0.63, green: 0.40, blue: 0.00, alpha: 1.0)
        addSubview(playbackOverlay)
        addSubview(interactionOverlay)

        addGestureRecognizer(linkTapGesture)
        addGestureRecognizer(longPressGesture)
        addGestureRecognizer(selectionHandlePanGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Sets the chapter layout and page index to render, automatically triggering a redraw.
    func configure(layout: CoreTextPaginator.ChapterLayout, pageIndex: Int, fallbackBackgroundColor: UIColor = .systemBackground) {
        self.layout = layout
        self.localPageIndex = pageIndex
        clearSelection()
        backgroundColor = layout.attributedString.length > 0
            ? layout.backgroundColor
            : fallbackBackgroundColor
        setNeedsDisplay()
        updatePlaybackHighlightOverlay()
    }

    func setPlaybackHighlight(text: String?) {
        playbackHighlightText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        updatePlaybackHighlightOverlay()
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        textAnnotations = annotations
        updateAnnotationOverlay()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard interactor.selectedTextForCopy?.isEmpty == false else { return false }
        return action == #selector(copy(_:)) || action == #selector(underlineSelection(_:))
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard interactor.selectedTextForCopy?.isEmpty == false else { return nil }
        var actions = suggestedActions

        if let existingAnnotation = interactor.tappedAnnotation {
            // Menu for existing annotation: change color, delete, add note
            let deleteAction = UIAction(
                title: localized("刪除標註"),
                image: nil,
                attributes: .destructive,
                handler: { [weak self] _ in
                    self?.deleteTappedAnnotation()
                }
            )
            actions.append(deleteAction)

            // Color submenu
            var colorActions: [UIAction] = []
            for color in AnnotationColor.allCases {
                let isCurrent = color == existingAnnotation.color
                colorActions.append(UIAction(
                    title: isCurrent ? "\(localized(colorName(for: color))) ✓" : localized(colorName(for: color)),
                    image: nil,
                    handler: { [weak self] _ in
                        self?.changeAnnotationColor(to: color)
                    }
                ))
            }
            let colorMenu = UIMenu(title: localized("顏色"), children: colorActions)
            actions.append(colorMenu)

            // Style toggle
            let currentStyle = existingAnnotation.style
            let otherStyle: AnnotationStyle = currentStyle == .underline ? .highlight : .underline
            actions.append(UIAction(
                title: localized(currentStyle == .underline ? "切換為螢光筆" : "切換為下劃線"),
                image: nil,
                handler: { [weak self] _ in
                    self?.changeAnnotationStyle(to: otherStyle)
                }
            ))
        } else {
            let removesExistingUnderline = selectedRangeHasExactUnderline()
            // Underline action
            actions.append(UIAction(
                title: localized(removesExistingUnderline ? "解除下劃線" : "下劃線"),
                image: nil,
                handler: { [weak self] _ in
                    self?.toggleUnderlineSelection(removesExistingUnderline: removesExistingUnderline)
                }
            ))
            // Highlight action (if not removing)
            if !removesExistingUnderline {
                actions.append(UIAction(
                    title: localized("螢光筆"),
                    image: nil,
                    handler: { [weak self] _ in
                        self?.toggleUnderlineSelection(removesExistingUnderline: false, style: .highlight, color: .yellow)
                    }
                ))
            }
        }

        return UIMenu(children: actions)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        configureTapPriority()
    }

    override func draw(_ rect: CGRect) {
        guard
            let layout,
            localPageIndex < layout.pageRanges.count,
            let ctx = UIGraphicsGetCurrentContext()
        else { return }

        Self.renderPage(
            layout: layout,
            pageIndex: localPageIndex,
            in: ctx,
            bounds: bounds
        )
    }

    nonisolated static func renderPage(
        layout: CoreTextPaginator.ChapterLayout,
        pageIndex: Int,
        in ctx: CGContext,
        bounds: CGRect
    ) {
        guard pageIndex < layout.pageRanges.count else { return }

        let layoutSize = CGSize(
            width: max(1, layout.renderSize.width),
            height: max(1, layout.renderSize.height)
        )
        let canonicalBounds = CGRect(origin: .zero, size: layoutSize)
        let scaleX = bounds.width / layoutSize.width
        let scaleY = bounds.height / layoutSize.height

        ctx.saveGState()
        ctx.translateBy(x: bounds.minX, y: bounds.minY)
        ctx.scaleBy(x: scaleX, y: scaleY)

        ctx.setFillColor(layout.backgroundColor.cgColor)
        ctx.fill(canonicalBounds)

        if layout.pageKinds[pageIndex] == .image {
            for attachment in layout.blockAttachments[pageIndex] ?? [] {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
            ctx.restoreGState()
            return
        }

        if let backgroundImage = layout.pageBackgroundImage {
            drawPageBackground(backgroundImage, in: canonicalBounds)
        }

        // Phase 1: CG geometry operations (background colors, borders) — coordinate-system independent
        drawBlockRenderables(layout.blockRenderables[pageIndex] ?? [], in: ctx, boundsHeight: layoutSize.height)

        let range = layout.pageRanges[pageIndex]

        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: layoutSize.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layoutSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let path = CGPath(rect: contentPathRect, transform: nil)
        let frame = CoreTextPaginator.makeFrame(
            framesetter: layout.framesetter,
            range: range,
            path: path,
            writingMode: layout.writingMode
        )

        // Collect ranges that will be redrawn by drawBlockRenderableText so drawLines can skip them.
        let suppressedRanges = (layout.blockRenderables[pageIndex] ?? [])
            .flatMap { $0.attributedText != nil ? $0.sourceRanges : [] }
        // ── Phase 2: text rendering ──────────────────────────────────────
        // Vertical (vertical-rl): CTFrameDraw handles glyph rotation
        // and right-to-left column progression automatically.
        // Horizontal: line-by-line drawing with CJK justification,
        // paragraph gap distribution, and HR divider lines.
        if layout.writingMode.isVertical {
            drawVerticalFrame(frame, in: ctx)
        } else {
            drawHorizontalFrame(
                frame,
                contentPathRect: contentPathRect,
                isLastPage: pageIndex == layout.pageRanges.count - 1,
                attributedString: layout.attributedString,
                suppressedRanges: suppressedRanges,
                in: ctx
            )
        }

        // Phase 3: after flip-back, draw all images using UIImage.draw()
        // UIImage.draw() requires the standard UIKit environment (origin top-left, Y downward)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -layoutSize.height)

        // 3a. Inline annotations (span.small notes). The main frame only
        // reserves their space through CTRunDelegate placeholders.
        let pageAnnotations = layout.inlineAnnotations[pageIndex] ?? []
        let pageInlineImages = layout.inlineAttachments[pageIndex] ?? []
        if !pageAnnotations.isEmpty || !pageInlineImages.isEmpty {
            CoreTextPaginator.debugVerticalLog("EPUBFLOW pageView.drawOverlays page=\(pageIndex) inlineAnnotations=\(pageAnnotations.count) inlineImages=\(pageInlineImages.count)")
        }
        drawInlineAnnotations(pageAnnotations)

        // 3b. Block attachments (block images without blockRenderStyle)
        Self.drawAttachments(layout.blockAttachments[pageIndex] ?? [])

        // 3c. Inline attachments (inline images)
        for attachment in pageInlineImages {
            attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
        }

        // 3d. Block images (decorative images with blockRenderStyle, e.g. watermarks)
        for item in layout.blockRenderables[pageIndex] ?? [] {
            if let attachment = item.imageAttachment {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
        }

        // 3e. Explicit block text (page/card-level geometry text, independent of the main text frame)
        for item in layout.blockRenderables[pageIndex] ?? [] {
            guard let text = item.attributedText else { continue }
            drawBlockRenderableText(
                text,
                in: item.rect,
                paddingTop: item.style.paddingTop,
                paddingLeft: item.style.paddingLeft,
                paddingBottom: item.style.paddingBottom,
                paddingRight: item.style.paddingRight,
                boundsHeight: layoutSize.height,
                context: ctx
            )
        }

        ctx.restoreGState()
    }

    nonisolated static func drawAttachments(_ attachments: [CoreTextPaginator.RenderedAttachment]) {
        for attachment in attachments {
            attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
        }
    }

    nonisolated static func drawInlineAnnotations(
        _ annotations: [CoreTextPaginator.RenderedInlineAnnotation]
    ) {
        guard !annotations.isEmpty else { return }
        CoreTextPaginator.debugVerticalLog("EPUBFLOW drawInlineAnnotations count=\(annotations.count)")
        for (index, annotation) in annotations.enumerated() where annotation.attributedString.length > 0 {
            CoreTextPaginator.debugVerticalLog("EPUBFLOW drawInlineAnnotation[\(index)] uiRect=\(annotation.uiRect) len=\(annotation.attributedString.length) text=\"\(inlineAnnotationDebugPreview(annotation.attributedString.string, limit: 80))\"")
            drawInlineAnnotationContent(annotation.attributedString, in: annotation.uiRect)
        }
    }

    private nonisolated static func drawInlineAnnotationContent(
        _ attributedString: NSAttributedString,
        in rect: CGRect
    ) {
        let items = inlineAnnotationItems(from: attributedString)
        guard !items.isEmpty else { return }
        CoreTextPaginator.debugVerticalLog("EPUBFLOW drawInlineAnnotationContent rect=\(rect) itemCount=\(items.count) centerX=\(rect.midX) topY=\(rect.minY) maxY=\(rect.maxY)")
        drawInlineAnnotationColumn(items, centerX: rect.midX, topY: rect.minY, maxY: rect.maxY)
    }

    private struct InlineAnnotationItem {
        enum Content {
            case image(UIImage, CGSize, CGFloat)
            case text(NSAttributedString)
        }

        let content: Content
        let advance: CGFloat
    }

    private nonisolated static func inlineAnnotationItems(from attributedString: NSAttributedString) -> [InlineAnnotationItem] {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let nsString = attributedString.string as NSString
        var result: [InlineAnnotationItem] = []
        var index = 0

        while index < attributedString.length {
            var effectiveRange = NSRange(location: 0, length: 0)
            if let delegate = attributedString.attribute(delegateKey, at: index, effectiveRange: &effectiveRange) {
                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                if let image = info.image {
                    result.append(InlineAnnotationItem(
                        content: .image(image, CGSize(width: info.drawWidth, height: info.drawHeight), info.opacity),
                        advance: max(1, info.width)
                    ))
                }
                index = max(index + 1, effectiveRange.location + effectiveRange.length)
                continue
            }

            let characterRange = nsString.rangeOfComposedCharacterSequence(at: index)
            let char = NSMutableAttributedString(attributedString: attributedString.attributedSubstring(from: characterRange))
            if !char.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(InlineAnnotationItem(
                    content: .text(char),
                    advance: verticalAnnotationAdvance(for: char)
                ))
            }
            index = characterRange.location + characterRange.length
        }

        return result
    }

    private nonisolated static func drawInlineAnnotationColumn(
        _ items: [InlineAnnotationItem],
        centerX: CGFloat,
        topY: CGFloat,
        maxY: CGFloat
    ) {
        var cursorY = topY
        for item in items where cursorY < maxY {
            switch item.content {
            case .image(let image, let size, let opacity):
                let y = cursorY + max(0, (item.advance - size.height) / 2)
                let imageRect = CGRect(
                    x: centerX - size.width / 2,
                    y: y,
                    width: size.width,
                    height: size.height
                )
                image.draw(in: imageRect, blendMode: .normal, alpha: opacity)
            case .text(let text):
                let drawAdvance = verticalAnnotationAdvance(for: text)
                let drawRect = CGRect(
                    x: centerX - drawAdvance / 2,
                    y: cursorY,
                    width: drawAdvance,
                    height: drawAdvance
                )
                centeredInlineAnnotationText(text).draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
            }
            cursorY += item.advance
        }
    }

    private nonisolated static func verticalAnnotationAdvance(for attributedString: NSAttributedString) -> CGFloat {
        RunDelegateProvider.inlineAnnotationTextAdvance(for: attributedString)
    }

    private nonisolated static func centeredInlineAnnotationText(_ attributedString: NSAttributedString) -> NSAttributedString {
        guard attributedString.length > 0 else { return attributedString }
        let mutable = NSMutableAttributedString(attributedString: RunDelegateProvider.sanitizedInlineAnnotationString(attributedString))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        mutable.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: mutable.length))
        return mutable
    }

    private nonisolated static func inlineAnnotationDebugPreview(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{FFFC}", with: "OBJ")
            .replacingOccurrences(of: "\u{3000}", with: "IDEOSPACE")
        return String(normalized.prefix(limit))
    }

    /// Draws all text lines of a CTFrame line-by-line, applying CTLineCreateJustifiedLine for justified non-last lines.
    /// Shared between draw(_ rect:) and CoreTextPageEngine.generateSnapshot().
    /// The CTM must already be configured for the CoreText coordinate system (y-axis flipped upward) before calling.
    /// - Parameters:
    ///   - contentMinX: Left edge of the content area (CoreText coordinates), used for drawing HR line start points
    ///   - contentMinY: Bottom of the content area (CoreText coordinates), used for calculating last-page remaining space
    ///   - isLastPage: Whether this is the last page of the chapter; last pages do not apply vertical justification
    // MARK: - Phase 2a: Vertical text rendering

    /// Draw a CTFrame in vertical-rl mode.
    /// CoreText handles glyph rotation and RTL column progression internally.
    private nonisolated static func drawVerticalFrame(_ frame: CTFrame, in ctx: CGContext) {
        CTFrameDraw(frame, ctx)
    }

    // MARK: - Phase 2b: Horizontal text rendering

    /// Draw a CTFrame in horizontal mode: line-by-line with CJK justification,
    /// paragraph gap distribution, and HR divider lines.
    private nonisolated static func drawHorizontalFrame(
        _ frame: CTFrame,
        contentPathRect: CGRect,
        isLastPage: Bool,
        attributedString: NSAttributedString,
        suppressedRanges: [NSRange],
        in ctx: CGContext
    ) {
        CoreTextHorizontalLineDrawer.drawLines(
            of: frame,
            contentWidth: contentPathRect.width,
            contentMinX: contentPathRect.minX,
            contentMinY: contentPathRect.minY,
            isLastPage: isLastPage,
            attrStr: attributedString,
            suppressedRanges: suppressedRanges,
            hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
            in: ctx
        )
    }

    // isCJKDominant moved to CoreTextHorizontalLineDrawer

    nonisolated static func drawBlockRenderables(
        _ renderables: [CoreTextPaginator.RenderedBlockRenderable],
        in ctx: CGContext,
        boundsHeight: CGFloat
    ) {
        for item in renderables {
            ctx.saveGState()
            let s = item.style
            let borderRect = CGRect(
                x: item.rect.minX - s.borderLeftWidth - s.paddingLeft,
                y: item.rect.minY - s.borderTopWidth - s.paddingTop,
                width: item.rect.width + s.borderLeftWidth + s.borderRightWidth + s.paddingLeft + s.paddingRight,
                height: item.rect.height + s.borderTopWidth + s.borderBottomWidth + s.paddingTop + s.paddingBottom
            )
            let radius = min(s.borderRadius, min(borderRect.width, borderRect.height) / 2)
            let hasBorder = s.borderTopWidth > 0 || s.borderBottomWidth > 0 || s.borderLeftWidth > 0 || s.borderRightWidth > 0
            if radius > 0 {
                let path = UIBezierPath(roundedRect: borderRect, cornerRadius: radius)
                if let fillColor = s.backgroundFillColor {
                    ctx.setFillColor(fillColor.cgColor)
                    ctx.addPath(path.cgPath)
                    ctx.fillPath()
                }
                if hasBorder {
                    if let borderColor = s.borderTopColor ?? s.borderLeftColor ?? s.borderRightColor ?? s.borderBottomColor {
                        ctx.setStrokeColor(borderColor.cgColor)
                    } else {
                        ctx.setStrokeColor(UIColor.label.cgColor)
                    }
                    ctx.setLineWidth(s.borderTopWidth > 0 ? s.borderTopWidth : (s.borderBottomWidth > 0 ? s.borderBottomWidth : (s.borderLeftWidth > 0 ? s.borderLeftWidth : s.borderRightWidth)))
                    ctx.addPath(path.cgPath)
                    ctx.strokePath()
                }
            } else {
                if let fillColor = s.backgroundFillColor {
                    ctx.setFillColor(fillColor.cgColor)
                    ctx.fill(borderRect)
                }
                if s.borderTopWidth > 0 {
                    let lineW = s.borderTopWidth
                    let y = borderRect.minY + lineW / 2
                    ctx.setStrokeColor((s.borderTopColor ?? .label).cgColor)
                    ctx.setLineWidth(lineW)
                    let (bx, bw) = borderXAndWidth(for: item, borderRect: borderRect)
                    ctx.move(to: CGPoint(x: bx, y: y))
                    ctx.addLine(to: CGPoint(x: bx + bw, y: y))
                    ctx.strokePath()
                }
                if s.borderBottomWidth > 0 {
                    let lineW = s.borderBottomWidth
                    let y = borderRect.maxY - lineW / 2
                    ctx.setStrokeColor((s.borderBottomColor ?? .label).cgColor)
                    ctx.setLineWidth(lineW)
                    let (bx, bw) = borderXAndWidth(for: item, borderRect: borderRect)
                    ctx.move(to: CGPoint(x: bx, y: y))
                    ctx.addLine(to: CGPoint(x: bx + bw, y: y))
                    ctx.strokePath()
                }
                if s.borderLeftWidth > 0 {
                    let lineW = s.borderLeftWidth
                    let x = borderRect.minX + lineW / 2
                    ctx.setStrokeColor((s.borderLeftColor ?? .label).cgColor)
                    ctx.setLineWidth(lineW)
                    ctx.move(to: CGPoint(x: x, y: borderRect.minY))
                    ctx.addLine(to: CGPoint(x: x, y: borderRect.maxY))
                    ctx.strokePath()
                }
                if s.borderRightWidth > 0 {
                    let lineW = s.borderRightWidth
                    let x = borderRect.maxX - lineW / 2
                    ctx.setStrokeColor((s.borderRightColor ?? .label).cgColor)
                    ctx.setLineWidth(lineW)
                    ctx.move(to: CGPoint(x: x, y: borderRect.minY))
                    ctx.addLine(to: CGPoint(x: x, y: borderRect.maxY))
                    ctx.strokePath()
                }
            }
            // Block images are drawn uniformly in Phase 3 (after flip-back) using UIImage.draw()
            ctx.restoreGState()
        }
    }

    // Calculates the starting x and width for border rendering based on style.width and textAlign
    private nonisolated static func borderXAndWidth(for item: CoreTextPaginator.RenderedBlockRenderable, borderRect: CGRect? = nil) -> (CGFloat, CGFloat) {
        let rect = borderRect ?? item.rect
        guard let constrainedWidth = item.style.width else {
            return (rect.minX, rect.width)
        }
        let bw = min(constrainedWidth, rect.width)
        let bx: CGFloat
        switch item.style.textAlign {
        case .center:
            bx = rect.minX + max(0, (rect.width - bw) / 2)
        case .right:
            bx = rect.minX + max(0, rect.width - bw)
        default:
            bx = rect.minX
        }
        return (bx, bw)
    }

    nonisolated static func drawBlockRenderableText(
        _ text: NSAttributedString,
        in rect: CGRect,
        paddingTop: CGFloat,
        paddingLeft: CGFloat,
        paddingBottom: CGFloat,
        paddingRight: CGFloat,
        boundsHeight: CGFloat,
        context ctx: CGContext
    ) {
        let contentRect = CGRect(
            x: rect.minX + paddingLeft,
            y: rect.minY + paddingTop,
            width: max(1, rect.width - paddingLeft - paddingRight),
            height: max(1, rect.height - paddingTop - paddingBottom)
        )
        let framesetter = CoreTextFramesetterFactory.make(for: text)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: text.length),
            nil,
            CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
            nil
        )
        let measuredHeight = ceil(suggestedSize.height)
        let drawRect = CGRect(
            x: contentRect.minX,
            y: contentRect.minY + max(0, (contentRect.height - measuredHeight) / 2),
            width: contentRect.width,
            height: min(contentRect.height, measuredHeight)
        )
        let coreTextRect = CGRect(
            x: drawRect.minX,
            y: boundsHeight - drawRect.maxY,
            width: drawRect.width,
            height: drawRect.height
        )
        let path = CGPath(rect: coreTextRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: text.length),
            path,
            nil
        )

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: boundsHeight)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    nonisolated static func drawPageBackground(_ image: UIImage, in bounds: CGRect) {
        let drawRect = backgroundImageRect(for: image.size, in: bounds)
        image.draw(in: drawRect)
    }

    private nonisolated static func backgroundImageRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    @objc override func copy(_ sender: Any?) {
        guard let text = interactor.selectedTextForCopy, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    @objc private func underlineSelection(_ sender: Any?) {
        toggleUnderlineSelection(removesExistingUnderline: selectedRangeHasExactUnderline())
    }

    private func toggleUnderlineSelection(removesExistingUnderline: Bool, style: AnnotationStyle = .underline, color: AnnotationColor = .yellow) {
        guard let layout,
              let range = interactor.selectionManager.selectedRange,
              range.length > 0,
              range.location >= 0,
              range.location + range.length <= layout.attributedString.length
        else { return }
        let excerpt = interactor.selectedTextForCopy ?? interactor.selectionManager.selectedText(in: layout.attributedString) ?? ""
        if removesExistingUnderline {
            let (remaining, _) = AnnotationStore.removeExact(
                spineIndex: layout.spineIndex,
                range: range,
                from: textAnnotations
            )
            textAnnotations = remaining
        } else {
            let newAnnotation = CoreTextTextAnnotation(
                spineIndex: layout.spineIndex,
                range: range,
                style: style,
                color: color
            )
            let (merged, _) = AnnotationStore.merge(newAnnotation, into: textAnnotations)
            textAnnotations = merged
        }
        updateAnnotationOverlay()
        NotificationCenter.default.post(
            name: .coreTextUnderlineSelectionRequested,
            object: self,
            userInfo: [
                "request": CoreTextUnderlineSelectionRequest(
                    position: CoreTextReadingPosition(
                        spineIndex: layout.spineIndex,
                        charOffset: range.location
                    ),
                    length: range.length,
                    excerpt: excerpt.trimmingCharacters(in: .whitespacesAndNewlines),
                    removesExistingUnderline: removesExistingUnderline,
                    style: style,
                    color: color
                )
            ]
        )
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let layout,
              localPageIndex < layout.pageRanges.count
        else {
            return
        }

        let point = gesture.location(in: self)

        if interactor.selectionManager.hasSelection {
            // If tap is on the existing selection, keep it and show menu again
            if let context = makeInteractionContext(),
               let index = stringIndex(at: point, in: context),
               let selRange = interactor.selectionManager.selectedRange,
               index >= selRange.location,
               index < selRange.location + selRange.length {
                interactor.selectedTextForCopy = interactor.selectionManager.selectedText(in: layout.attributedString)
                interactor.tappedAnnotation = AnnotationStore.annotationAt(
                    spineIndex: layout.spineIndex,
                    charOffset: index,
                    in: textAnnotations,
                    tolerance: 3
                )
                becomeFirstResponder()
                editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
                    identifier: nil,
                    sourcePoint: point))
                return
            }
            clearSelection()
            return
        }

        if let attachment = imageAttachment(at: point) {
            onImageAttachmentTap?(attachment)
            return
        }

        guard let context = makeInteractionContext(),
              let index = stringIndex(at: point, in: context)
        else {
            return
        }

        // Hit-test existing annotation first
        if let annotation = AnnotationStore.annotationAt(
            spineIndex: layout.spineIndex,
            charOffset: index,
            in: textAnnotations,
            tolerance: 3
        ) {
            interactor.tappedAnnotation = annotation
            interactor.selectionManager.setSelection(range: annotation.range, maxLength: layout.attributedString.length)
            updateSelectionOverlay(with: context)
            interactor.selectedTextForCopy = interactor.selectionManager.selectedText(in: layout.attributedString)
            becomeFirstResponder()
            editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: point))
            return
        }

        // Fall through to link detection
        guard let href = HTMLAttributedStringBuilder.linkHref(at: index, in: layout.attributedString) else {
            return
        }

        onInternalLinkTap?(href)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === linkTapGesture else { return true }
        return shouldHandleTap(at: touch.location(in: self))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === selectionHandlePanGesture {
            return interactor.selectionManager.hasSelection
                && nearestHandle(to: selectionHandlePanGesture.location(in: self)) != nil
        }
        return true
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let layout,
              localPageIndex < layout.pageRanges.count,
              let context = makeInteractionContext(),
              let index = stringIndex(at: gesture.location(in: self), in: context)
        else {
            if gesture.state == .cancelled || gesture.state == .failed {
                clearSelection()
            }
            return
        }

        switch gesture.state {
        case .began:
            let paragraphRange = defaultSelectionRange(around: index, in: layout.attributedString)
            // Snap selection to nearby annotations
            let snappedRange = AnnotationStore.expandedSelectionRange(
                spineIndex: layout.spineIndex,
                start: paragraphRange.location,
                end: paragraphRange.location + paragraphRange.length,
                in: textAnnotations,
                tolerance: 2
            )
            // If selection is fully inside an existing annotation, mark it for edit
            interactor.tappedAnnotation = AnnotationStore.annotationFullyContaining(
                spineIndex: layout.spineIndex,
                range: snappedRange,
                in: textAnnotations
            )
            interactor.selectionManager.setSelection(range: snappedRange, maxLength: layout.attributedString.length)
            updateSelectionOverlay(with: context)
        case .ended:
            updateSelectionOverlay(with: context)
            guard interactor.selectionManager.hasSelection else { return }
            interactor.selectedTextForCopy = interactor.selectionManager.selectedText(in: layout.attributedString)
            // If no tapped annotation found yet, check if selection is on an annotation
            if interactor.tappedAnnotation == nil, let selRange = interactor.selectionManager.selectedRange {
                interactor.tappedAnnotation = AnnotationStore.annotationAt(
                    spineIndex: layout.spineIndex,
                    charOffset: selRange.location,
                    in: textAnnotations,
                    tolerance: 0
                )
            }
            becomeFirstResponder()
            let point = gesture.location(in: self)
            editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: point))
        case .cancelled, .failed:
            clearSelection()
        default:
            break
        }
    }

    @objc private func handleSelectionHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard interactor.selectionManager.hasSelection,
              let layout,
              localPageIndex < layout.pageRanges.count,
              let context = makeInteractionContext()
        else {
            activeDragHandle = nil
            return
        }

        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            activeDragHandle = nearestHandle(to: point)
        case .changed:
            guard let activeDragHandle,
                  let index = stringIndex(at: point, in: context) else { return }
            switch activeDragHandle {
            case .start:
                interactor.selectionManager.updateSelectionStart(to: index, maxLength: layout.attributedString.length)
            case .end:
                interactor.selectionManager.updateSelectionEnd(to: index, maxLength: layout.attributedString.length)
            }
            // Snap to annotation boundaries
            if let selRange = interactor.selectionManager.selectedRange {
                let snapped = AnnotationStore.expandedSelectionRange(
                    spineIndex: layout.spineIndex,
                    start: selRange.location,
                    end: selRange.location + selRange.length,
                    in: textAnnotations,
                    tolerance: 3
                )
                if snapped != selRange {
                    interactor.selectionManager.setSelection(range: snapped, maxLength: layout.attributedString.length)
                }
            }
            updateSelectionOverlay(with: context)
            interactor.selectedTextForCopy = interactor.selectionManager.selectedText(in: layout.attributedString)
        case .ended:
            interactor.selectedTextForCopy = interactor.selectionManager.selectedText(in: layout.attributedString)
            if let selRange = interactor.selectionManager.selectedRange {
                interactor.tappedAnnotation = AnnotationStore.annotationFullyContaining(
                    spineIndex: layout.spineIndex,
                    range: selRange,
                    in: textAnnotations
                )
            }
            becomeFirstResponder()
            editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: point))
            activeDragHandle = nil
        case .cancelled, .failed:
            activeDragHandle = nil
        default:
            break
        }
    }

    private func configureTapPriority() {
        var current: UIView? = superview
        while let view = current {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer !== linkTapGesture,
                      recognizer is UITapGestureRecognizer
                else { continue }
                recognizer.require(toFail: linkTapGesture)
            }
            current = view.superview
        }
    }

    private func shouldHandleTap(at point: CGPoint) -> Bool {
        if interactor.selectionManager.hasSelection {
            return true
        }

        if imageAttachment(at: point) != nil {
            return true
        }

        guard let layout,
              localPageIndex < layout.pageRanges.count,
              let context = makeInteractionContext(),
              let index = stringIndex(at: point, in: context),
              HTMLAttributedStringBuilder.linkHref(at: index, in: layout.attributedString) != nil
        else {
            return false
        }
        return true
    }

    private func imageAttachment(at point: CGPoint) -> CoreTextPaginator.RenderedAttachment? {
        guard let layout,
              localPageIndex < layout.pageRanges.count,
              layout.renderSize.width > 0,
              layout.renderSize.height > 0
        else {
            return nil
        }

        let scaleX = bounds.width / layout.renderSize.width
        let scaleY = bounds.height / layout.renderSize.height
        let attachments = (layout.inlineAttachments[localPageIndex] ?? [])
            + (layout.blockAttachments[localPageIndex] ?? [])
            + (layout.blockRenderables[localPageIndex] ?? []).compactMap(\.imageAttachment)

        return attachments.first { attachment in
            let rect = CGRect(
                x: bounds.minX + attachment.rect.minX * scaleX,
                y: bounds.minY + attachment.rect.minY * scaleY,
                width: attachment.rect.width * scaleX,
                height: attachment.rect.height * scaleY
            )
            return rect.insetBy(dx: -8, dy: -8).contains(point)
        }
    }

    private func clearSelection() {
        interactor.selectionManager.clear()
        interactor.selectedTextForCopy = nil
        interactor.tappedAnnotation = nil
        activeDragHandle = nil
        interactionOverlay.clearSelection()
        editMenuInteraction.dismissMenu()
    }

    private func defaultSelectionRange(around index: Int, in attributedString: NSAttributedString) -> NSRange {
        guard attributedString.length > 0 else { return NSRange(location: 0, length: 0) }
        let nsString = attributedString.string as NSString
        var range = nsString.paragraphRange(for: NSRange(location: min(max(index, 0), attributedString.length - 1), length: 0))
        while range.length > 0 {
            let first = nsString.character(at: range.location)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(first)!) {
                range.location += 1
                range.length -= 1
            } else {
                break
            }
        }
        while range.length > 0 {
            let lastIndex = range.location + range.length - 1
            let last = nsString.character(at: lastIndex)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(last)!) {
                range.length -= 1
            } else {
                break
            }
        }
        if range.length > 0 { return range }
        return NSRange(location: min(max(index, 0), attributedString.length - 1), length: 1)
    }

    private func nearestHandle(to point: CGPoint) -> SelectionDragHandle? {
        let hitRadius: CGFloat = 36
        let start = interactionOverlay.startHandlePoint
        let end = interactionOverlay.endHandlePoint
        let startDistance = start.map { hypot($0.x - point.x, $0.y - point.y) } ?? .greatestFiniteMagnitude
        let endDistance = end.map { hypot($0.x - point.x, $0.y - point.y) } ?? .greatestFiniteMagnitude
        let best = min(startDistance, endDistance)
        guard best <= hitRadius else { return nil }
        return startDistance <= endDistance ? .start : .end
    }

    private func makeInteractionContext() -> InteractionContext? {
        guard let layout,
              localPageIndex < layout.pageRanges.count,
              bounds.width > 0,
              bounds.height > 0
        else {
            return nil
        }

        let layoutSize = CGSize(
            width: max(1, layout.renderSize.width),
            height: max(1, layout.renderSize.height)
        )
        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layoutSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let range = layout.pageRanges[localPageIndex]
        let path = CGPath(rect: contentPathRect, transform: nil)
        let frame = CoreTextPaginator.makeFrame(
            framesetter: layout.framesetter,
            range: range,
            path: path,
            writingMode: layout.writingMode
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        return InteractionContext(
            frame: frame,
            lines: lines,
            origins: origins,
            contentPathRect: contentPathRect,
            layoutSize: layoutSize,
            scaleX: bounds.width / layoutSize.width,
            scaleY: bounds.height / layoutSize.height,
            writingMode: layout.writingMode
        )
    }

    private func stringIndex(at point: CGPoint, in context: InteractionContext) -> Int? {
        let canonical = CGPoint(
            x: (point.x - bounds.minX) / context.scaleX,
            y: (point.y - bounds.minY) / context.scaleY
        )
        if context.writingMode.isVertical {
            return verticalStringIndex(atCanonicalPoint: canonical, in: context)
        }
        let coreY = context.layoutSize.height - canonical.y
        guard let lineIdx = nearestLineIndex(for: coreY, in: context) else { return nil }

        let line = context.lines[lineIdx]
        let lineOrigin = context.origins[lineIdx]
        let lineX = context.contentPathRect.minX + lineOrigin.x

        // Check horizontal bounds: tap must be within the line's actual typographic width.
        // CTLineGetStringIndexForPosition returns the nearest character even for taps far to the right,
        // which makes blank space trigger links and blocks page-turning.
        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &lineLeading))
        let textEndX = lineX + lineWidth
        // Allow small fudge for touch precision, but not the entire right margin
        let tapTolerance: CGFloat = 10
        guard canonical.x >= lineX - tapTolerance,
              canonical.x <= textEndX + tapTolerance
        else {
            return nil
        }

        let relativeX = canonical.x - lineX
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, relativeX), y: 0))
        if index != kCFNotFound {
            return max(0, index)
        }

        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return nil }
        if relativeX <= 0 {
            return max(0, range.location)
        }
        return max(0, range.location + range.length - 1)
    }

    private func verticalStringIndex(atCanonicalPoint point: CGPoint, in context: InteractionContext) -> Int? {
        guard let lineIdx = nearestVerticalLineIndex(forCanonicalX: point.x, in: context) else { return nil }
        let line = context.lines[lineIdx]
        let lineOrigin = context.origins[lineIdx]

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineAdvance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let baselineX = context.contentPathRect.minX + lineOrigin.x
        let x1 = baselineX - descent
        let x2 = baselineX + ascent
        let minX = min(x1, x2)
        let maxX = max(x1, x2)
        let tapTolerance: CGFloat = 10
        guard point.x >= minX - tapTolerance,
              point.x <= maxX + tapTolerance
        else {
            return nil
        }

        let lineTopY = context.layoutSize.height - (context.contentPathRect.minY + lineOrigin.y)
        let relativeAdvance = point.y - lineTopY
        guard relativeAdvance >= -tapTolerance,
              relativeAdvance <= lineAdvance + tapTolerance
        else {
            return nil
        }

        let index = CTLineGetStringIndexForPosition(
            line,
            CGPoint(x: max(0, min(lineAdvance, relativeAdvance)), y: 0)
        )
        if index != kCFNotFound {
            return max(0, index)
        }

        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return nil }
        if relativeAdvance <= 0 {
            return max(0, range.location)
        }
        return max(0, range.location + range.length - 1)
    }

    private func nearestLineIndex(for coreY: CGFloat, in context: InteractionContext) -> Int? {
        guard !context.lines.isEmpty else { return nil }

        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for idx in context.lines.indices {
            let line = context.lines[idx]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baselineY = context.contentPathRect.minY + context.origins[idx].y
            let minY = baselineY - descent
            let maxY = baselineY + ascent

            if coreY >= minY && coreY <= maxY {
                return idx
            }

            let distance: CGFloat
            if coreY < minY {
                distance = minY - coreY
            } else {
                distance = coreY - maxY
            }

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = idx
            }
        }

        return bestIndex
    }

    private func nearestVerticalLineIndex(forCanonicalX x: CGFloat, in context: InteractionContext) -> Int? {
        guard !context.lines.isEmpty else { return nil }

        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        let tapTolerance: CGFloat = 10

        for idx in context.lines.indices {
            let line = context.lines[idx]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baselineX = context.contentPathRect.minX + context.origins[idx].x
            let x1 = baselineX - descent
            let x2 = baselineX + ascent
            let minX = min(x1, x2)
            let maxX = max(x1, x2)

            if x >= minX && x <= maxX {
                return idx
            }

            let distance = x < minX ? minX - x : x - maxX
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = idx
            }
        }

        guard bestDistance <= tapTolerance else { return nil }
        return bestIndex
    }

    private func updateSelectionOverlay(with context: InteractionContext) {
        guard let range = interactor.selectionManager.selectedRange,
              range.length > 0
        else {
            interactionOverlay.clearSelection()
            return
        }

        let rects = selectionRects(for: range, in: context)
        interactionOverlay.selectionRects = rects
        interactionOverlay.startHandlePoint = rects.first.map { CGPoint(x: $0.minX, y: $0.minY) }
        interactionOverlay.endHandlePoint = rects.last.map { CGPoint(x: $0.maxX, y: $0.maxY) }
    }

    private func updateAnnotationOverlay() {
        guard let layout,
              localPageIndex < layout.pageRanges.count,
              let context = makeInteractionContext()
        else {
            for overlay in annotationOverlays.values {
                overlay.clearSelection()
                overlay.isHidden = true
            }
            return
        }
        let pageCFRange = layout.pageRanges[localPageIndex]
        let pageRange = NSRange(location: pageCFRange.location, length: pageCFRange.length)

        let layers = CoreTextAnnotationRenderer.render(
            annotations: textAnnotations,
            spineIndex: layout.spineIndex,
            pageCharRange: pageRange,
            lines: context.lines,
            lineOrigins: context.origins,
            contentOffset: CGPoint(x: context.contentPathRect.minX, y: context.contentPathRect.minY),
            layoutHeight: context.layoutSize.height,
            writingMode: context.writingMode
        )

        // Scale rects to view coordinates
        let scaledLayers = layers.map { layer -> CoreTextAnnotationRenderer.Layer in
            let scaledRects = layer.rects.map { rect in
                CGRect(
                    x: rect.minX * context.scaleX + bounds.minX,
                    y: rect.minY * context.scaleY + bounds.minY,
                    width: rect.width * context.scaleX,
                    height: rect.height * context.scaleY
                )
            }
            return CoreTextAnnotationRenderer.Layer(rects: scaledRects, style: layer.style, color: layer.color)
        }

        // Update or create overlay for each layer
        var activeKeys = Set<LayerKey>()
        for layer in scaledLayers {
            let key = LayerKey(style: layer.style, color: layer.color)
            activeKeys.insert(key)
            let overlay = annotationOverlay(for: layer)
            overlay.frame = bounds
            if layer.style == .highlight {
                overlay.fillColor = layer.color.uiColor.withAlphaComponent(0.25)
                overlay.selectionRects = layer.rects
                overlay.underlineRects = []
            } else {
                overlay.fillColor = .clear
                overlay.underlineColor = layer.color.uiColor.withAlphaComponent(0.85)
                overlay.underlineRects = layer.rects
                overlay.drawsVerticalUnderlines = layout.writingMode.isVertical
                overlay.selectionRects = []
            }
            overlay.startHandlePoint = nil
            overlay.endHandlePoint = nil
            overlay.isHidden = false
        }

        // Hide unused overlays
        for (key, overlay) in annotationOverlays where !activeKeys.contains(key) {
            overlay.isHidden = true
            overlay.clearSelection()
        }
    }

    private func selectedRangeHasExactUnderline() -> Bool {
        guard let layout,
              let range = interactor.selectionManager.selectedRange,
              range.length > 0
        else { return false }
        return textAnnotations.contains {
            $0.spineIndex == layout.spineIndex && NSEqualRanges($0.range, range)
        }
    }

    private func deleteTappedAnnotation() {
        guard let annotation = interactor.tappedAnnotation else { return }
        textAnnotations.removeAll { $0.id == annotation.id }
        updateAnnotationOverlay()
        NotificationCenter.default.post(
            name: .coreTextUnderlineSelectionRequested,
            object: self,
            userInfo: [
                "request": CoreTextUnderlineSelectionRequest(
                    position: CoreTextReadingPosition(
                        spineIndex: annotation.spineIndex,
                        charOffset: annotation.startOffset
                    ),
                    length: annotation.range.length,
                    excerpt: interactor.selectedTextForCopy ?? "",
                    removesExistingUnderline: true,
                    style: annotation.style,
                    color: annotation.color
                )
            ]
        )
        clearSelection()
    }

    private func changeAnnotationColor(to color: AnnotationColor) {
        guard var annotation = interactor.tappedAnnotation,
              let layout,
              let context = makeInteractionContext()
        else { return }
        annotation.color = color
        let (merged, _) = AnnotationStore.merge(annotation, into: textAnnotations)
        textAnnotations = merged
        interactor.tappedAnnotation = textAnnotations.first { $0.spineIndex == annotation.spineIndex && $0.range == annotation.range }
        updateAnnotationOverlay()
        updateSelectionOverlay(with: context)
        notifyAnnotationChange()
    }

    private func changeAnnotationStyle(to style: AnnotationStyle) {
        guard var annotation = interactor.tappedAnnotation,
              let layout,
              let context = makeInteractionContext()
        else { return }
        annotation.style = style
        let (merged, _) = AnnotationStore.merge(annotation, into: textAnnotations)
        textAnnotations = merged
        interactor.tappedAnnotation = textAnnotations.first { $0.spineIndex == annotation.spineIndex && $0.range == annotation.range }
        updateAnnotationOverlay()
        updateSelectionOverlay(with: context)
        notifyAnnotationChange()
    }

    private func notifyAnnotationChange() {
        guard let annotation = interactor.tappedAnnotation else { return }
        NotificationCenter.default.post(
            name: .coreTextUnderlineSelectionRequested,
            object: self,
            userInfo: [
                "request": CoreTextUnderlineSelectionRequest(
                    position: CoreTextReadingPosition(
                        spineIndex: annotation.spineIndex,
                        charOffset: annotation.startOffset
                    ),
                    length: annotation.range.length,
                    excerpt: interactor.selectedTextForCopy ?? "",
                    removesExistingUnderline: false,
                    style: annotation.style,
                    color: annotation.color
                )
            ]
        )
    }

    private func colorName(for color: AnnotationColor) -> String {
        switch color {
        case .yellow: return "黃色"
        case .green: return "綠色"
        case .blue: return "藍色"
        case .pink: return "粉色"
        case .orange: return "橙色"
        }
    }

    private func updatePlaybackHighlightOverlay() {
        guard let layout,
              let text = playbackHighlightText,
              !text.isEmpty,
              localPageIndex < layout.pageRanges.count
        else {
            playbackOverlay.clearSelection()
            return
        }

        let pageCFRange = layout.pageRanges[localPageIndex]
        let pageRange = NSRange(location: pageCFRange.location, length: pageCFRange.length)
        guard pageRange.location >= 0,
              pageRange.length > 0,
              pageRange.location + pageRange.length <= layout.attributedString.length
        else {
            playbackOverlay.clearSelection()
            return
        }

        let pageText = (layout.attributedString.string as NSString).substring(with: pageRange)
        let found = (pageText as NSString).range(of: text, options: [.caseInsensitive, .diacriticInsensitive])
        guard found.location != NSNotFound, found.length > 0 else {
            playbackOverlay.clearSelection()
            return
        }

        guard let context = makeInteractionContext() else {
            playbackOverlay.clearSelection()
            return
        }
        let chapterRange = NSRange(location: pageRange.location + found.location, length: found.length)
        let rects = selectionRects(for: chapterRange, in: context)
        playbackOverlay.selectionRects = rects
        playbackOverlay.startHandlePoint = nil
        playbackOverlay.endHandlePoint = nil
    }

    private func selectionRects(for range: NSRange, in context: InteractionContext) -> [CGRect] {
        let rects = CoreTextAnnotationRenderer.rects(
            forRange: range,
            lines: context.lines,
            lineOrigins: context.origins,
            contentOffset: CGPoint(x: context.contentPathRect.minX, y: context.contentPathRect.minY),
            layoutHeight: context.layoutSize.height,
            writingMode: context.writingMode
        )
        return rects.map { rect in
            CGRect(
                x: rect.minX * context.scaleX + bounds.minX,
                y: rect.minY * context.scaleY + bounds.minY,
                width: rect.width * context.scaleX,
                height: rect.height * context.scaleY
            )
        }
    }

    #if DEBUG
    func debugStringIndex(at point: CGPoint) -> Int? {
        guard let context = makeInteractionContext() else { return nil }
        return stringIndex(at: point, in: context)
    }

    func debugSelectionRects(for range: NSRange) -> [CGRect] {
        guard let context = makeInteractionContext() else { return [] }
        return selectionRects(for: range, in: context)
    }
    #endif

}

/// Single-page ViewController wrapping CoreTextPageView, for use with UIPageViewController.
final class CoreTextPageViewController: UIViewController {
    private let pageView = CoreTextPageView()
    private(set) var globalPageIndex: Int = 0
    private(set) var coreTextReadingPosition: CoreTextReadingPosition?
    var onInternalLinkTap: ((String) -> Void)? {
        didSet {
            if isViewLoaded {
                pageView.onInternalLinkTap = onInternalLinkTap
            }
        }
    }

    private var pendingLayout: CoreTextPaginator.ChapterLayout?
    private var pendingLocalPage: Int = 0
    private var pendingFallbackColor: UIColor = .systemBackground
    private var pendingPlaybackHighlightText: String?
    private var pendingTextAnnotations: [CoreTextTextAnnotation] = []

    func configure(
        layout: CoreTextPaginator.ChapterLayout,
        localPage: Int,
        globalPage: Int,
        readingPosition: CoreTextReadingPosition? = nil,
        fallbackBackgroundColor: UIColor = .systemBackground
    ) {
        self.globalPageIndex = globalPage
        self.coreTextReadingPosition = readingPosition
        self.pendingFallbackColor = fallbackBackgroundColor
        if isViewLoaded {
            pageView.onInternalLinkTap = onInternalLinkTap
            installImageTapHandler()
            pageView.configure(layout: layout, pageIndex: localPage, fallbackBackgroundColor: fallbackBackgroundColor)
            pageView.setTextAnnotations(pendingTextAnnotations)
            pageView.setPlaybackHighlight(text: pendingPlaybackHighlightText)
        } else {
            pendingLayout = layout
            pendingLocalPage = localPage
        }
    }

    func setPlaybackHighlight(text: String?) {
        pendingPlaybackHighlightText = text
        guard isViewLoaded else { return }
        pageView.setPlaybackHighlight(text: text)
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        pendingTextAnnotations = annotations
        guard isViewLoaded else { return }
        pageView.setTextAnnotations(annotations)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageView.frame = view.bounds
        pageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageView.onInternalLinkTap = onInternalLinkTap
        installImageTapHandler()
        view.addSubview(pageView)
        if let layout = pendingLayout {
            pageView.configure(layout: layout, pageIndex: pendingLocalPage, fallbackBackgroundColor: pendingFallbackColor)
            pageView.setTextAnnotations(pendingTextAnnotations)
            pageView.setPlaybackHighlight(text: pendingPlaybackHighlightText)
            pendingLayout = nil
        }
    }

    private func installImageTapHandler() {
        pageView.onImageAttachmentTap = { [weak self] attachment in
            self?.presentImagePreview(for: attachment)
        }
    }

    private func presentImagePreview(for attachment: CoreTextPaginator.RenderedAttachment) {
        let controller = CoreTextImagePreviewController(attachment: attachment)
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }
}

extension CoreTextPageViewController: PageIndexProviding {}

private final class CoreTextImagePreviewController: UIViewController, UIScrollViewDelegate {
    private let attachment: CoreTextPaginator.RenderedAttachment
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(attachment: CoreTextPaginator.RenderedAttachment) {
        self.attachment = attachment
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)

        imageView.image = attachment.image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = attachment.alt ?? attachment.sourceHref ?? "Image"
        scrollView.addSubview(imageView)

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 18
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImageView()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }

    private func layoutImageView() {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }
        let imageSize = attachment.image.size
        let scale = min(
            boundsSize.width / max(imageSize.width, 1),
            boundsSize.height / max(imageSize.height, 1)
        )
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize
        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = scrollView.bounds.size
        let frame = imageView.frame
        let x = max((boundsSize.width - frame.width) / 2, 0)
        let y = max((boundsSize.height - frame.height) / 2, 0)
        imageView.center = CGPoint(
            x: frame.width / 2 + x,
            y: frame.height / 2 + y
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }

        let point = recognizer.location(in: imageView)
        let zoomScale = min(scrollView.maximumZoomScale, 2.5)
        let width = scrollView.bounds.width / zoomScale
        let height = scrollView.bounds.height / zoomScale
        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        scrollView.zoom(to: rect, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
extension CoreTextPageViewController: CoreTextReadingPositionProviding {}

/// Snapshot ViewController for cross-chapter page-turn animation handoff.
/// Displays a pre-rendered UIImage; the Coordinator swaps it out for the actual CoreTextPageViewController after the animation completes.
final class SnapshotPageViewController: UIViewController {
    private let imageView = UIImageView()
    private(set) var globalPageIndex: Int
    private(set) var coreTextReadingPosition: CoreTextReadingPosition?

    init(
        image: UIImage,
        globalPage: Int,
        backgroundColor: UIColor,
        readingPosition: CoreTextReadingPosition? = nil
    ) {
        self.globalPageIndex = globalPage
        self.coreTextReadingPosition = readingPosition
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        view.backgroundColor = backgroundColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
    }
}

extension SnapshotPageViewController: PageIndexProviding {}
extension SnapshotPageViewController: CoreTextReadingPositionProviding {}

/// Back side used by curl's double-sided page animation.
final class PageBackViewController: UIViewController {
    let virtualIndex: Int
    let logicalPageIndex: Int

    private let pageBackgroundColor: UIColor
    private let textureImage: UIImage?

    init(
        virtualIndex: Int,
        logicalPageIndex: Int,
        backgroundColor: UIColor,
        textureImage: UIImage? = nil
    ) {
        self.virtualIndex = virtualIndex
        self.logicalPageIndex = logicalPageIndex
        self.pageBackgroundColor = backgroundColor
        self.textureImage = textureImage
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = backgroundColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageBackgroundColor
        view.isOpaque = true

        guard let textureImage else { return }
        let imageView = UIImageView(image: textureImage)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.alpha = 0.08
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// Placeholder ViewController shown when a chapter's layout has not yet been computed (displays chapter title + loading indicator).
final class PlaceholderPageViewController: UIViewController {
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private(set) var globalPageIndex: Int
    private(set) var coreTextReadingPosition: CoreTextReadingPosition?

    private let themeBackgroundColor: UIColor
    private let themeTextColor: UIColor

    init(
        chapterTitle: String = "",
        globalPage: Int = 0,
        readingPosition: CoreTextReadingPosition? = nil,
        themeBackgroundColor: UIColor = .systemBackground,
        themeTextColor: UIColor = .label
    ) {
        self.globalPageIndex = globalPage
        self.coreTextReadingPosition = readingPosition
        self.themeBackgroundColor = themeBackgroundColor
        self.themeTextColor = themeTextColor
        super.init(nibName: nil, bundle: nil)
        titleLabel.text = chapterTitle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = themeBackgroundColor

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = themeTextColor.withAlphaComponent(0.5)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.color = themeTextColor.withAlphaComponent(0.6)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        spinner.startAnimating()
    }
}

extension PlaceholderPageViewController: PageIndexProviding {}
extension PlaceholderPageViewController: CoreTextReadingPositionProviding {}
