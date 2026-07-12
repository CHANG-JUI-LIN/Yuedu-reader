import CoreText
import UIKit

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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let chunk = chunk else { return }

        // Image-only chunk (cover / full-page illustration): draw attachments directly.
        if chunk.isImageOnly {
            for attachment in chunk.attachments {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
            return
        }

        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        chunk.materializeFrameIfNeeded()
        guard let frame = chunk.frame else { return }

        // Phase 1: Block decorations in UIKit coordinates (backgrounds, borders)
        CoreTextPageView.drawBlockRenderables(
            chunk.blockRenderables,
            in: ctx,
            boundsHeight: bounds.height
        )

        // Phase 2: Text — flip to CoreText coordinates for drawing
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        if chunk.writingMode.isVertical {
            CTFrameDraw(frame, ctx)
        } else {
            let suppressedRanges = chunk.blockRenderables
                .flatMap { $0.attributedText != nil ? $0.sourceRanges : [] }

            CoreTextHorizontalLineDrawer.drawLines(
                of: frame,
                contentWidth: bounds.width,
                contentMinX: 0,
                contentMinY: 0,
                isLastPage: true,
                attrStr: chunk.attributedString,
                suppressedRanges: suppressedRanges,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                in: ctx
            )
        }
        ctx.restoreGState()

        // Phase 2b: Inline text annotations (span.small notes in vertical writing)
        if chunk.writingMode.isVertical, !chunk.inlineAnnotations.isEmpty {
            CoreTextPageView.drawInlineAnnotations(chunk.inlineAnnotations)
        }

        // Phase 3: Block image attachments (UIKit coordinates)
        for item in chunk.blockRenderables {
            if let attachment = item.imageAttachment {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
        }

        // Phase 4: Inline image attachments (UIKit coordinates)
        for attachment in chunk.attachments {
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
    private var boundAxis: CoreTextScrollAxis = .vertical
    private var boundLeadingSpacing: CGFloat = 0
    private(set) var currentChunk: CoreTextChunk?
    private var annotationOverlays: [LayerKey: InteractionOverlayView] = [:]

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
            overlay.bottomAnchor.constraint(equalTo: drawView.bottomAnchor)
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
        backdropView.setNeedsDisplay()
        drawView.setNeedsDisplay()
        overlay.clearSelection()
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

    func applyPlaybackHighlight(text: String?) {
        guard let text, !text.isEmpty,
              let chunk = currentChunk,
              chunk.chapterIndex >= 0
        else {
            playbackOverlay.clearSelection()
            return
        }

        let nsString = chunk.attributedString.string as NSString
        let searchRange = NSRange(location: chunk.charRange.location,
                                  length: min(chunk.charRange.length, chunk.attributedString.length - chunk.charRange.location))
        guard searchRange.length > 0 else {
            playbackOverlay.clearSelection()
            return
        }

        let found = nsString.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
        guard found.location != NSNotFound, found.length > 0 else {
            playbackOverlay.clearSelection()
            return
        }

        let rects = renderRects(for: found)
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
    }

    private func clearAnnotationOverlays() {
        for overlay in annotationOverlays.values {
            overlay.clearSelection()
            overlay.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        drawView.chunk?.evictFrame()
        backdropView.chunk = nil
        backdropView.frame = .zero
        drawView.chunk = nil
        currentChunk = nil
        overlay.clearSelection()
        playbackOverlay.clearSelection()
        clearAnnotationOverlays()
    }
}
