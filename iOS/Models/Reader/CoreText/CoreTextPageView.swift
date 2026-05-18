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
        // ── Diagnostics: log all text/image positions for problem pages ──
        logPageDiagnostics(
            layout: layout,
            pageIndex: pageIndex,
            frame: frame,
            contentPathRect: contentPathRect,
            layoutSize: layoutSize
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
                let drawRect = CGRect(
                    x: centerX - item.advance / 2,
                    y: cursorY,
                    width: item.advance,
                    height: item.advance
                )
                text.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
            }
            cursorY += item.advance
        }
    }

    private nonisolated static func verticalAnnotationAdvance(for attributedString: NSAttributedString) -> CGFloat {
        if let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            return max(1, font.pointSize)
        }
        return 1
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
    // MARK: - Page Diagnostics (page-level text/image position logging)

    /// Logs every text line, image, and block renderable position for pages
    /// matching keywords like "版權", "整理說明", etc.
    private nonisolated static func logPageDiagnostics(
        layout: CoreTextPaginator.ChapterLayout,
        pageIndex: Int,
        frame: CTFrame,
        contentPathRect: CGRect,
        layoutSize: CGSize
    ) {
        let range = layout.pageRanges[pageIndex]
        guard range.length > 0 else { return }
        let nsRange = NSRange(location: range.location, length: min(range.length, layout.attributedString.length - range.location))
        guard nsRange.length > 0 else { return }
        let pageText = (layout.attributedString.string as NSString).substring(with: nsRange)

        let keywords = ["版權", "Copyright", "BookDNA", "經典復刻", "浙版數媒", "書名頁", "曹雪芹著 脂硯齋評"]
        let matched = keywords.filter { pageText.contains($0) }
        let inlineImgs = layout.inlineAttachments[pageIndex] ?? []
        let inlineAnnotations = layout.inlineAnnotations[pageIndex] ?? []
        let oversizedAnnotations = inlineAnnotations.filter { $0.uiRect.height > contentPathRect.height }
        guard !matched.isEmpty || !inlineImgs.isEmpty || !oversizedAnnotations.isEmpty else { return }

        print("[PageDiag] ===============================================================")
        print("[PageDiag] PAGE \(pageIndex) spine=\(layout.spineIndex) matched=\(matched)")
        print("[PageDiag] writingMode=\(layout.writingMode.isVertical ? "vertical-rl" : "horizontal")")
        print("[PageDiag] renderSize=\(layout.renderSize) layoutSize=\(layoutSize)")
        print("[PageDiag] contentInsets=\(layout.contentInsets)")
        print("[PageDiag] contentPathRect=\(contentPathRect)")
        print("[PageDiag] pageRange=(\(range.location), \(range.length))")
        let preview = String(pageText.replacingOccurrences(of: "\n", with: "\\n").prefix(300))
        print("[PageDiag] pageText prefix: \"\(preview)\"")

        // ── Text lines ──
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        print("[PageDiag] --- Text Lines: \(lines.count) ---")
        for (i, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let origin = origins[i]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baselineX = contentPathRect.minX + origin.x
            let typographicCenterX = baselineX + (ascent - descent) / 2
            // CoreText rect
            let coreTextRect = CGRect(
                x: baselineX,
                y: contentPathRect.minY + origin.y - descent,
                width: max(0, lineWidth),
                height: max(0, ascent + descent)
            )
            // UIKit rect
            let uiRect = CGRect(
                x: coreTextRect.minX,
                y: layoutSize.height - coreTextRect.maxY,
                width: coreTextRect.width,
                height: coreTextRect.height
            )
            var lineText = ""
            if lineRange.location < layout.attributedString.length {
                let end = min(lineRange.location + lineRange.length, layout.attributedString.length)
                if end > lineRange.location {
                    let t = (layout.attributedString.string as NSString)
                        .substring(with: NSRange(location: lineRange.location, length: min(end - lineRange.location, 60)))
                    lineText = t.replacingOccurrences(of: "\n", with: "\\n")
                }
            }
            // Paragraph style for this line
            var psInfo = "ps=nil"
            if lineRange.location < layout.attributedString.length {
                if let ps = layout.attributedString.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle {
                    psInfo = "ps.firstLineHeadIndent=\(String(format: "%.1f", ps.firstLineHeadIndent)) headIndent=\(String(format: "%.1f", ps.headIndent)) tailIndent=\(String(format: "%.1f", ps.tailIndent)) paraSpacingBefore=\(String(format: "%.1f", ps.paragraphSpacingBefore)) paraSpacing=\(String(format: "%.1f", ps.paragraphSpacing)) lineSpacing=\(String(format: "%.1f", ps.lineSpacing)) alignment=\(ps.alignment.rawValue) minLineHeight=\(String(format: "%.1f", ps.minimumLineHeight)) maxLineHeight=\(String(format: "%.1f", ps.maximumLineHeight))"
                }
            }
            print("[PageDiag]   L[\(i)] origin=(\(String(format: "%.1f", origin.x)), \(String(format: "%.1f", origin.y))) baselineX=\(String(format: "%.1f", baselineX)) typeCenterX=\(String(format: "%.1f", typographicCenterX)) centerDelta=\(String(format: "%.1f", typographicCenterX - baselineX)) w=\(String(format: "%.1f", lineWidth)) asc=\(String(format: "%.1f", ascent)) desc=\(String(format: "%.1f", descent)) ctRect=\(String(format: "%.1f", coreTextRect.minX)),\(String(format: "%.1f", coreTextRect.minY)),\(String(format: "%.1f", coreTextRect.width)),\(String(format: "%.1f", coreTextRect.height)) uiRect=\(String(format: "%.1f", uiRect.minX)),\(String(format: "%.1f", uiRect.minY)),\(String(format: "%.1f", uiRect.width)),\(String(format: "%.1f", uiRect.height)) range=(\(lineRange.location),\(lineRange.length)) \"\(lineText)\"")
            print("[PageDiag]          \(psInfo)")
        }

        // ── Inline attachments ──
        print("[PageDiag] --- Inline Images: \(inlineImgs.count) ---")
        for (i, img) in inlineImgs.enumerated() {
            print("[PageDiag]   IMG-inline[\(i)] rect=(\(String(format: "%.1f", img.rect.minX)), \(String(format: "%.1f", img.rect.minY)), \(String(format: "%.1f", img.rect.width)), \(String(format: "%.1f", img.rect.height))) drawSize=\(img.originalSize) src=\(img.sourceHref ?? "nil") alt=\(img.alt ?? "nil")")
        }

        print("[PageDiag] --- Inline Annotations: \(inlineAnnotations.count) ---")
        for (i, annotation) in inlineAnnotations.enumerated() {
            print("[PageDiag]   ANNO-inline[\(i)] uiRect=(\(String(format: "%.1f", annotation.uiRect.minX)), \(String(format: "%.1f", annotation.uiRect.minY)), \(String(format: "%.1f", annotation.uiRect.width)), \(String(format: "%.1f", annotation.uiRect.height))) len=\(annotation.attributedString.length) text=\"\(inlineAnnotationDebugPreview(annotation.attributedString.string, limit: 100))\"")
        }

        // ── Block attachments ──
        let blockImgs = layout.blockAttachments[pageIndex] ?? []
        print("[PageDiag] --- Block Images: \(blockImgs.count) ---")
        for (i, img) in blockImgs.enumerated() {
            print("[PageDiag]   IMG-block[\(i)] rect=(\(String(format: "%.1f", img.rect.minX)), \(String(format: "%.1f", img.rect.minY)), \(String(format: "%.1f", img.rect.width)), \(String(format: "%.1f", img.rect.height))) drawSize=\(img.originalSize) src=\(img.sourceHref ?? "nil")")
        }

        // ── Block renderables ──
        let renderables = layout.blockRenderables[pageIndex] ?? []
        print("[PageDiag] --- Block Renderables: \(renderables.count) ---")
        for (i, br) in renderables.enumerated() {
            let imgInfo: String
            if let img = br.imageAttachment {
                imgInfo = "img=(\(String(format: "%.1f", img.rect.minX)),\(String(format: "%.1f", img.rect.minY)),\(String(format: "%.1f", img.rect.width)),\(String(format: "%.1f", img.rect.height))) src=\(img.sourceHref ?? "nil")"
            } else {
                imgInfo = "no-image"
            }
            let textInfo = br.attributedText != nil ? "hasText len=\(br.attributedText!.length)" : "no-text"
            let styleInfo = "bg=\(br.style.backgroundFillColor != nil ? "Y" : "N") borderTop=\(br.style.borderTopWidth) borderBot=\(br.style.borderBottomWidth) w=\(br.style.width?.description ?? "nil")"
            print("[PageDiag]   BLOCK[\(i)] rect=(\(String(format: "%.1f", br.rect.minX)), \(String(format: "%.1f", br.rect.minY)), \(String(format: "%.1f", br.rect.width)), \(String(format: "%.1f", br.rect.height))) \(imgInfo) \(textInfo) \(styleInfo)")
        }

        print("[PageDiag] ===============================================================")
    }

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
              localPageIndex < layout.pageRanges.count
        else {
            return
        }

        if selectionManager.hasSelection {
            clearSelection()
            return
        }

        let point = gesture.location(in: self)
        if let attachment = imageAttachment(at: point) {
            onImageAttachmentTap?(attachment)
            return
        }

        guard let context = makeInteractionContext(),
              let index = stringIndex(at: point, in: context)
        else {
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

        if imageAttachment(at: point) != nil {
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

    /// Text selection / tap / long-press are supported only in horizontal mode.
    /// Vertical mode returns nil — CoreText's CTFrameDraw does not expose
    /// per-line origins needed for hit-testing in vertical layout.
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
