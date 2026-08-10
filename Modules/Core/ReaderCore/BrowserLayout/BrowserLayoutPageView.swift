import UIKit

/// Draws one page's DisplayList directly with CoreGraphics — no intermediate
/// UIImage. Also performs link hit-testing from the fragment rects and paints
/// a selection/TTS highlight overlay.
@MainActor
final class BrowserLayoutPageView: UIView, UIGestureRecognizerDelegate {

    var displayList: DisplayList = .empty
    var backgroundColorFill: UIColor = .white
    var onLinkTap: ((String) -> Void)?
    var onImageTap: ((DisplayImageItem) -> Void)?
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
        /// BrowserFallbackReason.description when this page is a forced
        /// unsupported render (browserForced); nil for supported pages.
        let fallbackReason: String?
        /// k1 page-local rect (for window conversion in didMoveToWindow).
        let k1PageLocalRect: CGRect
        /// traceID shared with the layout stage.
        let traceID: String
        /// spine + generation for diagnostic keys.
        let spine: Int
        let generation: Int
        /// Generic geometry overlay (Phase 2C): page content rect,
        /// body border rect, first line box — all PAGE CANVAS-local.
        var pageContentRect: CGRect?
        var bodyBorderRect: CGRect?
        var firstLineBoxRect: CGRect?
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
        tapRecognizer.delegate = self
        addGestureRecognizer(tapRecognizer)
        addGestureRecognizer(longPressRecognizer)
        // Long press wins over the tap recognizer when it fires.
        tapRecognizer.require(toFail: longPressRecognizer)
    }

    /// The page's tap recognizer only RECEIVES touches that hit a link (or an
    /// active selection). Any other tap is NOT received, so this recognizer
    /// never blocks the reader's ancestor tap zones (page turn / panel toggle)
    /// — mirror CoreTextPageView.gestureRecognizer(_:shouldReceive:).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === tapRecognizer else { return true }
        let point = touch.location(in: self)
        if hasActiveSelection {
            return true  // selection handles/deselect need every tap
        }
        // Taps on links AND on images are owned by this page view (mirror
        // CoreTextPageView.shouldHandleTap, which also returns true for image
        // attachments). Anything else falls through to the reader's zones.
        return linkTarget(at: point) != nil || imageTarget(at: point) != nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }


    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        // Mirror CoreTextPageView.configureTapPriority: the READER's tap zones
        // live on UIPageViewController's view. This page's link tap must win
        // when it matches a link, and FAIL (letting the reader's tap zones
        // fire → toggle menu / page turn) when it does not. Without this, the
        // page's recognizer consumed every tap and the reading panel could not
        // be toggled.
        configureTapPriority()
    }

    private func configureTapPriority() {
        var current: UIView? = superview
        while let view = current {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer !== tapRecognizer,
                      recognizer is UITapGestureRecognizer
                else { continue }
                recognizer.require(toFail: tapRecognizer)
            }
            current = view.superview
        }
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
    /// Plus generic geometry boxes (Phase 2C):
    /// - red frame: page content rect
    /// - blue frame: body border rect
    /// - green frame: first block rect
    /// - yellow frame: first line box
    /// Left-top label: commit SHA + engine mode + this view's frame/bounds.
    private func drawDebugOverlay(in context: CGContext) {
        guard let spec = debugSpec else { return }
        // Generic geometry frames (Phase 2C): page content rect (red),
        // body border rect (blue), first line box (yellow) — all compared in
        // the SAME (page-local) space.
        func frameRect(_ r: CGRect, color: UIColor, width: CGFloat = 1.5) {
            color.setStroke()
            context.setLineWidth(width)
            context.stroke(r)
        }
        // The page-content (red) and first-line-box (yellow) frames were
        // scaffolding for the Phase 2C geometry work and are gone; they covered
        // the actual page. The body border box stays — it is the only one that
        // outlines authored content rather than the viewport.
        if let r = spec.bodyBorderRect { frameRect(r, color: .systemBlue) }
        // Label block: commit SHA, actual engine, fallback reason (UNSUPPORTED
        // FORCED for forced unsupported renders), page content rect.
        let forcedNote = spec.fallbackReason.map { " UNSUPPORTED FORCED:\($0)" } ?? ""
        let label = "[\(spec.commitSHA)] \(spec.engineMode)\(forcedNote)\n"
            + "pageContent=\(spec.pageContentRect.map { String(format: "(%.0f,%.0f,%.0f,%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? "-")\n"
            + "view.frame=\(frame) safeArea=\(safeAreaInsets)"
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
                return text.rect.rawValue
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
        if let link = linkTarget(at: point) {
            onLinkTap?(link)
            return
        }
        if let image = imageTarget(at: point) {
            onImageTap?(image)
        }
    }

    /// The image fragment whose page-local rect contains the point.
    ///
    /// CSS background paint is skipped: it is not an element, so a browser never
    /// hit-tests it. The injected background covers the whole canvas and sits
    /// FIRST in the display list, so including it made every tap on such a page
    /// "hit an image" — the reader's page-turn/menu zones never saw the tap and
    /// the real illustrations behind it could not be opened.
    func imageTarget(at point: CGPoint) -> DisplayImageItem? {
        for item in displayList.items {
            guard case .image(let image) = item, !image.isBackgroundPaint else { continue }
            if image.rect.contains(point) {
                return image
            }
        }
        return nil
    }

    /// Nearest link hit region for a tap point (within the fragment rect or a
    /// small tolerance vertically for adjacent lines).
    func linkTarget(at point: CGPoint) -> String? {
        var best: (href: String, distance: CGFloat)? = nil
        for item in displayList.items {
            guard case .text(let text) = item, let href = text.linkTarget else { continue }
            let expanded = text.rect.rawValue.insetBy(dx: -4, dy: -4)
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

    /// Full-screen zoomable preview for a tapped image fragment — reuses the
    /// legacy CoreTextImagePreviewController so there is a single image
    /// preview implementation.
    private func presentImagePreview(_ item: DisplayImageItem) {
        let attachment = CoreTextPaginator.RenderedAttachment(
            rect: item.rect.rawValue,
            image: item.image ?? UIImage(),
            opacity: 1,
            sourceHref: item.source,
            alt: item.alt,
            linkHref: item.linkTarget,
            originalSize: item.image?.size
        )
        let controller = CoreTextImagePreviewController(attachment: attachment)
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    override func loadView() {
        view = pageView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageView.backgroundColorFill
        pageView.onImageTap = { [weak self] item in
            self?.presentImagePreview(item)
        }
    }
}

/// Terminal diagnostic page VC for `browserForced` chapters the browser engine
/// cannot render (unsupported / image-only / empty / failed / timeout). A REAL
/// page owned by the browser engine — `effectiveEngine=browser`, NEVER a legacy
/// fallback, and never a placeholder that could re-ensure layout. The reader
/// treats it as one page and can turn past it into the next chapter.
@MainActor
final class BrowserForcedDiagnosticViewController: UIViewController,
    PageIndexProviding,
    CoreTextReadingPositionProviding {
    let globalPageIndex: Int
    let coreTextReadingPosition: CoreTextReadingPosition?
    private let diagnosticPage: BrowserForcedDiagnosticPage
    private let backgroundColorFill: UIColor

    init(
        globalPageIndex: Int,
        readingPosition: CoreTextReadingPosition?,
        diagnosticPage: BrowserForcedDiagnosticPage,
        backgroundColor: UIColor,
        showOverlay: Bool
    ) {
        self.globalPageIndex = globalPageIndex
        self.coreTextReadingPosition = readingPosition
        self.diagnosticPage = diagnosticPage
        self.backgroundColorFill = backgroundColor
        super.init(nibName: nil, bundle: nil)
        if showOverlay {
            let label = UILabel()
            let reason = diagnosticPage.reason.description
            let features = diagnosticPage.unsupportedFeatures.isEmpty
                ? ""
                : " / unsupported=\(diagnosticPage.unsupportedFeatures.map(\.description).joined(separator: ","))"
            label.text = "FORCED UNSUPPORTED\nreason=\(reason)\(features)\nspine=\(diagnosticPage.spineIndex)"
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .systemRed
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            label.accessibilityIdentifier = "reader_forced_diagnostic_page"
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.leadingAnchor.constraint(lessThanOrEqualTo: view.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColorFill
    }
}
