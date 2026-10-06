import CoreText
import UIKit
import YueduCoreText

/// Paints the publication-authored page backdrop behind a scroll chunk, including the reader's
/// horizontal/vertical text insets. Large chunks repeat the artwork at viewport-sized intervals
/// instead of stretching one page texture across several screen heights.
final class CoreTextChunkBackdropView: UIView {
    var chunk: CoreTextChunk?
    var scrollAxis: CoreTextScrollAxis = .vertical
    var viewportSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let chunk else { return }
        if let backgroundColor = chunk.pageBackgroundColor {
            backgroundColor.setFill()
            UIRectFill(bounds)
        }
        guard let backgroundImage = chunk.pageBackgroundImage else { return }
        for tile in Self.backgroundTileRects(
            in: bounds,
            viewportSize: viewportSize,
            axis: scrollAxis
        ) {
            CoreTextPageView.drawPageBackground(backgroundImage, in: tile)
        }
    }

    static func backgroundTileRects(
        in bounds: CGRect,
        viewportSize: CGSize,
        axis: CoreTextScrollAxis
    ) -> [CGRect] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        switch axis {
        case .vertical:
            let tileHeight = viewportSize.height > 0 ? viewportSize.height : bounds.height
            let tileWidth = max(bounds.width, viewportSize.width > 0 ? viewportSize.width : bounds.width)
            return stride(from: bounds.minY, to: bounds.maxY, by: tileHeight).map { y in
                CGRect(x: bounds.minX, y: y, width: tileWidth, height: tileHeight)
            }
        case .horizontalRTL:
            let tileWidth = viewportSize.width > 0 ? viewportSize.width : bounds.width
            let tileHeight = max(bounds.height, viewportSize.height > 0 ? viewportSize.height : bounds.height)
            return stride(from: bounds.minX, to: bounds.maxX, by: tileWidth).map { x in
                CGRect(x: x, y: bounds.minY, width: tileWidth, height: tileHeight)
            }
        }
    }
}

/// Draws the CTFrame directly. Handles the CoreText coordinate system inversion.
final class CoreTextChunkDrawView: UIView {
    var chunk: CoreTextChunk?
    private(set) var drawCount = 0
    var rendersContentExternally = false
    /// VoiceOver double-tap on the chapter text — mirrors the sighted centre tap
    /// that opens the reader toolbar.
    var onAccessibilityActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onAccessibilityActivate else { return false }
        onAccessibilityActivate()
        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard !rendersContentExternally, let chunk else { return }
        drawCount += 1
        Self.draw(chunk, bounds: bounds)
    }

    /// Whole-chunk and partition paint on the main thread, using the chunk's own
    /// frame and the live reader settings. Geometry stays in chunk coordinates.
    static func draw(_ chunk: CoreTextChunk, bounds: CGRect, lineIndices: IndexSet? = nil) {

        let renderTrace = lineIndices == nil ? ReaderPerfTrace.begin(
            .renderChunk,
            metadata: ReaderPerfMetadata(
                spineIndex: chunk.chapterIndex,
                characterCount: chunk.charRange.length,
                chunkCount: 1,
                writingMode: String(describing: chunk.writingMode),
                executor: Thread.isMainThread ? "main" : "background"
            )
        ) : nil
        defer { if let renderTrace { ReaderPerfTrace.end(renderTrace) } }

        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        chunk.materializeFrameIfNeeded()
        CoreTextChunkPainter.paint(CoreTextChunkPainter.Content(chunk: chunk, frame: chunk.frame),
                                   bounds: bounds, lineIndices: lineIndices,
                                   underline: .current(), in: ctx)
    }
}

/// The single chunk painter, shared by the on-screen cell and the continuous-scroll
/// raster worker. It reads only the values it is handed — never `GlobalSettings`,
/// never a chunk's mutable frame state — so it may run off the main thread.
/// `ctx` must also be the current UIKit context: image attachments draw through it.
enum CoreTextChunkPainter {
    struct Content {
        let attributedString: NSAttributedString
        let writingMode: ReaderWritingMode
        let isImageOnly: Bool
        var frame: CTFrame?
        let attachments: [CoreTextPaginator.RenderedAttachment]
        let blockRenderables: [CoreTextPaginator.RenderedBlockRenderable]
        let inlineAnnotations: [CoreTextPaginator.RenderedInlineAnnotation]
        let combinedUprightCells: [CoreTextPaginator.RenderedCombinedUpright]

