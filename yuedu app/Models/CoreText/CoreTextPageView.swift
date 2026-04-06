import CoreText
import UIKit

/// 單頁 CoreText 渲染視圖。
/// 使用 draw(_ rect:) 逐行繪製（支援 CJK 兩端對齊），不截圖、不快取 layer。
final class CoreTextPageView: UIView {
    private var layout: CoreTextPaginator.ChapterLayout?
    private var localPageIndex: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// 設定要渲染的章節佈局與頁碼，自動觸發重繪。
    func configure(layout: CoreTextPaginator.ChapterLayout, pageIndex: Int, fallbackBackgroundColor: UIColor = .systemBackground) {
        self.layout = layout
        self.localPageIndex = pageIndex
        backgroundColor = layout.attributedString.length > 0
            ? extractBackgroundColor(from: layout.attributedString)
            : fallbackBackgroundColor
        setNeedsDisplay()
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

    static func renderPage(
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
        let frame = CTFramesetterCreateFrame(layout.framesetter, range, path, nil)
        drawLines(
            of: frame,
            contentWidth: contentPathRect.width,
            contentMinX: contentPathRect.minX,
            contentMinY: contentPathRect.minY,
            isLastPage: pageIndex == layout.pageRanges.count - 1,
            attrStr: layout.attributedString,
            in: ctx
        )

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

        ctx.restoreGState()
    }

    static func drawAttachments(_ attachments: [CoreTextPaginator.RenderedAttachment]) {
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
    static func drawLines(
        of frame: CTFrame,
        contentWidth: CGFloat,
        contentMinX: CGFloat,
        contentMinY: CGFloat,
        isLastPage: Bool,
        attrStr: NSAttributedString,
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

            // 1. 行首避頭尾 (Hanging Punctuation)：如果行首是開括號，向左偏移讓字形對齊
            if lineStart < stringLength {
                let firstChar = nsString.character(at: lineStart)
                if let scalar = Unicode.Scalar(firstChar),
                   CJKTypographyProcessor.openingMarks.contains(scalar) {
                    let fontSize = attrStr.attribute(.font, at: lineStart, effectiveRange: nil) as? UIFont
                    let offset = (fontSize?.pointSize ?? 17) * 0.45
                    origin.x -= offset
                }
            }

            // Phase 4: HR 分隔線
            if lineRange.location < stringLength,
               attrStr.attribute(
                   HTMLAttributedStringBuilder.hrDividerAttribute,
                   at: lineRange.location, effectiveRange: nil
               ) != nil {
                ctx.saveGState()
                ctx.setStrokeColor(UIColor.separator.cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: origin.x, y: origin.y))
                ctx.addLine(to: CGPoint(x: origin.x + contentWidth, y: origin.y))
                ctx.strokePath()
                ctx.restoreGState()
                continue
            }

            ctx.textPosition = origin

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

            // 非最後一行且設定 justified：用 CTLineCreateJustifiedLine 改善 CJK 字間分配
            let lineToDraw: CTLine
            if isJustified && !isParagraphLastLine {
                // 行末避頭尾 (Hanging Punctuation)：如果行末是閉括號，微調寬度讓其視覺上對齊
                var effectiveWidth = contentWidth
                if lineEnd > 0 {
                    let lastChar = nsString.character(at: lineEnd - 1)
                    if let scalar = Unicode.Scalar(lastChar),
                       CJKTypographyProcessor.closingMarks.contains(scalar) {
                        let fontSize = attrStr.attribute(.font, at: lineEnd - 1, effectiveRange: nil) as? UIFont
                        let bonus = (fontSize?.pointSize ?? 17) * 0.4
                        effectiveWidth += bonus
                    }
                }

                // 限制 Justification 拉伸比例，避免字數過少時產生醜陋的間距（大餅臉）
                // 若文字實際寬度不足 contentWidth 的 60%，則不做 justify
                let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                if lineWidth > Double(contentWidth) * 0.6 {
                    lineToDraw = CTLineCreateJustifiedLine(line, 1.0, Double(effectiveWidth)) ?? line
                } else {
                    lineToDraw = line
                }
            } else {
                lineToDraw = line
            }

            CTLineDraw(lineToDraw, ctx)
        }
    }

    static func drawBlockRenderables(
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
            // block image 統一在 Phase 3（flip-back 後）用 UIImage.draw() 繪製
            ctx.restoreGState()
        }
    }

    // 根據 style.width 和 textAlign 計算 border 的起始 x 和寬度
    private static func borderXAndWidth(for item: CoreTextPaginator.RenderedBlockRenderable) -> (CGFloat, CGFloat) {
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

    static func drawBlockRenderableText(
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

    static func drawPageBackground(_ image: UIImage, in bounds: CGRect) {
        let drawRect = backgroundImageRect(for: image.size, in: bounds)
        image.draw(in: drawRect)
    }

    private static func backgroundImageRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
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

    private var pendingLayout: CoreTextPaginator.ChapterLayout?
    private var pendingLocalPage: Int = 0
    private var pendingFallbackColor: UIColor = .systemBackground

    func configure(
        layout: CoreTextPaginator.ChapterLayout,
        localPage: Int,
        globalPage: Int,
        fallbackBackgroundColor: UIColor = .systemBackground
    ) {
        self.globalPageIndex = globalPage
        self.pendingFallbackColor = fallbackBackgroundColor
        if isViewLoaded {
            pageView.configure(layout: layout, pageIndex: localPage, fallbackBackgroundColor: fallbackBackgroundColor)
        } else {
            pendingLayout = layout
            pendingLocalPage = localPage
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageView.frame = view.bounds
        pageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageView)
        if let layout = pendingLayout {
            pageView.configure(layout: layout, pageIndex: pendingLocalPage, fallbackBackgroundColor: pendingFallbackColor)
            pendingLayout = nil
        }
    }
}

extension CoreTextPageViewController: PageIndexProviding {}

/// 跨章節翻頁動畫接力用的快照 ViewController。
/// 顯示預先渲染好的 UIImage，動畫結束後由 Coordinator 換成真正的 CoreTextPageViewController。
final class SnapshotPageViewController: UIViewController {
    private let imageView = UIImageView()
    private(set) var globalPageIndex: Int

    init(image: UIImage, globalPage: Int, backgroundColor: UIColor) {
        self.globalPageIndex = globalPage
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
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

/// 章節尚未計算完成時的佔位 ViewController（顯示章節標題 + 載入指示器）
final class PlaceholderPageViewController: UIViewController {
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private(set) var globalPageIndex: Int

    init(chapterTitle: String = "", globalPage: Int = 0) {
        self.globalPageIndex = globalPage
        super.init(nibName: nil, bundle: nil)
        titleLabel.text = chapterTitle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
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
