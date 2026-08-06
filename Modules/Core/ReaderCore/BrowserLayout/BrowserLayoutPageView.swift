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

    /// DEBUG geometry probe (drawn only when `BrowserLayoutFeature.showDebugOverlay`).
    /// Exposes the page-local vs window-space coordinate truth on the REAL
    /// on-screen page view — never a detached render.
    struct DebugSpec {
        let commitSHA: String
        let engineMode: String
        /// k1 expected page-local top (89.67 for the RedChamber cover).
        let k1ExpectedPageLocalTop: CGFloat
        /// k1 actual top found in the DisplayList (blue line).
        let k1DisplayListTop: CGFloat
        /// k1 page-local rect (for window conversion in didMoveToWindow).
        let k1PageLocalRect: CGRect
        /// traceID shared with the layout stage.
        let traceID: String
        /// spine + generation for diagnostic keys.
        let spine: Int
        let generation: Int
    }
    var debugSpec: DebugSpec?

    /// One-shot superview-chain dump on first draw (DEBUG overlay only).
    private var didDumpSuperviews = false

    private func dumpSuperviewChain() {
        guard let spec = debugSpec else { return }
        var chain: [String] = []
        var view: UIView? = self
        var depth = 0
        while let v = view, depth < 12 {
            let name = NSStringFromClass(type(of: v))
            let transform = v.transform
            let winRect = v.window.map { v.convert(v.bounds, to: $0) } ?? .null
            chain.append(
                "[\(depth)] \(name) frame=\(v.frame) bounds=\(v.bounds) center=\(v.center) "
                + "transform=\(transform.a),\(transform.b),\(transform.c),\(transform.d),\(transform.tx),\(transform.ty) "
                + "safeArea=\(v.safeAreaInsets) clips=\(v.clipsToBounds) toWindow=\(winRect)"
            )
            view = v.superview
            depth += 1
        }
        BrowserLayoutDeviceDiagnostic.log(
            .superviewChain(spine: spec.spine, generation: spec.generation),
            spine: spec.spine, generation: spec.generation,
            message: "superviewChain \(chain.joined(separator: " | "))"
        )
        didDumpSuperviews = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let spec = debugSpec, window != nil else { return }
        BrowserLayoutDeviceDiagnostic.log(
            .pageViewDidMoveToWindow(spine: spec.spine, generation: spec.generation),
            spine: spec.spine, generation: spec.generation,
            message: "pageViewDidMoveToWindow frame=\(frame) bounds=\(bounds) center=\(center) "
                + "transform=\(transform.a),\(transform.d) scale=\(contentScaleFactor) "
                + "safeArea=\(safeAreaInsets) hidden=\(isHidden) alpha=\(alpha) clips=\(clipsToBounds) "
                + "screenScale=\(window?.screen.scale ?? -1) "
                + "k1PageLocalRect=\(BrowserLayoutDeviceDiagnostic.rect(spec.k1PageLocalRect, space: "coordinate=pageLocal")) "
                + "k1WindowRect=\(BrowserLayoutDeviceDiagnostic.rect(convert(spec.k1PageLocalRect, to: window), space: "coordinate=window"))"
        )
        dumpSuperviewChain()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let spec = debugSpec else { return }
        BrowserLayoutDeviceDiagnostic.log(
            .pageViewLayout(spine: spec.spine, generation: spec.generation),
            spine: spec.spine, generation: spec.generation,
            message: "pageViewLayout frame=\(frame) bounds=\(bounds) center=\(center) "
                + "transform=\(transform.a),\(transform.d) scale=\(contentScaleFactor) "
                + "safeArea=\(safeAreaInsets) k1WindowRect=\(window.map { BrowserLayoutDeviceDiagnostic.rect(convert(spec.k1PageLocalRect, to: $0), space: "coordinate=window") } ?? "no-window")"
        )
    }

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
        let ctmBefore = BrowserLayoutDeviceDiagnostic.ctm(context)
        backgroundColorFill.setFill()
        context.fill(bounds)
        DisplayListDrawer.draw(displayList, in: context)
        for highlight in highlightRects {
            highlightColor.setFill()
            context.fill(highlight.intersection(bounds))
        }
        if let spec = debugSpec {
            BrowserLayoutDeviceDiagnostic.log(
                .pageViewDraw(spine: spec.spine, generation: spec.generation),
                spine: spec.spine, generation: spec.generation,
                message: "pageViewDraw dirtyRect=\(rect) frame=\(frame) bounds=\(bounds) "
                    + "center=\(center) transform=\(transform.a),\(transform.d) scale=\(contentScaleFactor) "
                    + "safeArea=\(safeAreaInsets) hidden=\(isHidden) alpha=\(alpha) clips=\(clipsToBounds) "
                    + "screenScale=\(window?.screen.scale ?? -1) "
                    + "ctmBefore=\(ctmBefore) ctmAfter=\(BrowserLayoutDeviceDiagnostic.ctm(context)) "
                    + "k1PageLocalRect=\(BrowserLayoutDeviceDiagnostic.rect(spec.k1PageLocalRect, space: "coordinate=pageLocal")) "
                    + "k1WindowRect=\(window.map { BrowserLayoutDeviceDiagnostic.rect(convert(spec.k1PageLocalRect, to: $0), space: "coordinate=window") } ?? "no-window")"
            )
            if BrowserLayoutFeature.showDebugOverlay {
                if !didDumpSuperviews { dumpSuperviewChain() }
                drawDebugOverlay(in: context)
            }
        }
    }

    /// Three reference lines in the REAL view's context:
    /// - red:   k1 expected page-local top (89.67)
    /// - blue:  k1 top found in the DisplayList (the actual draw position)
    /// - yellow: the same expected top converted to window coordinates
    /// Left-top label: commit SHA + engine mode + this view's frame/bounds.
    private func drawDebugOverlay(in context: CGContext) {
        guard let spec = debugSpec else { return }
        let lineWidth: CGFloat = 2
        func line(atY y: CGFloat, color: UIColor) {
            color.setStroke()
            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
            context.strokePath()
        }
        // Red: expected page-local top.
        line(atY: spec.k1ExpectedPageLocalTop, color: .systemRed)
        // Blue: actual DisplayList k1 top.
        line(atY: spec.k1DisplayListTop, color: .systemBlue)
        // Yellow: window-converted expected top (via convert to window then back
        // to this view's local coords — this shows host-hierarchy shifts).
        if let window {
            let windowPoint = convert(CGPoint(x: 0, y: spec.k1ExpectedPageLocalTop), to: window)
            line(atY: windowPoint.y, color: .systemYellow)
        }
        // Label block.
        let label = "[\(spec.commitSHA)] \(spec.engineMode)\n"
            + "view.frame=\(frame) bounds=\(bounds) transform=\(transform.a),\(transform.d)\n"
            + "safeArea=\(safeAreaInsets) ctxScale=\(context.ctm.a),\(context.ctm.d)\n"
            + "red(expected)=\(spec.k1ExpectedPageLocalTop) blue(displayList)=\(spec.k1DisplayListTop)"
        let font = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .backgroundColor: UIColor.white.withAlphaComponent(0.85),
        ]
        label.draw(at: CGPoint(x: 4, y: 4), withAttributes: attrs)
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
            label.accessibilityIdentifier = "reader_engine_badge"
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
