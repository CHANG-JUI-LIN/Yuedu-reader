import UIKit

/// Draws one page's DisplayList directly with CoreGraphics — no intermediate
/// UIImage. Also performs link hit-testing from the fragment rects and paints
/// a selection/TTS highlight overlay.
@MainActor
final class BrowserLayoutPageView: UIView, UIGestureRecognizerDelegate {

    var displayList: DisplayList = .empty
    var backgroundColorFill: UIColor = .white
    /// Every tappable link on this page, in final page-local geometry, built by
    /// the engine from the SAME display list this view draws. The view never
    /// derives link geometry itself.
    var interactionRegions: LinkInteractionRegionSet = .empty {
        didSet { cancelLinkPress() }
    }
    var onLinkActivate: ((LinkInteractionRegion) -> Void)?
    var onImageTap: ((DisplayImageItem) -> Void)?
    var onLongPress: (() -> Void)?
    /// Pressed-link wash. Paint only — never affects layout or pagination.
    var linkPressedColor: UIColor = UIColor.label.withAlphaComponent(0.15) {
        didSet { pressedHighlightLayer.fillColor = linkPressedColor.cgColor }
    }
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
        // The press overlay spans the page; its path is already page-local.
        pressedHighlightLayer.frame = bounds
        guard let spec = debugSpec else { return }
        BrowserLayoutDeviceDiagnostic.log(
            .pageViewLayout(spine: spec.spine, generation: spec.generation),
            spine: spec.spine, generation: spec.generation,
            message: "pageViewLayout frame=\(frame) bounds=\(bounds) center=\(center) "
                + "transform=\(transform.a),\(transform.d) scale=\(contentScaleFactor) "
                + "safeArea=\(safeAreaInsets) k1WindowRect=\(window.map { BrowserLayoutDeviceDiagnostic.rect(convert(spec.k1PageLocalRect, to: $0), space: "coordinate=window") } ?? "no-window")"
        )
    }

    /// Pressed-link wash. A dedicated sublayer above the content layer so a
    /// press costs a compositing pass and never a CoreGraphics redraw of the
    /// page's text.
    private let pressedHighlightLayer = CAShapeLayer()

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
        // The tap recognizer's job for links is to CLAIM the touch, so the
        // reader's ancestor page-turn/menu zones fail (see configureTapPriority).
        // Activation itself runs from touchesEnded, which needs the touch to
        // survive recognition — with the default `true`, UIKit replaces the
        // view's touchesEnded with touchesCancelled the moment the recognizer
        // fires, and no link could ever complete its press.
        tapRecognizer.cancelsTouchesInView = false
        addGestureRecognizer(tapRecognizer)
        addGestureRecognizer(longPressRecognizer)
        // Long press wins over the tap recognizer when it fires.
        tapRecognizer.require(toFail: longPressRecognizer)
        pressedHighlightLayer.fillColor = linkPressedColor.cgColor
        pressedHighlightLayer.isHidden = true
        layer.addSublayer(pressedHighlightLayer)
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
        return interactionRegions.hitTest(point) != nil || imageTarget(at: point) != nil
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
        routeTap(at: recognizer.location(in: self))
    }

    /// What the tap recognizer decides, and the only thing it decides.
    ///
    /// Links are NOT activated here. The press lifecycle owns activation
    /// (touchesBegan → touchesEnded) because only it can tell a completed press
    /// from a finger that wandered off the link. This recognizer still has to
    /// RECOGNIZE a link tap: that is what fails the reader's ancestor page-turn
    /// recognizer, so following a link does not also turn the page.
    func routeTap(at point: CGPoint) {
        // Selection takes priority over links: a tap inside an active selection
        // deselects. Tapping outside it can still follow links.
        if isInsideActiveSelection(point) {
            onDeselect?()
            return
        }
        guard interactionRegions.hitTest(point) == nil else { return }
        if let image = imageTarget(at: point) {
            onImageTap?(image)
        }
    }

    // MARK: - Link press lifecycle (normal → pressed → activated)

    enum LinkInteractionState: Equatable {
        case normal
        case pressed
        case activated
    }

    /// Observable interaction state (`activated` is momentary — it is set for
    /// the duration of the activation callback and reverts to `normal`).
    private(set) var linkInteractionState: LinkInteractionState = .normal
    /// The region the current touch went down on, and the only region this
    /// touch is allowed to activate.
    private(set) var pressedLinkRegion: LinkInteractionRegion?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        beginLinkPress(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        updateLinkPress(at: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = touches.first else { return }
        endLinkPress(at: touch.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        cancelLinkPress()
    }

    /// Touch-down. Arms activation and paints the pressed wash when the point
    /// is on a link. A no-op during an active selection — there the tap belongs
    /// to the selection UI.
    @discardableResult
    func beginLinkPress(at point: CGPoint) -> LinkInteractionRegion? {
        cancelLinkPress()
        guard !isInsideActiveSelection(point),
              let region = interactionRegions.hitTest(point) else { return nil }
        pressedLinkRegion = region
        linkInteractionState = .pressed
        paintPressedHighlight(for: region)
        return region
    }

    /// Touch-move. Leaving the pressed link disarms activation for the rest of
    /// this touch (a finger that wandered off must not follow the link, and must
    /// not adopt whichever link it wandered onto).
    func updateLinkPress(at point: CGPoint) {
        guard let region = pressedLinkRegion else { return }
        if interactionRegions.hitTest(point)?.linkID != region.linkID {
            cancelLinkPress()
        }
    }

    /// Touch-up. Activates only when the finger lifts on the SAME link it went
    /// down on; returns the activated region (nil when nothing activated).
    @discardableResult
    func endLinkPress(at point: CGPoint) -> LinkInteractionRegion? {
        defer { cancelLinkPress() }
        guard let region = pressedLinkRegion,
              interactionRegions.hitTest(point)?.linkID == region.linkID else { return nil }
        linkInteractionState = .activated
        onLinkActivate?(region)
        return region
    }

    func cancelLinkPress() {
        pressedLinkRegion = nil
        linkInteractionState = .normal
        clearPressedHighlight()
    }

    /// True when a selection is up and the point lands on it. Such a point
    /// belongs to the selection UI (it deselects) and must never start a link
    /// press. One predicate, shared with the tap handler — the two used to
    /// carry separate copies of the same rule.
    private func isInsideActiveSelection(_ point: CGPoint) -> Bool {
        guard hasActiveSelection else { return false }
        return highlightRects.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
    }

    /// Paints every region of the pressed link — a link broken across two lines
    /// highlights both halves, the way CSS `:active` applies to the element and
    /// not to one of its boxes. Pure paint: no relayout, no repagination, and
    /// the content layer is not even redrawn (the wash is its own sublayer).
    private func paintPressedHighlight(for region: LinkInteractionRegion) {
        let path = UIBezierPath()
        for piece in interactionRegions.pieces(ofLink: region.linkID) {
            path.append(UIBezierPath(
                roundedRect: piece.pageLocalRect.insetBy(dx: -2, dy: -1),
                cornerRadius: 3
            ))
        }
        guard !path.isEmpty else { return }
        // No implicit animation: a wash that fades in over 0.25s reads as lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressedHighlightLayer.path = path.cgPath
        pressedHighlightLayer.isHidden = false
        CATransaction.commit()
    }

    private func clearPressedHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressedHighlightLayer.isHidden = true
        pressedHighlightLayer.path = nil
        CATransaction.commit()
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

    /// The href at a page-local point.
    ///
    /// Delegates to the region set — the one hit-test implementation. The old
    /// body here walked the display list for `.text` items only, which is why an
    /// `<a href>` wrapping an `<img>` (the 文墨 annotation icon) drew fine and
    /// never responded: its geometry was on an image item that link hit-testing
    /// never looked at.
    func linkTarget(at point: CGPoint) -> String? {
        interactionRegions.hitTest(point)?.href
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
        interactionRegions: LinkInteractionRegionSet = .empty,
        pressedLinkColor: UIColor? = nil,
        onLinkActivate: ((LinkInteractionRegion) -> Void)?
    ) {
        self.globalPageIndex = globalPageIndex
        self.coreTextReadingPosition = readingPosition
        self.pageView = BrowserLayoutPageView(frame: .zero)
        self.pageView.displayList = displayList
        self.pageView.backgroundColorFill = backgroundColor
        self.pageView.interactionRegions = interactionRegions
        if let pressedLinkColor {
            self.pageView.linkPressedColor = pressedLinkColor
        }
        self.pageView.onLinkActivate = onLinkActivate
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

    /// Shows a note as an arrow popover anchored to the marker that was tapped —
    /// the same `FootnotePopoverHost` the legacy paged and scroll readers use,
    /// so all three modes present a note identically. `anchor` is the tapped
    /// link region's page-local rect, which is the marker's exact geometry.
    func presentFootnote(_ text: String, anchor: CGRect) {
        FootnotePopoverHost.present(
            text: text,
            from: self,
            sourceView: pageView,
            sourceRect: anchor
        )
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
