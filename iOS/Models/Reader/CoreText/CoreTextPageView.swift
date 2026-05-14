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
    }

    private var layout: CoreTextPaginator.ChapterLayout?
    private var localPageIndex: Int = 0
    private let selectionManager = TextSelectionManager()
    private let playbackOverlay = InteractionOverlayView()
    private let annotationOverlay = InteractionOverlayView()
    private let interactionOverlay = InteractionOverlayView()
    private var selectedTextForCopy: String?
    private var playbackHighlightText: String?
    private var textAnnotations: [CoreTextTextAnnotation] = []
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
        annotationOverlay.frame = bounds
        annotationOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        annotationOverlay.fillColor = .clear
        annotationOverlay.showsHandles = false
        interactionOverlay.frame = bounds
        interactionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        interactionOverlay.fillColor = UIColor.systemYellow.withAlphaComponent(0.30)
        interactionOverlay.handleColor = UIColor(red: 0.63, green: 0.40, blue: 0.00, alpha: 1.0)
        addSubview(playbackOverlay)
        addSubview(annotationOverlay)
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
            ? extractBackgroundColor(from: layout.attributedString)
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
        guard selectedTextForCopy?.isEmpty == false else { return false }
        return action == #selector(copy(_:)) || action == #selector(underlineSelection(_:))
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard selectedTextForCopy?.isEmpty == false else { return nil }
        var actions = suggestedActions
        actions.append(UIAction(
            title: localized("underline"),
            image: nil,
            handler: { [weak self] _ in
                self?.underlineSelection(nil)
            }
        ))
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
        let insets = layout.contentInsets

        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: layoutSize.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        let contentPathRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: max(1, layoutSize.width - insets.left - insets.right),
            height: max(1, layoutSize.height - insets.top - insets.bottom)
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
        if layout.writingMode.isVertical {
            CTFrameDraw(frame, ctx)
        } else {
            drawLines(
                of: frame,
                contentWidth: contentPathRect.width,
                contentMinX: contentPathRect.minX,
                contentMinY: contentPathRect.minY,
                isLastPage: pageIndex == layout.pageRanges.count - 1,
                attrStr: layout.attributedString,
                suppressedRanges: suppressedRanges,
                in: ctx
            )
        }

        // Phase 3: after flip-back, draw all images using UIImage.draw()
        // UIImage.draw() requires the standard UIKit environment (origin top-left, Y downward)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -layoutSize.height)

        // 3a. Block attachments (block images without blockRenderStyle)
        Self.drawAttachments(layout.blockAttachments[pageIndex] ?? [])

        // 3b. Inline attachments (inline images)
        for attachment in layout.inlineAttachments[pageIndex] ?? [] {
            attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
        }

        // 3c. Block images (decorative images with blockRenderStyle, e.g. watermarks)
        for item in layout.blockRenderables[pageIndex] ?? [] {
            if let blockImage = item.style.blockImage,
               let image = blockImage.image {
                let availableRect = item.rect
                let contentWidth = max(1, availableRect.width - blockImage.paddingLeft - blockImage.paddingRight)
                let drawWidth = min(blockImage.drawSize.width, contentWidth)
                let drawHeight = blockImage.drawSize.height
                let imgX: CGFloat
                switch blockImage.alignment {
                case .center:
                    imgX = availableRect.minX + blockImage.paddingLeft + max(0, (contentWidth - drawWidth) / 2)
                case .right:
                    imgX = availableRect.minX + blockImage.paddingLeft + max(0, contentWidth - drawWidth)
                default:
                    imgX = availableRect.minX + blockImage.paddingLeft
                }
                let imgY = availableRect.minY + max(0, (availableRect.height - drawHeight) / 2)
                image.draw(
                    in: CGRect(x: imgX, y: imgY, width: drawWidth, height: drawHeight),
                    blendMode: .normal,
                    alpha: blockImage.opacity
                )
            }
        }

        // 3d. Explicit block text (page/card-level geometry text, independent of the main text frame)
        for item in layout.blockRenderables[pageIndex] ?? [] {
            guard let text = item.attributedText else { continue }
            drawBlockRenderableText(
                text,
                in: item.rect,
                paddingLeft: item.style.paddingLeft,
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

    /// Draws all text lines of a CTFrame line-by-line, applying CTLineCreateJustifiedLine for justified non-last lines.
    /// Shared between draw(_ rect:) and CoreTextPageEngine.generateSnapshot().
    /// The CTM must already be configured for the CoreText coordinate system (y-axis flipped upward) before calling.
    /// - Parameters:
    ///   - contentMinX: Left edge of the content area (CoreText coordinates), used for drawing HR line start points
    ///   - contentMinY: Bottom of the content area (CoreText coordinates), used for calculating last-page remaining space
    ///   - isLastPage: Whether this is the last page of the chapter; last pages do not apply vertical justification
    nonisolated static func drawLines(
        of frame: CTFrame,
        contentWidth: CGFloat,
        contentMinX: CGFloat,
        contentMinY: CGFloat,
        isLastPage: Bool,
        attrStr: NSAttributedString,
        suppressedRanges: [NSRange] = [],
        in ctx: CGContext
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let nsString = attrStr.string as NSString
        let stringLength = attrStr.length

        // Phase 5A: On non-last pages, distribute bottom remaining space evenly across paragraph gaps to fill the page top-to-bottom
        var extraSpacePerGap: CGFloat = 0
        var paragraphGapAfterLine: Set<Int> = []

        if !isLastPage && lines.count > 1 {
            for i in 0..<(lines.count - 1) {
                let r = CTLineGetStringRange(lines[i])
                let checkIdx = r.location + r.length
                if checkIdx < stringLength {
                    let ch = nsString.character(at: checkIdx)
                    if ch == 0x000A || ch == 0x2028 || ch == 0x2029 {
                        paragraphGapAfterLine.insert(i)
                    }
                }
            }
            if !paragraphGapAfterLine.isEmpty {
                var lastDescent: CGFloat = 0
                CTLineGetTypographicBounds(lines.last!, nil, &lastDescent, nil)
                let lastBaseline = origins[lines.count - 1].y
                let usedBottom = lastBaseline + lastDescent   // descent is negative
                let extraSpace = usedBottom - contentMinY
                if extraSpace > 2 {
                    extraSpacePerGap = extraSpace / CGFloat(paragraphGapAfterLine.count)
                }
            }
        }

        var accumulatedShift: CGFloat = 0

        accumulatedShift = 0
        for (lineIdx, line) in lines.enumerated() {
            // Accumulate paragraph gap compensation
            if lineIdx > 0 && paragraphGapAfterLine.contains(lineIdx - 1) {
                accumulatedShift -= extraSpacePerGap
            }

            var origin = origins[lineIdx]
            origin.x += contentMinX
            origin.y += (accumulatedShift + contentMinY)

            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length

            // Skip lines that belong to explicit block renderables (drawn by drawBlockRenderableText).
            // Without this, the same text is drawn twice: once by CTFrame and once by the explicit block.
            if !suppressedRanges.isEmpty {
                let lineNSRange = NSRange(location: lineStart, length: max(0, lineRange.length))
                if suppressedRanges.contains(where: { NSIntersectionRange($0, lineNSRange).length > 0 }) {
                    continue
                }
            }

            // Phase 4: HR divider line
            if lineRange.location < stringLength,
               let hrValue = attrStr.attribute(
                   HTMLAttributedStringBuilder.hrDividerAttribute,
                   at: lineRange.location, effectiveRange: nil
               ) {
                let hr = hrValue as? HTMLAttributedStringBuilder.HRDividerStyle
                let hrColor = hr?.color ?? UIColor.separator
                let hrLineWidth = hr?.lineWidth ?? 0.5

                // Compute available draw width respecting margins
                let leftMargin = (hr?.marginLeft ?? 0) + (hr?.inheritedBlockMarginLeft ?? 0)
                let rightMargin = hr?.marginRight ?? 0
                let availableWidth = max(1, contentWidth - leftMargin - rightMargin)

                // Rule width: explicit px, percentage of available width, or fill available
                let ruleWidth: CGFloat
                if let w = hr?.ruleWidth { ruleWidth = w }
                else if let pct = hr?.ruleWidthPercent { ruleWidth = availableWidth * pct / 100.0 }
                else { ruleWidth = availableWidth }

                // Horizontal position respecting alignment
                let alignment = hr?.alignment ?? .natural
                let isCentered = hr?.isHorizontallyCentered ?? false
                let startX: CGFloat
                if isCentered || alignment == .center {
                    startX = contentMinX + leftMargin + (availableWidth - ruleWidth) / 2
                } else if alignment == .right {
                    startX = contentMinX + leftMargin + (availableWidth - ruleWidth)
                } else {
                    startX = contentMinX + leftMargin
                }

                ctx.saveGState()
                ctx.setStrokeColor(hrColor.cgColor)
                ctx.setLineWidth(hrLineWidth)
                ctx.move(to: CGPoint(x: startX, y: origin.y))
                ctx.addLine(to: CGPoint(x: startX + ruleWidth, y: origin.y))
                ctx.strokePath()
                ctx.restoreGState()
                continue
            }

            // Determine whether this is the last line of the paragraph (last lines should not be justified to avoid forced stretching)
            let isParagraphLastLine: Bool
            if lineEnd >= stringLength {
                isParagraphLastLine = true
            } else {
                let nextCharCode = nsString.character(at: lineEnd)
                // \n (0x000A) or Unicode line separator (0x2028)
                isParagraphLastLine = nextCharCode == 0x000A || nextCharCode == 0x2028
            }

            // Get paragraph alignment
            let isJustified: Bool
            if lineRange.location < stringLength {
                let paraStyle = attrStr.attribute(
                    .paragraphStyle, at: lineRange.location, effectiveRange: nil
                ) as? NSParagraphStyle
                isJustified = paraStyle?.alignment == .justified
            } else {
                isJustified = false
            }

            origin.x = max(contentMinX, origin.x)
            let maxRightX = contentMinX + contentWidth
            let availableWidth = max(1, maxRightX - origin.x)

            // For non-last justified lines: use CTLineCreateJustifiedLine for better CJK character spacing
            let lineToDraw: CTLine
            if isJustified && !isParagraphLastLine {
                // CTFrame automatically justifies all non-last lines for .justified paragraphs,
                // causing short lines to be over-stretched. Rebuild a natural CTLine from the original
                // substring to get the true width, then decide whether to justify.
                let lineNSRange = NSRange(location: lineStart, length: max(0, lineRange.length))
                let substring = attrStr.attributedSubstring(from: lineNSRange)
                let naturalLine = CTLineCreateWithAttributedString(substring)
                let naturalWidth = CTLineGetTypographicBounds(naturalLine, nil, nil, nil)
                let coverage = naturalWidth / Double(availableWidth)

                if coverage < 0.7 {
                    // Line is too short (< 70% of available width), skip justification to avoid excessive letter spacing
                    lineToDraw = naturalLine
                } else {
                    let lineText = nsString.substring(with: lineNSRange)
                    let shouldUseCJKJustify = Self.isCJKDominant(lineText) && coverage > 0.85

                    if shouldUseCJKJustify {
                        // Pure CJK character line: use CTLineCreateJustifiedLine for precise justification
                        lineToDraw = CTLineCreateJustifiedLine(naturalLine, 1.0, Double(availableWidth)) ?? naturalLine
                    } else {
                        // English / Latin text or mixed: use natural line to avoid CTFrame's over-stretched spacing
                        lineToDraw = naturalLine
                    }
                }
            } else {
                lineToDraw = line
            }

            ctx.textPosition = origin
            CTLineDraw(lineToDraw, ctx)
        }
    }

    /// Returns true when the text is predominantly CJK (Chinese / Japanese / Korean),
    /// meaning CJK codepoints outnumber Latin letters + digits.
    private nonisolated static func isCJKDominant(_ text: String) -> Bool {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0xAC00...0xD7AF:   // Hangul Syllables
                cjk += 1
            case 0x0041...0x005A,   // A-Z
                 0x0061...0x007A,   // a-z
                 0x0030...0x0039:   // 0-9
                latin += 1
            default:
                continue
            }
        }
        return cjk > latin
    }

    nonisolated static func drawBlockRenderables(
        _ renderables: [CoreTextPaginator.RenderedBlockRenderable],
        in ctx: CGContext,
        boundsHeight: CGFloat
    ) {
        for item in renderables {
            ctx.saveGState()
            if let fillColor = item.style.backgroundFillColor {
                ctx.setFillColor(fillColor.cgColor)
                ctx.fill(item.rect)
            }
            if item.style.borderTopWidth > 0 {
                let lineW = item.style.borderTopWidth
                let y = item.rect.minY + lineW / 2
                ctx.setStrokeColor((item.style.borderTopColor ?? .label).cgColor)
                ctx.setLineWidth(lineW)
                let (bx, bw) = borderXAndWidth(for: item)
                ctx.move(to: CGPoint(x: bx, y: y))
                ctx.addLine(to: CGPoint(x: bx + bw, y: y))
                ctx.strokePath()
            }
            if item.style.borderBottomWidth > 0 {
                let lineW = item.style.borderBottomWidth
                let y = item.rect.maxY - lineW / 2
                ctx.setStrokeColor((item.style.borderBottomColor ?? .label).cgColor)
                ctx.setLineWidth(lineW)
                let (bx, bw) = borderXAndWidth(for: item)
                ctx.move(to: CGPoint(x: bx, y: y))
                ctx.addLine(to: CGPoint(x: bx + bw, y: y))
                ctx.strokePath()
            }
            if item.style.borderLeftWidth > 0 {
                let lineW = item.style.borderLeftWidth
                let x = item.rect.minX + lineW / 2
                ctx.setStrokeColor((item.style.borderLeftColor ?? .label).cgColor)
                ctx.setLineWidth(lineW)
                ctx.move(to: CGPoint(x: x, y: item.rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: item.rect.maxY))
                ctx.strokePath()
            }
            if item.style.borderRightWidth > 0 {
                let lineW = item.style.borderRightWidth
                let x = item.rect.maxX - lineW / 2
                ctx.setStrokeColor((item.style.borderRightColor ?? .label).cgColor)
                ctx.setLineWidth(lineW)
                ctx.move(to: CGPoint(x: x, y: item.rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: item.rect.maxY))
                ctx.strokePath()
            }
            // Block images are drawn uniformly in Phase 3 (after flip-back) using UIImage.draw()
            ctx.restoreGState()
        }
    }

    // Calculates the starting x and width for border rendering based on style.width and textAlign
    private nonisolated static func borderXAndWidth(for item: CoreTextPaginator.RenderedBlockRenderable) -> (CGFloat, CGFloat) {
        guard let constrainedWidth = item.style.width else {
            return (item.rect.minX, item.rect.width)
        }
        let bw = min(constrainedWidth, item.rect.width)
        let bx: CGFloat
        switch item.style.textAlign {
        case .center:
            bx = item.rect.minX + max(0, (item.rect.width - bw) / 2)
        case .right:
            bx = item.rect.minX + max(0, item.rect.width - bw)
        default:
            bx = item.rect.minX
        }
        return (bx, bw)
    }

    nonisolated static func drawBlockRenderableText(
        _ text: NSAttributedString,
        in rect: CGRect,
        paddingLeft: CGFloat,
        paddingRight: CGFloat,
        boundsHeight: CGFloat,
        context ctx: CGContext
    ) {
        let contentRect = CGRect(
            x: rect.minX + paddingLeft,
            y: rect.minY,
            width: max(1, rect.width - paddingLeft - paddingRight),
            height: rect.height
        )
        let framesetter = CTFramesetterCreateWithAttributedString(text)
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
        guard let text = selectedTextForCopy, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    @objc private func underlineSelection(_ sender: Any?) {
        guard let layout,
              let range = selectionManager.selectedRange,
              range.length > 0,
              range.location >= 0,
              range.location + range.length <= layout.attributedString.length
        else { return }
        let excerpt = selectedTextForCopy ?? selectionManager.selectedText(in: layout.attributedString) ?? ""
        let annotation = CoreTextTextAnnotation(
            id: UUID(),
            spineIndex: layout.spineIndex,
            range: range
        )
        textAnnotations.append(annotation)
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
                    excerpt: excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ]
        )
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let layout,
              localPageIndex < layout.pageRanges.count,
              let context = makeInteractionContext(),
              let index = stringIndex(at: gesture.location(in: self), in: context)
        else {
            return
        }

        if selectionManager.hasSelection {
            clearSelection()
            return
        }

        guard index < layout.attributedString.length,
              let href = layout.attributedString.attribute(
                  HTMLAttributedStringBuilder.internalLinkAttribute,
                  at: index,
                  effectiveRange: nil
              ) as? String,
              !href.isEmpty
        else {
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
            return selectionManager.hasSelection
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
            selectionManager.setSelection(range: paragraphRange, maxLength: layout.attributedString.length)
            updateSelectionOverlay(with: context)
        case .changed:
            selectionManager.updateSelection(to: index, maxLength: layout.attributedString.length)
            updateSelectionOverlay(with: context)
        case .ended:
            selectionManager.updateSelection(to: index, maxLength: layout.attributedString.length)
            updateSelectionOverlay(with: context)
            guard selectionManager.hasSelection else { return }
            selectedTextForCopy = selectionManager.selectedText(in: layout.attributedString)
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
        guard selectionManager.hasSelection,
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
                selectionManager.updateSelectionStart(to: index, maxLength: layout.attributedString.length)
            case .end:
                selectionManager.updateSelectionEnd(to: index, maxLength: layout.attributedString.length)
            }
            updateSelectionOverlay(with: context)
            selectedTextForCopy = selectionManager.selectedText(in: layout.attributedString)
        case .ended:
            selectedTextForCopy = selectionManager.selectedText(in: layout.attributedString)
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
        if selectionManager.hasSelection {
            return true
        }

        guard let layout,
              localPageIndex < layout.pageRanges.count,
              let context = makeInteractionContext(),
              let index = stringIndex(at: point, in: context),
              index < layout.attributedString.length,
              let href = layout.attributedString.attribute(
                  HTMLAttributedStringBuilder.internalLinkAttribute,
                  at: index,
                  effectiveRange: nil
              ) as? String
        else {
            return false
        }
        return !href.isEmpty
    }

    private func clearSelection() {
        selectionManager.clear()
        selectedTextForCopy = nil
        activeDragHandle = nil
        interactionOverlay.clearSelection()
        // Also dismiss the copy menu so it doesn't stick around after the highlight is dismissed
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
              !layout.writingMode.isVertical,
              bounds.width > 0,
              bounds.height > 0
        else {
            return nil
        }

        let layoutSize = CGSize(
            width: max(1, layout.renderSize.width),
            height: max(1, layout.renderSize.height)
        )
        let insets = layout.contentInsets
        let contentPathRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: max(1, layoutSize.width - insets.left - insets.right),
            height: max(1, layoutSize.height - insets.top - insets.bottom)
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
            scaleY: bounds.height / layoutSize.height
        )
    }

    private func stringIndex(at point: CGPoint, in context: InteractionContext) -> Int? {
        let canonical = CGPoint(
            x: (point.x - bounds.minX) / context.scaleX,
            y: (point.y - bounds.minY) / context.scaleY
        )
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

    private func updateSelectionOverlay(with context: InteractionContext) {
        guard let range = selectionManager.selectedRange,
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
            annotationOverlay.clearSelection()
            return
        }
        let pageCFRange = layout.pageRanges[localPageIndex]
        let pageRange = NSRange(location: pageCFRange.location, length: pageCFRange.length)
        let rects = textAnnotations
            .filter { $0.spineIndex == layout.spineIndex }
            .flatMap { annotation -> [CGRect] in
                let intersection = NSIntersectionRange(pageRange, annotation.range)
                guard intersection.length > 0 else { return [] }
                return selectionRects(for: intersection, in: context)
            }
        annotationOverlay.selectionRects = []
        annotationOverlay.underlineRects = rects
        annotationOverlay.startHandlePoint = nil
        annotationOverlay.endHandlePoint = nil
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
        var result: [CGRect] = []

        for idx in context.lines.indices {
            let line = context.lines[idx]
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.length > 0 else { continue }

            let lineNSRange = NSRange(location: lineRange.location, length: lineRange.length)
            let intersection = NSIntersectionRange(lineNSRange, range)
            guard intersection.length > 0 else { continue }

            let startOffset = CGFloat(CTLineGetOffsetForStringIndex(line, intersection.location, nil))
            let endOffset = CGFloat(
                CTLineGetOffsetForStringIndex(
                    line,
                    intersection.location + intersection.length,
                    nil
                )
            )

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

            let baselineY = context.contentPathRect.minY + context.origins[idx].y
            let lineTop = baselineY + ascent
            let lineHeight = max(1, ascent + descent)
            let canonicalRect = CGRect(
                x: context.contentPathRect.minX + context.origins[idx].x + min(startOffset, endOffset),
                y: context.layoutSize.height - lineTop,
                width: max(1, abs(endOffset - startOffset)),
                height: lineHeight
            )

            let scaled = CGRect(
                x: canonicalRect.minX * context.scaleX + bounds.minX,
                y: canonicalRect.minY * context.scaleY + bounds.minY,
                width: canonicalRect.width * context.scaleX,
                height: canonicalRect.height * context.scaleY
            )
            result.append(scaled)
        }

        return result
    }

    private func extractBackgroundColor(from attrStr: NSAttributedString) -> UIColor {
        guard attrStr.length > 0,
              let color = attrStr.attribute(
                  .backgroundColor,
                  at: 0,
                  effectiveRange: nil
              ) as? UIColor
        else { return .systemBackground }
        return color
    }
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
        view.addSubview(pageView)
        if let layout = pendingLayout {
            pageView.configure(layout: layout, pageIndex: pendingLocalPage, fallbackBackgroundColor: pendingFallbackColor)
            pageView.setTextAnnotations(pendingTextAnnotations)
            pageView.setPlaybackHighlight(text: pendingPlaybackHighlightText)
            pendingLayout = nil
        }
    }
}

extension CoreTextPageViewController: PageIndexProviding {}
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
