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
    func configure(layout: CoreTextPaginator.ChapterLayout, pageIndex: Int) {
        self.layout = layout
        self.localPageIndex = pageIndex
        backgroundColor = layout.attributedString.length > 0
            ? extractBackgroundColor(from: layout.attributedString)
            : .systemBackground
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard
            let layout,
            localPageIndex < layout.pageRanges.count,
            let ctx = UIGraphicsGetCurrentContext()
        else { return }

        if layout.pageKinds[localPageIndex] == .image {
            if let imgRect = layout.imageRects[localPageIndex],
               let image = layout.pageImages[localPageIndex] {
                image.draw(in: imgRect)
            }
            return
        }

        let range = layout.pageRanges[localPageIndex]
        let insets = layout.contentInsets

        // 1. CoreText 座標系：左下角為原點，需翻轉
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        // 2. 建立 CTFrame，逐行繪製（支援 CJK 兩端對齊）
        let contentPathRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom)
        )
        let path = CGPath(rect: contentPathRect, transform: nil)
        let frame = CTFramesetterCreateFrame(layout.framesetter, range, path, nil)
        CoreTextPageView.drawLines(
            of: frame,
            contentWidth: contentPathRect.width,
            attrStr: layout.attributedString,
            in: ctx
        )

        // 3. 翻轉回 UIView 座標系，繪製圖片
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -bounds.height)

        if let imgRect = layout.imageRects[localPageIndex],
           let image = layout.pageImages[localPageIndex] {
            image.draw(in: imgRect)
        }
    }

    /// 逐行繪製 CTFrame 的所有文字行，對 justified 非末行套用 CTLineCreateJustifiedLine。
    /// 共用於 draw(_ rect:) 和 CoreTextPageEngine.generateSnapshot()。
    /// 呼叫前必須已在 CGContext 中設定好 CoreText 座標系（y 軸向上翻轉）。
    static func drawLines(
        of frame: CTFrame,
        contentWidth: CGFloat,
        attrStr: NSAttributedString,
        in ctx: CGContext
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let nsString = attrStr.string as NSString
        let stringLength = attrStr.length

        for (lineIdx, line) in lines.enumerated() {
            let origin = origins[lineIdx]
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y)

            let lineRange = CTLineGetStringRange(line)
            let lineEnd = lineRange.location + lineRange.length

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
            if isJustified && !isParagraphLastLine,
               let justified = CTLineCreateJustifiedLine(line, 1.0, Double(contentWidth)) {
                lineToDraw = justified
            } else {
                lineToDraw = line
            }

            CTLineDraw(lineToDraw, ctx)
        }
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

    func configure(
        layout: CoreTextPaginator.ChapterLayout,
        localPage: Int,
        globalPage: Int
    ) {
        self.globalPageIndex = globalPage
        if isViewLoaded {
            pageView.configure(layout: layout, pageIndex: localPage)
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
            pageView.configure(layout: layout, pageIndex: pendingLocalPage)
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

    init(chapterTitle: String = "") {
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
