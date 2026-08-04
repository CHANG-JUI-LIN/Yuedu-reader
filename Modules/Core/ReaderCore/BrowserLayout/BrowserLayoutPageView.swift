import UIKit

/// Draws one page's DisplayList directly with CoreGraphics — no intermediate
/// UIImage. Also performs link hit-testing from the fragment rects and paints
/// a selection/TTS highlight overlay.
@MainActor
final class BrowserLayoutPageView: UIView {

    var displayList: DisplayList = .empty
    var backgroundColorFill: UIColor = .white
    var onLinkTap: ((String) -> Void)?
    var onLongPress: (() -> Void)?
    /// Highlight rects (selection / TTS sentence) painted above the content.
    var highlightRects: [CGRect] = []
    var highlightColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.35)
    /// When a selection is active, taps deselect instead of following links.
    var hasActiveSelection = false
    var onDeselect: (() -> Void)?

    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        return recognizer
    }()
    private lazy var longPressRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        recognizer.minimumPressDuration = 0.5
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(tapRecognizer)
        addGestureRecognizer(longPressRecognizer)
        // Long press wins over the tap recognizer when it fires.
        tapRecognizer.require(toFail: longPressRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        backgroundColorFill.setFill()
        context.fill(bounds)
        DisplayListDrawer.draw(displayList, in: context)
        for highlight in highlightRects {
            highlightColor.setFill()
            context.fill(highlight.intersection(bounds))
        }
    }

    /// The page-local rect of the character under a point (selection anchor).
    func characterRect(at point: CGPoint) -> CGRect? {
        for item in displayList.items {
            guard case .text(let text) = item else { continue }
            if text.rect.contains(point) {
                return text.rect
            }
        }
        return nil
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onLongPress?()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        // Selection takes priority over links: a tap inside an active
        // selection deselects.
        if hasActiveSelection {
            let inside = highlightRects.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
            if inside {
                onDeselect?()
                return
            }
            // Tapping outside the selection can still follow links.
        }
        guard let link = linkTarget(at: point) else { return }
        onLinkTap?(link)
    }

    /// Nearest link hit region for a tap point (within the fragment rect or a
    /// small tolerance vertically for adjacent lines).
    func linkTarget(at point: CGPoint) -> String? {
        var best: (href: String, distance: CGFloat)? = nil
        for item in displayList.items {
            guard case .text(let text) = item, let href = text.linkTarget else { continue }
            let expanded = text.rect.insetBy(dx: -4, dy: -4)
            let distance: CGFloat
            if expanded.contains(point) {
                distance = 0
            } else {
                // Distance to the expanded rect (so taps just below/above the
                // line still hit when no other link is closer).
                let dx = max(expanded.minX - point.x, 0, point.x - expanded.maxX)
                let dy = max(expanded.minY - point.y, 0, point.y - expanded.maxY)
                distance = dx * dx + dy * dy
            }
            if best == nil || distance < best!.distance {
                best = (href, distance)
            }
        }
        return best?.distance ?? 0 <= 6 * 6 ? best?.href : nil
    }
}

/// Hosts a `BrowserLayoutPageView`; tracks its position for the reader.
@MainActor
final class BrowserLayoutPageViewController: UIViewController,
    PageIndexProviding,
    CoreTextReadingPositionProviding {

    let globalPageIndex: Int
    let coreTextReadingPosition: CoreTextReadingPosition?
    let pageView: BrowserLayoutPageView

    init(
        globalPageIndex: Int,
        readingPosition: CoreTextReadingPosition?,
        displayList: DisplayList,
        backgroundColor: UIColor,
        statusText: String? = nil,
        onLinkTap: ((String) -> Void)?
    ) {
        self.globalPageIndex = globalPageIndex
        self.coreTextReadingPosition = readingPosition
        self.pageView = BrowserLayoutPageView(frame: .zero)
        self.pageView.displayList = displayList
        self.pageView.backgroundColorFill = backgroundColor
        self.pageView.onLinkTap = onLinkTap
        super.init(nibName: nil, bundle: nil)
        if let statusText, BrowserLayoutFeature.showDebugOverlay {
            let label = UILabel()
            label.text = "[\(statusText)]"
            label.font = .systemFont(ofSize: 10)
            label.textColor = .systemRed
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                label.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -6),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = pageView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageView.backgroundColorFill
    }
}
