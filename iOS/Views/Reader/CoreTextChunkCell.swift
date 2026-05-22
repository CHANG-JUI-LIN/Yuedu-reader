import CoreText
import UIKit

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
            for annotation in chunk.inlineAnnotations where annotation.attributedString.length > 0 {
                let sanitized = RunDelegateProvider.sanitizedInlineAnnotationString(annotation.attributedString)
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let mutable = NSMutableAttributedString(attributedString: sanitized)
                mutable.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: mutable.length))
                mutable.draw(with: annotation.uiRect, options: [.usesLineFragmentOrigin], context: nil)
            }
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

    let drawView = CoreTextChunkDrawView()
    private let playbackOverlay = InteractionOverlayView()
    let overlay = InteractionOverlayView()
    private var leadingConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private(set) var currentChunk: CoreTextChunk?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        drawView.translatesAutoresizingMaskIntoConstraints = false
        playbackOverlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        playbackOverlay.fillColor = UIColor.systemYellow.withAlphaComponent(0.28)
        playbackOverlay.showsHandles = false
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
        leadingSpacing: CGFloat
    ) {
        currentChunk = chunk
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

        drawView.setNeedsDisplay()
        overlay.clearSelection()
    }

    func applySelection(chapterIndex: Int, chapterRange: NSRange?) {
        guard let chunk = currentChunk else { overlay.clearSelection(); return }
        guard let range = chapterRange, chunk.chapterIndex == chapterIndex, range.length > 0 else {
            overlay.clearSelection()
            return
        }
        let rects = chunk.selectionRects(forChapterRange: range)
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

        let rects = chunk.selectionRects(forChapterRange: found)
        playbackOverlay.selectionRects = rects
        playbackOverlay.startHandlePoint = nil
        playbackOverlay.endHandlePoint = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        drawView.chunk?.evictFrame()
        drawView.chunk = nil
        currentChunk = nil
        overlay.clearSelection()
        playbackOverlay.clearSelection()
    }
}
