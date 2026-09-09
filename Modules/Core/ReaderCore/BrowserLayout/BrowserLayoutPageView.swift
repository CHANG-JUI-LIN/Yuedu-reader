import Accessibility
import UIKit

/// Draws one page's DisplayList directly with CoreGraphics — no intermediate
/// UIImage. Also performs link hit-testing from the fragment rects and paints
/// a selection/TTS highlight overlay.
@MainActor
final class BrowserLayoutPageView: UIView, UIGestureRecognizerDelegate, @preconcurrency AXCustomContentProvider {
    var accessibilityCustomContent: [AXCustomContent]! = []

    var readingPositionForBars: CoreTextReadingPosition?
    var pageBars: ReaderPageBars? {
        didSet {
            setNeedsDisplay()
            refreshAccessibility()
        }
    }
    var displayList: DisplayList = .empty
    var backgroundColorFill: UIColor = .white
    /// The reader's own background artwork, when the user has chosen one.
    ///
    /// This is the reading surface, not a decoration behind an opaque page:
    /// `CoreTextPageView` draws it per page and so must this view, or a book
    /// whose chapters render on the browser engine loses the background the
    /// moment it leaves a legacy chapter.
    var readerBackgroundImage: UIImage?
    /// Scroll hosts paint the reader artwork once behind their collection.
    /// Their bounded tiles must suppress the authored canvas without repainting it.
    var skipAuthoredBackgroundPaint = false
    /// Let UICollectionView own VoiceOver scrolling for continuous tiles.
    var usesContinuousScrolling = false
    /// Every tappable link on this page, in final page-local geometry, built by
    /// the engine from the SAME display list this view draws. The view never
    /// derives link geometry itself.
    var interactionRegions: LinkInteractionRegionSet = .empty {
        didSet { cancelLinkPress() }
    }
    var onLinkActivate: ((LinkInteractionRegion) -> Void)?
    var onImageTap: ((DisplayImageItem) -> Void)?
    var onLongPress: (() -> Void)?
    private(set) var textInteraction: BrowserTextInteractionController?

