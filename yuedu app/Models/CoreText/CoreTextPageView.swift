import CoreText
import UIKit

/// 單頁 CoreText 渲染視圖。
/// 使用 draw(_ rect:) 直接以 CTFrameDraw 繪製，不截圖、不快取 layer。
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

        let range = layout.pageRanges[localPageIndex]

        // 1. CoreText 座標系：左下角為原點，需翻轉
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        // 2. 建立 CTFrame 並繪製文字
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(layout.framesetter, range, path, nil)
        CTFrameDraw(frame, ctx)

        // 3. 翻轉回 UIView 座標系，繪製圖片
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -bounds.height)

        if let imgRect = layout.imageRects[localPageIndex],
           let image = layout.pageImages[localPageIndex] {
            image.draw(in: imgRect)
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
