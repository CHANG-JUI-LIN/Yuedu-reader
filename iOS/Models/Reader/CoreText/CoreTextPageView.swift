import CoreText
import UIKit

/// 單頁 CoreText 渲染視圖。
/// 使用 draw(_ rect:) 逐行繪製（支援 CJK 兩端對齊），不截圖、不快取 layer。
final class CoreTextPageView: UIView, UIGestureRecognizerDelegate {
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
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

    /// 設定要渲染的章節佈局與頁碼，自動觸發重繪。
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
            print("[draw] pageKind=image pageIndex=\(pageIndex) — skipping drawLines, drawing \(layout.blockAttachments[pageIndex]?.count ?? 0) attachments")
            for attachment in layout.blockAttachments[pageIndex] ?? [] {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
            ctx.restoreGState()
            return
        }
        print("[draw] pageKind=text pageIndex=\(pageIndex) stringLen=\(layout.attributedString.length) pages=\(layout.pageRanges.count)")

        if let backgroundImage = layout.pageBackgroundImage {
            drawPageBackground(backgroundImage, in: canonicalBounds)
        }

        // Phase 1: CG 幾何操作（背景色、邊框）— 不受座標系影響
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

        // Phase 3: flip-back 後統一用 UIImage.draw() 繪製所有圖片
        // UIImage.draw() 需要 UIKit 標準環境（左上原點，Y 向下）
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -layoutSize.height)

        // 3a. Block attachments（無 blockRenderStyle 的區塊圖片）
        Self.drawAttachments(layout.blockAttachments[pageIndex] ?? [])

        // 3b. Inline attachments（行內圖片）
        for attachment in layout.inlineAttachments[pageIndex] ?? [] {
            attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
        }

        // 3c. Block images（有 blockRenderStyle 的裝飾圖片，如浮水印）
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

        // 3d. Explicit block text（page/card 級幾何文字，不依賴主文字 frame）
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

    /// 逐行繪製 CTFrame 的所有文字行，對 justified 非末行套用 CTLineCreateJustifiedLine。
    /// 共用於 draw(_ rect:) 和 CoreTextPageEngine.generateSnapshot()。
    /// 呼叫前必須已在 CGContext 中設定好 CoreText 座標系（y 軸向上翻轉）。
    /// - Parameters:
    ///   - contentMinX: 內容區域左邊界（CoreText 座標），用於繪製 hr 線段起點
    ///   - contentMinY: 內容區域底部（CoreText 座標），用於計算末頁餘白
    ///   - isLastPage: 是否為章節最後一頁；最後一頁不做垂直均分
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

        // Phase 5A: 非末頁時把底部餘白均分到段落間距，讓頁面文字上下填滿
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
                let usedBottom = lastBaseline + lastDescent   // descent 為負值
                let extraSpace = usedBottom - contentMinY
                if extraSpace > 2 {
                    extraSpacePerGap = extraSpace / CGFloat(paragraphGapAfterLine.count)
                }
            }
        }

        var accumulatedShift: CGFloat = 0

        accumulatedShift = 0
        for (lineIdx, line) in lines.enumerated() {
            // 累積段落間距補償
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

            // Phase 4: HR 分隔線
            if lineRange.location < stringLength,
               let hrValue = attrStr.attribute(
                   HTMLAttributedStringBuilder.hrDividerAttribute,
                   at: lineRange.location, effectiveRange: nil
               ) {
                let hrStyle = hrValue as? HTMLAttributedStringBuilder.HRDividerStyle
                let hrColor = hrStyle?.color ?? UIColor.separator
                let hrWidth = hrStyle?.lineWidth ?? 0.5
                print("[HR] drawing at origin=\(origin) contentWidth=\(contentWidth) color=\(hrColor) width=\(hrWidth)")
                ctx.saveGState()
                ctx.setStrokeColor(hrColor.cgColor)
                ctx.setLineWidth(hrWidth)
                ctx.move(to: CGPoint(x: origin.x, y: origin.y))
                ctx.addLine(to: CGPoint(x: origin.x + contentWidth, y: origin.y))
                ctx.strokePath()
                ctx.restoreGState()
                continue
            }

            // 判斷是否為段落最後一行（最後一行不做 justify，避免強制撐開）
            let isParagraphLastLine: Bool
            if lineEnd >= stringLength {
                isParagraphLastLine = true
            } else {
                let nextCharCode = nsString.character(at: lineEnd)
                // \n (0x000A) 或 Unicode line separator (0x2028)
                isParagraphLastLine = nextCharCode == 0x000A || nextCharCode == 0x2028
            }

            // 取得段落對齊方式
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

            // 非最後一行且設定 justified：用 CTLineCreateJustifiedLine 改善 CJK 字間分配
            let lineToDraw: CTLine
            if isJustified && !isParagraphLastLine {
                // CTFrame 對 .justified 段落會自動 justify 所有非末行，
                // 導致很短的行被過度拉伸。用原始 substring rebuild 一條
                // natural CTLine 取得真實寬度，再決定是否 justify。
                let lineNSRange = NSRange(location: lineStart, length: max(0, lineRange.length))
                let substring = attrStr.attributedSubstring(from: lineNSRange)
                let naturalLine = CTLineCreateWithAttributedString(substring)
                let naturalWidth = CTLineGetTypographicBounds(naturalLine, nil, nil, nil)
                let coverage = naturalWidth / Double(availableWidth)

                if coverage < 0.7 {
                    // 行太短（< 70% 可用寬），不做 justify，避免字距爆炸
                    lineToDraw = naturalLine
                } else {
                    let hasExpandableWhitespace: Bool = {
                        guard lineNSRange.length > 0,
                              lineNSRange.location + lineNSRange.length <= stringLength
                        else { return false }
                        let lineText = nsString.substring(with: lineNSRange)
                        return lineText.contains(" ") || lineText.contains("\u{00A0}") || lineText.contains("\t")
                    }()

                    if !hasExpandableWhitespace && coverage > 0.85 {
                        // CJK 純漢字行：用 CTLineCreateJustifiedLine 做精確 justify
                        lineToDraw = CTLineCreateJustifiedLine(naturalLine, 1.0, Double(availableWidth)) ?? line
                    } else {
                        // 中間覆蓋率或含可擴展空白：保留 CTFrame 的 justify
                        lineToDraw = line
                    }
                }
            } else {
                lineToDraw = line
            }

            ctx.textPosition = origin
            CTLineDraw(lineToDraw, ctx)
        }
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
            // block image 統一在 Phase 3（flip-back 後）用 UIImage.draw() 繪製
            ctx.restoreGState()
        }
    }

    // 根據 style.width 和 textAlign 計算 border 的起始 x 和寬度
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
            UIMenuController.shared.menuItems = [
                UIMenuItem(title: localized("下劃線"), action: #selector(underlineSelection(_:)))
            ]
            let point = gesture.location(in: self)
            UIMenuController.shared.showMenu(from: self, rect: CGRect(x: point.x, y: point.y, width: 1, height: 1))
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
            UIMenuController.shared.menuItems = [
                UIMenuItem(title: localized("下劃線"), action: #selector(underlineSelection(_:)))
            ]
            UIMenuController.shared.showMenu(from: self, rect: CGRect(x: point.x, y: point.y, width: 1, height: 1))
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
        // 同步關掉「拷貝」menu，否則點掉反白後 menu 會繼續黏在畫面上
        if #available(iOS 13.0, *) {
            UIMenuController.shared.hideMenu()
        } else {
            UIMenuController.shared.setMenuVisible(false, animated: true)
        }
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
        let relativeX = canonical.x - lineX
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: relativeX, y: 0))
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

/// 單頁 ViewController，包裝 CoreTextPageView，供 UIPageViewController 使用。
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

/// 跨章節翻頁動畫接力用的快照 ViewController。
/// 顯示預先渲染好的 UIImage，動畫結束後由 Coordinator 換成真正的 CoreTextPageViewController。
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

/// 章節尚未計算完成時的佔位 ViewController（顯示章節標題 + 載入指示器）。
///
/// 原先右下角還有一個 `footerTimeLabel` 時鐘，但它會和閱讀器底部 footer 的時鐘
/// 重疊（使用者截圖中的「那個奇怪的時間」），所以拿掉了。
/// 如果之後想再顯示時鐘，把 footerTimeLabel 相關的建構與 constraint 搬回來即可。
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