        /// Snapshot a chunk's paint inputs. Main thread: `attachments`,
        /// `blockRenderables` and `inlineAnnotations` are filled in by materialization.
        init(chunk: CoreTextChunk, frame: CTFrame?) {
            attributedString = chunk.attributedString
            writingMode = chunk.writingMode
            isImageOnly = chunk.isImageOnly
            self.frame = frame
            attachments = chunk.attachments
            blockRenderables = chunk.blockRenderables
            inlineAnnotations = chunk.inlineAnnotations
            combinedUprightCells = chunk.combinedUprightCells
        }
    }

    static func paint(_ content: Content, bounds: CGRect, lineIndices: IndexSet?,
                      underline: ReaderTextUnderlineDecoration?, in ctx: CGContext) {
        // Image-only chunk (cover / full-page illustration): draw attachments directly.
        if content.isImageOnly {
            for attachment in content.attachments {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
            return
        }
        guard let frame = content.frame else { return }

        // Phase 1: Block decorations in UIKit coordinates (backgrounds, borders)
        CoreTextPageView.drawBlockRenderables(
            content.blockRenderables,
            writingMode: content.writingMode,
            in: ctx,
            boundsHeight: bounds.height
        )

        let suppressedRanges = content.blockRenderables
            .flatMap { $0.suppressesSourceText ? $0.sourceRanges : [] }

        // Phase 2: Text — flip to CoreText coordinates for drawing
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        if content.writingMode.isVertical {
            RegexHighlightDecorationRenderer.drawVertical(
                frame: frame,
                attributedString: content.attributedString,
                contentOffset: .zero,
                layoutHeight: bounds.height,
                writingMode: content.writingMode,
                suppressedRanges: suppressedRanges,
                context: ctx
            )
            CoreTextPageView.drawVerticalFrame(
                frame,
                contentOffset: .zero,
                suppressedRanges: suppressedRanges,
                in: ctx
            )
        } else {
            CoreTextHorizontalLineDrawer.drawLines(
                of: frame,
                contentWidth: bounds.width,
                contentMinX: 0,
                contentMinY: 0,
                isLastPage: true,
                attrStr: content.attributedString,
                suppressedRanges: suppressedRanges,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                lineIndices: lineIndices,
                underline: underline,
                in: ctx
            )
        }
        ctx.restoreGState()

        // Phase 2b: Inline text annotations (span.small notes in vertical writing)
        if content.writingMode.isVertical, !content.inlineAnnotations.isEmpty {
            CoreTextPageView.drawInlineAnnotations(content.inlineAnnotations)
        }
        if content.writingMode.isVertical, !content.combinedUprightCells.isEmpty {
            CoreTextPageView.drawCombinedUpright(content.combinedUprightCells, from: content.attributedString, in: ctx)
        }

        // Phase 3: Block image attachments (UIKit coordinates)
        for item in content.blockRenderables {
            if let attachment = item.imageAttachment {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
        }

        // Phase 4: Inline image attachments (UIKit coordinates)
        for attachment in content.attachments {
            attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
        }
    }
}

final class CoreTextChunkCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "CoreTextChunkCollectionCell"

    private let backdropView = CoreTextChunkBackdropView()
    let drawView = CoreTextChunkDrawView()
    private let playbackOverlay = InteractionOverlayView()
    let overlay = InteractionOverlayView()
    private var leadingConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    var rendersContentExternally = false {
        didSet {
            guard oldValue != rendersContentExternally else { return }
            drawView.rendersContentExternally = rendersContentExternally
            backdropView.isHidden = rendersContentExternally
            drawView.layer.contents = nil
            if !rendersContentExternally { drawView.setNeedsDisplay() }
        }
    }
    private var boundAxis: CoreTextScrollAxis = .vertical
    private var boundLeadingSpacing: CGFloat = 0
    private(set) var currentChunk: CoreTextChunk?
    private var annotationOverlays: [LayerKey: InteractionOverlayView] = [:]
    private let noteMarkerOverlay = NoteMarkerOverlayView()
    /// 目前這個 chunk 上的筆記圓圈（座標同 `drawView`），供捲動控制器做命中判定。
    private(set) var noteMarkers: [CoreTextAnnotationRenderer.NoteMarker] = []
    /// Opens the reader toolbar from VoiceOver — the same sink the centre tap uses.
    /// Without it a VoiceOver user cannot reach the toolbar in scroll mode: the tap
    /// recognizer never fires because VoiceOver consumes the touch.
    var onAccessibilityMenu: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        backdropView.translatesAutoresizingMaskIntoConstraints = true
        drawView.translatesAutoresizingMaskIntoConstraints = false
        playbackOverlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        playbackOverlay.fillColor = UIColor.systemYellow.withAlphaComponent(0.28)
        playbackOverlay.showsHandles = false
        overlay.fillColor = UIColor.systemYellow.withAlphaComponent(0.30)
        overlay.handleColor = UIColor(red: 0.63, green: 0.40, blue: 0.00, alpha: 1.0)
        contentView.addSubview(backdropView)
        contentView.addSubview(drawView)
        contentView.addSubview(playbackOverlay)
        contentView.addSubview(overlay)
        // 標註 overlay 是 `insertSubview(belowSubview: overlay)`，所以圓圈加在最後就會在最上層。
        noteMarkerOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(noteMarkerOverlay)

        leadingConstraint = drawView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        topConstraint = drawView.topAnchor.constraint(equalTo: contentView.topAnchor)
        widthConstraint = drawView.widthAnchor.constraint(equalToConstant: 1)
        heightConstraint = drawView.heightAnchor.constraint(equalToConstant: 1)

        NSLayoutConstraint.activate([
            leadingConstraint,
            topConstraint,
            widthConstraint,
            heightConstraint,
            playbackOverlay.leadingAnchor.constraint(equalTo: drawView.leadingAnchor),
            playbackOverlay.trailingAnchor.constraint(equalTo: drawView.trailingAnchor),
            playbackOverlay.topAnchor.constraint(equalTo: drawView.topAnchor),
            playbackOverlay.bottomAnchor.constraint(equalTo: drawView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: drawView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: drawView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: drawView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: drawView.bottomAnchor),
            noteMarkerOverlay.leadingAnchor.constraint(equalTo: drawView.leadingAnchor),
            noteMarkerOverlay.trailingAnchor.constraint(equalTo: drawView.trailingAnchor),
            noteMarkerOverlay.topAnchor.constraint(equalTo: drawView.topAnchor),
            noteMarkerOverlay.bottomAnchor.constraint(equalTo: drawView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func bind(
        chunk: CoreTextChunk,
        axis: CoreTextScrollAxis,
        horizontalInset: CGFloat,
        verticalInset: CGFloat,
        leadingSpacing: CGFloat,
        viewportSize: CGSize
    ) {
        let contentChanged = currentChunk !== chunk || axis != .vertical
        let backdropChanged = contentChanged || backdropView.viewportSize != viewportSize
        currentChunk = chunk
        boundAxis = axis
        boundLeadingSpacing = leadingSpacing
        backdropView.chunk = chunk
        backdropView.scrollAxis = axis
        backdropView.viewportSize = viewportSize
        drawView.chunk = chunk

        switch axis {
        case .vertical:
            leadingConstraint.constant = horizontalInset
            topConstraint.constant = leadingSpacing
            widthConstraint.constant = chunk.width
            heightConstraint.constant = chunk.height
        case .horizontalRTL:
            leadingConstraint.constant = leadingSpacing
            topConstraint.constant = verticalInset
            widthConstraint.constant = chunk.width
            heightConstraint.constant = chunk.height
        }

        setNeedsLayout()
        if backdropChanged { backdropView.setNeedsDisplay() }
        if contentChanged {
            drawView.setNeedsDisplay()
            overlay.clearSelection()
            refreshAccessibility(for: chunk)
        }
    }

    /// The chunk is drawn with `CTFrameDraw`, so without this it is an empty view to
    /// VoiceOver. Expose the chunk's text as one element — the collection view's own
    /// scrolling then carries VoiceOver through the chapter — and keep the toolbar
    /// reachable through a custom action.
    private func refreshAccessibility(for chunk: CoreTextChunk) {
        drawView.isAccessibilityElement = true
        drawView.accessibilityTraits = .staticText
        drawView.accessibilityLabel = Self.plainText(of: chunk)
        drawView.accessibilityHint = localized("點兩下展開閱讀工具")
        drawView.onAccessibilityActivate = { [weak self] in self?.onAccessibilityMenu?() }
        drawView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: localized("選單")) { [weak self] _ in
                guard let handler = self?.onAccessibilityMenu else { return false }
                handler()
                return true
            }
        ]
    }

    private static func plainText(of chunk: CoreTextChunk) -> String {
        let available = chunk.attributedString.length - chunk.charRange.location
        guard chunk.charRange.location >= 0, available > 0 else { return "" }
        let range = NSRange(
            location: chunk.charRange.location,
            length: min(chunk.charRange.length, available)
        )
        guard range.length > 0 else { return "" }
        return chunk.attributedString.attributedSubstring(from: range).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let chunk = currentChunk else {
            backdropView.frame = .zero
            return
        }
        switch boundAxis {
        case .vertical:
            backdropView.frame = CGRect(
                x: 0,
                y: boundLeadingSpacing,
                width: contentView.bounds.width,
                height: chunk.height
            )
        case .horizontalRTL:
            backdropView.frame = CGRect(
                x: boundLeadingSpacing,
                y: 0,
                width: chunk.width,
                height: contentView.bounds.height
            )
        }
    }

    func applySelection(chapterIndex: Int, chapterRange: NSRange?) {
        guard let chunk = currentChunk else { overlay.clearSelection(); return }
        guard let range = chapterRange, chunk.chapterIndex == chapterIndex, range.length > 0 else {
            overlay.clearSelection()
            return
        }
        let rects = renderRects(for: range)
        if rects.isEmpty { overlay.clearSelection(); return }
        overlay.selectionRects = rects

        let chunkStart = chunk.charRange.location
        let chunkEnd = chunk.charRange.location + chunk.charRange.length
        let selStart = range.location
        let selEnd = range.location + range.length - 1
        let containsStart = selStart >= chunkStart && selStart < chunkEnd
        let containsEnd = selEnd >= chunkStart && selEnd < chunkEnd
        overlay.startHandlePoint = containsStart ? rects.first.map { CGPoint(x: $0.minX, y: $0.maxY) } : nil
        overlay.endHandlePoint = containsEnd ? rects.last.map { CGPoint(x: $0.maxX, y: $0.maxY) } : nil
    }

    func applyPlaybackHighlight(_ highlight: ReaderPlaybackHighlight?) {
        let s = GlobalSettings.shared
        guard s.ttsHighlightEnabled else {
            playbackOverlay.clearSelection()
            playbackOverlay.boxStyle = nil
            playbackOverlay.boxColor = nil
            playbackOverlay.fillColor = .clear
            playbackOverlay.isHidden = true
            return
        }
        guard let highlight,
              let chunk = currentChunk,
              chunk.chapterIndex >= 0
        else {
            playbackOverlay.clearSelection()
            playbackOverlay.isHidden = false
            return
        }

        let searchRange = NSRange(location: chunk.charRange.location,
                                  length: min(chunk.charRange.length, chunk.attributedString.length - chunk.charRange.location))
        guard let found = highlight.occurrence(
            in: chunk.attributedString.string as NSString,
            searchRange: searchRange,
            chapterIndex: chunk.chapterIndex
        ) else {
            playbackOverlay.clearSelection()
            playbackOverlay.isHidden = false
            return
        }

        let rects = renderRects(for: found)
        CoreTextPageView.applyTTSPlaybackStyle(to: playbackOverlay)
        playbackOverlay.selectionRects = rects
        playbackOverlay.startHandlePoint = nil
        playbackOverlay.endHandlePoint = nil
    }

    /// Union of the current playback-highlight rects, converted into `target`'s
    /// coordinate space, or nil when this cell isn't showing the spoken line. The
    /// scroll controller uses it to keep the highlighted line on screen while listening.
    func playbackHighlightBounds(in target: UIView) -> CGRect? {
        let rects = playbackOverlay.selectionRects
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        return playbackOverlay.convert(union, to: target)
    }

    /// Helper: computes rects for a chapter-level range within this chunk using the shared renderer.
    private func renderRects(for chapterRange: NSRange) -> [CGRect] {
        guard let chunk = currentChunk else { return [] }
        chunk.materializeFrameIfNeeded()
        guard let frame = chunk.frame else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let chunkNS = NSRange(location: chunk.charRange.location, length: chunk.charRange.length)
        let inter = NSIntersectionRange(chunkNS, chapterRange)
        guard inter.length > 0 else { return [] }

        return CoreTextAnnotationRenderer.rects(
            forRange: inter,
            lines: lines,
            lineOrigins: origins,
            contentOffset: .zero,
            layoutHeight: chunk.height,
            writingMode: chunk.writingMode
        )
    }

    /// Renders text annotations (underline/highlight) onto this chunk using the shared AnnotationRenderer.
    func applyAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        guard let chunk = currentChunk, chunk.chapterIndex >= 0 else {
            clearAnnotationOverlays()
            return
        }
        chunk.materializeFrameIfNeeded()
        guard let frame = chunk.frame else {
            clearAnnotationOverlays()
            return
        }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { clearAnnotationOverlays(); return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let chunkNS = NSRange(location: chunk.charRange.location, length: chunk.charRange.length)
        let layers = CoreTextAnnotationRenderer.render(
            annotations: annotations,
            spineIndex: chunk.chapterIndex,
            pageCharRange: chunkNS,
            lines: lines,
            lineOrigins: origins,
            contentOffset: .zero,
            layoutHeight: chunk.height,
            writingMode: chunk.writingMode
        )

        // Apply layers — reuse overlay views per (style, color)
        // Insert below the selection overlay (overlay) so selection stays on top
        var activeKeys = Set<LayerKey>()
        for layer in layers {
            let key = LayerKey(style: layer.style, color: layer.color)
            activeKeys.insert(key)
            let overlayView: InteractionOverlayView
            if let existing = annotationOverlays[key] {
                overlayView = existing
            } else {
                overlayView = InteractionOverlayView()
                overlayView.translatesAutoresizingMaskIntoConstraints = false
                overlayView.showsHandles = false
                contentView.insertSubview(overlayView, belowSubview: overlay)
                NSLayoutConstraint.activate([
                    overlayView.leadingAnchor.constraint(equalTo: drawView.leadingAnchor),
                    overlayView.trailingAnchor.constraint(equalTo: drawView.trailingAnchor),
                    overlayView.topAnchor.constraint(equalTo: drawView.topAnchor),
                    overlayView.bottomAnchor.constraint(equalTo: drawView.bottomAnchor),
                ])
                annotationOverlays[key] = overlayView
            }
            overlayView.apply(layer: layer, isVertical: chunk.writingMode.isVertical)
        }

        // Hide unused overlays
        for (key, overlay) in annotationOverlays where !activeKeys.contains(key) {
            overlay.isHidden = true
            overlay.clearSelection()
        }

        noteMarkers = CoreTextAnnotationRenderer.noteMarkers(
            annotations: annotations,
            spineIndex: chunk.chapterIndex,
            pageCharRange: chunkNS,
            lines: lines,
            lineOrigins: origins,
            contentOffset: .zero,
            layoutHeight: chunk.height,
            writingMode: chunk.writingMode
        )
        noteMarkerOverlay.markers = noteMarkers
    }

    /// 命中判定：`localPoint` 是 `drawView` 座標。回傳被點到的標註 id。
    func noteMarkerAnnotationID(atLocalPoint localPoint: CGPoint) -> UUID? {
        noteMarkers.first {
            NoteMarkerGeometry.tapRect(for: $0.badgeRect).contains(localPoint)
        }?.annotationID
    }

    private func clearAnnotationOverlays() {
        for overlay in annotationOverlays.values {
            overlay.clearSelection()
            overlay.isHidden = true
        }
        noteMarkers = []
        noteMarkerOverlay.markers = []
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // The CTFrame belongs to `CoreTextScrollEngine`, not to this cell — the cell is
        // only its current tenant. Evicting it here used cell recycling as the memory
        // policy, which is exactly wrong for small scroll deltas: the same few chunks
        // cycle through the reuse pool, so every reappearance paid a synchronous CTFrame
        // rebuild plus a full CoreText redraw. Frame lifetime is now owned by the engine
        // (`trimMaterializedChunks`), keyed on distance from the visible row.
        // `setNeedsDisplay()` is deferred. Without dropping the backing stores
        // immediately, a reused cell can composite its previous chunk for one
        // frame while fast scrolling, which appears as text/image ghosting.
        drawView.layer.contents = nil
        backdropView.layer.contents = nil
        backdropView.chunk = nil
        backdropView.frame = .zero
        drawView.chunk = nil
        currentChunk = nil
        overlay.clearSelection()
        playbackOverlay.clearSelection()
        clearAnnotationOverlays()
    }
}