    func configureTextInteraction(sourceText: String, spineIndex: Int, annotations: [CoreTextTextAnnotation], paragraphRanges: [NSRange] = []) {
        guard textInteraction == nil else { textInteraction?.annotations = annotations; return }
        let interaction = BrowserTextInteractionController(page: self, sourceText: sourceText,
                                                          spineIndex: spineIndex, paragraphRanges: paragraphRanges)
        interaction.onSearch = { text in
            NotificationCenter.default.post(name: .coreTextSearchSelectionRequested, object: nil, userInfo: ["text": text])
        }
        interaction.onTranslate = { text in
            NotificationCenter.default.post(name: .coreTextTranslateSelectionRequested, object: nil, userInfo: ["text": text])
        }
        textInteraction = interaction
        interaction.annotations = annotations
        refreshAccessibility()
    }
    /// Pressed-link wash. Paint only — never affects layout or pagination.
    var linkPressedColor: UIColor = UIColor.label.withAlphaComponent(0.15) {
        didSet { pressedHighlightLayer.fillColor = linkPressedColor.cgColor }
    }
    /// Highlight rects (selection / TTS sentence) painted above the content.
    var highlightRects: [CGRect] = []
    var highlightColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.35)
    /// This page's plain text and where it starts in the chapter's offset space.
    ///
    /// The one place the view learns what it is showing in SOURCE terms. Both
    /// VoiceOver (which reads the page) and the TTS wash (which has to find the
    /// spoken sentence among the fragments) need it, and deriving it twice from
    /// the display list is how the two would end up disagreeing.
    var pageSourceText: String = ""
    var pageSourceRange: NSRange = NSRange(location: 0, length: 0)
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
        // The overlays span the page; their paths are already page-local.
        pressedHighlightLayer.frame = bounds
        playbackHighlightLayer.frame = bounds
        textInteraction?.layout()
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
    /// TTS sentence wash — same reasoning, its own layer.
    private let playbackHighlightLayer = CAShapeLayer()

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
        playbackHighlightLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.28).cgColor
        playbackHighlightLayer.isHidden = true
        layer.addSublayer(playbackHighlightLayer)
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
        return textInteraction?.ownsTap(at: point) == true || interactionRegions.hitTest(point) != nil || imageTarget(at: point) != nil
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
        if let readerBackgroundImage {
            // Aspect-fill and centred through the SAME helper the legacy page
            // and the 載入中 placeholder use, so the artwork does not shift when
            // a page turn crosses between the two engines.
            CoreTextPageView.drawPageBackground(readerBackgroundImage, in: bounds)
        }
        DisplayListDrawer.draw(
            displayList,
            in: context,
            // A reader-chosen background REPLACES the book's own page surface,
            // exactly as in the legacy page.
            skipAuthoredBackgroundPaint: skipAuthoredBackgroundPaint || readerBackgroundImage != nil
        )
        for highlight in highlightRects {
            highlightColor.setFill()
            context.fill(highlight.intersection(bounds))
        }
        pageBars?.draw(in: bounds, context: context)
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
        for item in displayList.items.reversed() {
            guard case .text(let text) = item else { continue }
            if text.rect.contains(point) {
                return text.rect.rawValue
            }
        }
        return nil
    }

    /// Maps displayed text geometry back into the chapter source coordinate
    /// space. Ruby annotations carry their base range, so hit-testing never
    /// invents a second offset space for `<rt>`.
    func sourceRange(at point: CGPoint) -> NSRange? {
        if let textInteraction { return textInteraction.sourceRange(at: point) }
        for item in displayList.items.reversed() {
            guard case .text(let text) = item, text.rect.contains(point) else { continue }
            return text.sourceRange
        }
        return nil
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            cancelLinkPress()
            textInteraction?.begin(at: recognizer.location(in: self))
            onLongPress?()
        case .ended: textInteraction?.finish()
        case .cancelled: textInteraction?.clear()
        default: break
        }
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
        if textInteraction?.tap(at: point) == true { return }
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

    // MARK: - Accessibility

    /// The browser engine draws straight into `draw(_:)`, exactly like
    /// `CoreTextPageView`, so without this a browser-rendered page is an empty
    /// `UIView` to VoiceOver: nothing to focus, and the reader's tap zones never
    /// fire because VoiceOver swallows the touch. Same contract as the legacy
    /// page — read the whole page as one element, activate → menu, accessibility
    /// scroll → page turn.
    var onAccessibilityAction: ((TouchAction) -> Void)? {
        didSet { refreshAccessibility() }
    }

    /// RTL books flip the physical page order, so a VoiceOver "scroll right"
    /// has to advance rather than go back.
    var accessibilityUsesRTLPageOrder = false {
        didSet {
            guard accessibilityUsesRTLPageOrder != oldValue else { return }
            refreshAccessibility()
        }
    }

    /// Plain text of the page currently drawn.
    var accessibilityPageText: String {
        pageSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = accessibilityPageText
        accessibilityCustomContent = [pageBars?.header, pageBars?.footer].compactMap { model in
            guard let model, !model.accessibilityValue.isEmpty else { return nil }
            return AXCustomContent(label: localized(model.bar.titleKey), value: model.accessibilityValue)
        }
        accessibilityHint = usesContinuousScrolling
            ? localized("點兩下展開閱讀工具")
            : localized("點兩下展開閱讀工具，三指左右滑動翻頁")
        accessibilityCustomActions = usesContinuousScrolling ? [
            accessibilityAction(named: localized("選單"), action: .toggleMenu),
        ] : [
            accessibilityAction(named: localized("下一頁"), action: .nextPage),
            accessibilityAction(named: localized("上一頁"), action: .prevPage),
            accessibilityAction(named: localized("選單"), action: .toggleMenu),
            accessibilityAction(named: localized("目錄"), action: .tableOfContents),
        ]
        if textInteraction != nil {
            accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: localized("選取文字")) { [weak self] _ in
                guard let self, let first = displayList.items.compactMap({ item -> CGRect? in
                    if case .text(let text) = item { return text.rect.rawValue }; return nil
                }).first else { return false }
                textInteraction?.begin(at: CGPoint(x: first.midX, y: first.midY))
                textInteraction?.finish()
                return true
            })
        }
    }

    private func accessibilityAction(
        named name: String,
        action: TouchAction
    ) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            guard let handler = self?.onAccessibilityAction else { return false }
            handler(action)
            return true
        }
    }

    override func accessibilityActivate() -> Bool {
        guard let onAccessibilityAction else { return false }
        onAccessibilityAction(.toggleMenu)
        return true
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !usesContinuousScrolling else { return false }
        guard let onAccessibilityAction else { return false }
        let action: TouchAction
        switch direction {
        case .left, .up:
            action = accessibilityUsesRTLPageOrder ? .prevPage : .nextPage
        case .right, .down:
            action = accessibilityUsesRTLPageOrder ? .nextPage : .prevPage
        default:
            return false
        }
        onAccessibilityAction(action)
        return true
    }

    // MARK: - TTS playback highlight

    private var playbackHighlightText: String?

    /// Washes the sentence TTS is speaking, matching `CoreTextPageView`.
    ///
    /// Its own `CAShapeLayer` rather than `highlightRects`: the wash changes once
    /// per spoken sentence, and repainting every glyph of the page through
    /// `draw(_:)` that often is a cost the reader can feel.
    func setPlaybackHighlight(text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != playbackHighlightText else { return }
        playbackHighlightText = trimmed
        updatePlaybackHighlight()
    }

    private func updatePlaybackHighlight() {
        guard let needle = playbackHighlightText, !needle.isEmpty,
              let range = sourceRange(ofSpokenText: needle) else {
            clearPlaybackHighlight()
            return
        }
        paintPlaybackHighlight(sourceRange: range)
    }

    /// A continuous document can supply a sentence spanning two paint tiles.
    /// Both tiles use its chapter range and paint only their own geometry.
    func setPlaybackHighlight(sourceRange: NSRange?) {
        playbackHighlightText = nil
        guard let sourceRange else { clearPlaybackHighlight(); return }
        paintPlaybackHighlight(sourceRange: sourceRange)
    }

    func playbackHighlightBounds(in view: UIView) -> CGRect? {
        guard !playbackHighlightLayer.isHidden, let path = playbackHighlightLayer.path else { return nil }
        let rect = path.boundingBoxOfPath.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return convert(rect, to: view)
    }

    private func paintPlaybackHighlight(sourceRange range: NSRange) {
        let path = UIBezierPath()
        for rect in rects(intersectingSourceRange: range) {
            path.append(UIBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3))
        }
        guard !path.isEmpty else {
            clearPlaybackHighlight()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playbackHighlightLayer.path = path.cgPath
        playbackHighlightLayer.isHidden = false
        CATransaction.commit()
    }

    private func clearPlaybackHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playbackHighlightLayer.isHidden = true
        playbackHighlightLayer.path = nil
        CATransaction.commit()
    }

    /// The spoken sentence located in CHAPTER offset space. Searching this
    /// page's own text (not the whole chapter) is what keeps a sentence that
    /// repeats later in the chapter from washing the wrong paragraph here.
    private func sourceRange(ofSpokenText needle: String) -> NSRange? {
        let page = pageSourceText as NSString
        guard page.length > 0 else { return nil }
        let found = page.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        guard found.location != NSNotFound else { return nil }
        return NSRange(
            location: pageSourceRange.location + found.location,
            length: found.length
        )
    }

    /// Page-local rects of every text fragment overlapping a chapter-space range.
    private func rects(intersectingSourceRange range: NSRange) -> [CGRect] {
        BrowserTextGeometry.rects(in: displayList, range: range)
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
        guard textInteraction?.ownsTap(at: point) != true, !isInsideActiveSelection(point),
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
    private let mediaAttachments: [Int: EPUBMediaAttachment]
    private lazy var inlineVideos = BrowserInlineVideoCoordinator(owner: self)
    private var mediaAccessibilityActions: [UIAccessibilityCustomAction] = []

    init(
        globalPageIndex: Int,
        readingPosition: CoreTextReadingPosition?,
        displayList: DisplayList,
        mediaAttachments: [Int: EPUBMediaAttachment] = [:],
        backgroundColor: UIColor,
        readerBackgroundImage: UIImage? = nil,
        pageSourceText: String = "",
        pageSourceRange: NSRange = NSRange(location: 0, length: 0),
        statusText: String? = nil,
        interactionRegions: LinkInteractionRegionSet = .empty,
        pressedLinkColor: UIColor? = nil,
        onLinkActivate: ((LinkInteractionRegion) -> Void)?
    ) {
        self.globalPageIndex = globalPageIndex
        self.mediaAttachments = mediaAttachments
        self.coreTextReadingPosition = readingPosition
        self.pageView = BrowserLayoutPageView(frame: .zero)
        self.pageView.displayList = displayList
        self.pageView.backgroundColorFill = backgroundColor
        self.pageView.readerBackgroundImage = readerBackgroundImage
        self.pageView.pageSourceText = pageSourceText
        self.pageView.pageSourceRange = pageSourceRange
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

    /// VoiceOver-originated reader commands, routed by the paged host through
    /// the same sink the tap zones use.
    var onAccessibilityAction: ((TouchAction) -> Void)? {
        didSet { pageView.onAccessibilityAction = onAccessibilityAction }
    }

    var accessibilityUsesRTLPageOrder = false {
        didSet { pageView.accessibilityUsesRTLPageOrder = accessibilityUsesRTLPageOrder }
    }

    func setPlaybackHighlight(text: String?) {
        pageView.setPlaybackHighlight(text: text)
    }

    override func loadView() {
        view = pageView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageView.backgroundColorFill
        pageView.onImageTap = { [weak self] item in
            guard let self else { return }
            if inlineVideos.start(nodeID: item.nodeID) { return }
            presentImagePreview(item)
        }
        pageView.refreshAccessibility()
        syncInlineVideos()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncInlineVideos()
        // Move VoiceOver to the page that just became visible; otherwise a page
        // turn leaves focus on the previous (offscreen) page and reads nothing.
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .screenChanged, argument: pageView)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncInlineVideos()
    }

    private func syncInlineVideos() {
        let placements = pageView.displayList.items.compactMap { item -> BrowserInlineVideoPlacement? in
            guard case .image(let image) = item, !image.isBackgroundPaint,
                  let media = mediaAttachments[image.nodeID], media.kind == .video else { return nil }
            return BrowserInlineVideoPlacement(nodeID: image.nodeID, media: media, rect: image.rect.rawValue)
        }
        inlineVideos.sync(placements)
        if pageView.accessibilityPageText.isEmpty, let first = placements.first {
            let title = first.media.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pageView.accessibilityLabel = title.isEmpty ? localized("播放") : title
        }
        let readerActions = (pageView.accessibilityCustomActions ?? []).filter { action in
            !mediaAccessibilityActions.contains { $0 === action }
        }
        mediaAccessibilityActions = placements.map { placement in
            let title = placement.media.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return UIAccessibilityCustomAction(name: title.isEmpty ? localized("播放") : localized("播放") + " " + title) { [weak self] _ in
                self?.inlineVideos.start(nodeID: placement.nodeID) ?? false
            }
        }
        pageView.accessibilityCustomActions = readerActions + mediaAccessibilityActions
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
