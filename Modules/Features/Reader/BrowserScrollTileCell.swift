import YueduCoreText
import UIKit

/// Paints one window onto a `BrowserScrollDocument`.
///
/// A tile owns NO content. It has a document rect and asks the chapter's
/// document what falls inside it — that is the entire rendering model, and it is
/// why scroll mode needs no slicing: the layout is continuous and the tile is
/// just where the viewport happens to be. Recycling a tile changes its document
/// rect; nothing is re-laid-out, and no per-tile display list is kept in sync
/// with anything.
///
/// Deliberately NOT built on `CoreTextChunk`. A chunk is a legacy *layout* unit
/// (a slice of an attributed string with its own `CTFrame`, because a CTFrame
/// cannot be arbitrarily tall). Giving it an optional display list would have
/// made one type mean two incompatible things and dragged the browser engine
/// back into the shape it exists to replace. The two cell types coexist in one
/// collection view instead, so a book whose chapters fall back to legacy still
/// scrolls as one continuous list.
final class BrowserScrollTileView: UIView {

    /// The chapter document this tile draws from.
    var document: BrowserScrollDocument = .empty {
        didSet { setNeedsDisplay() }
    }
    /// The tile's window in DOCUMENT coordinates.
    var documentRect: CGRect = .zero {
        didSet {
            guard documentRect != oldValue else { return }
            setNeedsDisplay()
        }
    }
    /// Painted behind the content — the reader theme, or the publication's own
    /// page background where it has one.
    var backgroundFill: UIColor = .clear

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

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if backgroundFill != .clear {
            backgroundFill.setFill()
            context.fill(bounds)
        }
        // The window's contents, already translated into tile-local space.
        ReaderDisplayListDrawer.draw(document.items(in: documentRect), in: context)
    }

    /// The link under a tile-local point, resolved against the chapter's
    /// document-space regions. Regions are built once per chapter, so a tile
    /// never rebuilds them — it only moves the point.
    func linkRegion(
        atTileLocalPoint point: CGPoint,
        regions: LinkInteractionRegionSet
    ) -> LinkInteractionRegion? {
        regions.hitTest(CGPoint(
            x: point.x + documentRect.minX,
            y: point.y + documentRect.minY
        ))
    }
}

/// Hosts a bounded browser interaction window. Viewport scrolling paints through
/// the independent fragment host; other routes retain their existing tile painter.
/// The document remains the sole owner of chapter layout.
@MainActor
final class BrowserScrollTileCell: UICollectionViewCell {
    static let reuseIdentifier = "BrowserScrollTileCell"

    private(set) var currentTile: BrowserScrollTile?
    private(set) var interactiveView = BrowserLayoutPageView(frame: .zero)
    var onAccessibilityMenu: (() -> Void)?
    var onLinkActivate: ((LinkInteractionRegion) -> Void)?
    var onImageTap: ((DisplayImageItem) -> Void)?
    private(set) var boundRevision: UInt64 = 0
    private(set) var paintUpdateCount = 0
    private var horizontalInset: CGFloat = 0
    private var leadingSpacing: CGFloat = 0
    private var verticalInset: CGFloat = 0
    private var paintClipView: UIView?

    /// One point of sampling neighbours prevents scaled images from clamping
    /// interpolation at a backing-store edge. Only the original tile is shown.
    private var paintBleed: CGFloat { currentTile.map(Self.paintBleed) ?? 0 }

    private static func paintBleed(of tile: BrowserScrollTile) -> CGFloat {
        tile.chapter.isViewportDriven && tile.chapter.writingMode == .horizontal ? 1 : 0
    }

    /// Where the tile paints, in document space: its window, grown by the hidden
    /// `paintBleed` — and in vertical writing by the reader's top and bottom insets,
    /// which it shows. A highlight's art can stand past the end of a column (蜘蛛侠's
    /// head sits on top of the quote) and paged mode draws it in the page margin; a
    /// tile cut to its window cut the head off at the column top (2026-10-15).
    private(set) var renderingDocumentRect: CGRect = .zero

    private static func renderingRect(of tile: BrowserScrollTile, topInset: CGFloat, bottomInset: CGFloat) -> CGRect {
        let window = tile.documentRect
        guard tile.chapter.writingMode.isVertical else { return window.insetBy(dx: 0, dy: -paintBleed(of: tile)) }
        return CGRect(x: window.minX, y: window.minY - topInset,
                      width: window.width, height: window.height + topInset + bottomInset)
    }

    /// A point in the painted view, in the tile's window.
    func tileLocalPoint(fromRenderingPoint point: CGPoint) -> CGPoint {
        let window = currentTile?.documentRect ?? .zero
        return CGPoint(x: point.x + renderingDocumentRect.minX - window.minX,
                       y: point.y + renderingDocumentRect.minY - window.minY)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.clipsToBounds = true
        installInteractiveView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let tile = currentTile else { interactiveView.frame = .zero; return }
        let frame = CGRect(
            x: tile.chapter.writingMode.isVertical ? 0 : horizontalInset,
            y: tile.chapter.writingMode.isVertical ? verticalInset : leadingSpacing,
            width: tile.documentRect.width, height: tile.documentRect.height
        )
        if paintBleed > 0 {
            let clip: UIView
            if let existing = paintClipView { clip = existing }
            else {
                clip = UIView()
                clip.clipsToBounds = true
                contentView.addSubview(clip)
                paintClipView = clip
            }
            clip.isHidden = false
            clip.frame = frame
            if interactiveView.superview !== clip { clip.addSubview(interactiveView) }
            interactiveView.frame = CGRect(x: 0, y: -paintBleed, width: frame.width,
                                           height: frame.height + 2 * paintBleed)
        } else {
            paintClipView?.isHidden = true
            if interactiveView.superview !== contentView { contentView.addSubview(interactiveView) }
            // A vertical tile also covers the insets it paints; the content view clips the rest.
            interactiveView.frame = CGRect(
                x: frame.minX, y: frame.minY + renderingDocumentRect.minY - tile.documentRect.minY,
                width: frame.width, height: renderingDocumentRect.height
            )
        }
    }

    /// - Parameters:
    ///   - verticalInset: Where a vertical tile's window starts in the cell.
    ///   - bottomInset: What a vertical tile's cell holds below its window.
    func configure(tile: BrowserScrollTile, horizontalInset: CGFloat, leadingSpacing: CGFloat, verticalInset: CGFloat = 0,
                   bottomInset: CGFloat = 0, rendersContentExternally: Bool = false) {
        interactiveView.usesExternalContentSurface = rendersContentExternally
        let renderingRect = Self.renderingRect(of: tile, topInset: verticalInset, bottomInset: bottomInset)
        let isSameBinding = (currentTile.map {
            $0.chapter === tile.chapter && $0.documentRect == tile.documentRect
                && $0.charRange.location == tile.charRange.location
                && $0.charRange.length == tile.charRange.length
        } ?? false) && renderingRect == renderingDocumentRect
        if currentTile != nil, currentTile?.chapter !== tile.chapter {
            interactiveView.resetContinuousBinding()
        }
        if !isSameBinding {
            interactiveView.textInteraction?.clear()
            interactiveView.cancelLinkPress()
        }
        currentTile = tile
        renderingDocumentRect = renderingRect
        // UIView records draw commands on main; Core Animation executes the
        // viewport tile's backing-store raster off main. Trace 4 shows glyph
        // raster/PNG decode in CABackingStoreUpdate after draw(_:) has returned.
        // Keep the existing scale, clipping, content lifetime and vertical path.
        interactiveView.layer.drawsAsynchronously = tile.chapter.isViewportDriven
            && !tile.chapter.writingMode.isVertical && !rendersContentExternally
        interactiveView.continuousSpineIndex = tile.chapter.spineIndex
        interactiveView.continuousDocumentRect = renderingDocumentRect
        self.horizontalInset = horizontalInset
        self.leadingSpacing = leadingSpacing
        self.verticalInset = verticalInset
        if !isSameBinding || boundRevision != tile.chapter.layoutRevision {
            boundRevision = tile.chapter.layoutRevision
            interactiveView.continuousLayoutRevision = boundRevision
            let chapter = tile.chapter
            let displayList = chapter.document.items(in: renderingDocumentRect)
            let paintChanged = !interactiveView.displayList.hasSameContents(as: displayList)
                || interactiveView.backgroundColorFill != (chapter.usesReaderBackground ? .clear : chapter.backgroundColor)
                || interactiveView.skipAuthoredBackgroundPaint != chapter.usesReaderBackground
            // A new chapter snapshot can contain only offscreen additions.
            // Keep the existing backing store and interaction state in that case.
            if paintChanged || !isSameBinding {
                let source = chapter.document.sourceText as NSString
                let start = min(max(0, tile.charRange.location), source.length)
                let range = NSRange(location: start, length: min(max(0, tile.charRange.length), source.length - start))
                interactiveView.displayList = displayList
                interactiveView.pageSourceRange = range
                interactiveView.pageSourceText = source.substring(with: range)
                interactiveView.backgroundColorFill = chapter.usesReaderBackground ? .clear : chapter.backgroundColor
                interactiveView.skipAuthoredBackgroundPaint = chapter.usesReaderBackground
                interactiveView.interactionRegions = .build(
                    from: interactiveView.displayList, spineIndex: chapter.spineIndex,
                    anchors: chapter.document.linkAnchors
                )
                interactiveView.configureTextInteraction(
                    sourceText: chapter.document.sourceText, spineIndex: chapter.spineIndex, annotations: [],
                    paragraphRanges: chapter.paragraphRanges
                )
                interactiveView.refreshAccessibility()
                if paintChanged && !rendersContentExternally {
                    paintUpdateCount += 1
                    interactiveView.setNeedsDisplay()
                }
            }
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    func applyAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        interactiveView.textInteraction?.annotations = annotations
    }

    func applyPlaybackHighlight(_ highlight: ReaderPlaybackHighlight?) {
        guard let highlight, let tile = currentTile else {
            interactiveView.setPlaybackHighlight(sourceRange: nil)
            return
        }
        // Search chapter coordinates so a sentence crossing a tile seam still
        // highlights both visible pieces, and keep only matches this tile can draw.
        // Among those, the reader's expected offset decides — a chapter that says
        // 「嗯。」 twice otherwise always washed the first one.
        let source = tile.chapter.document.sourceText as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var best: NSRange?
        var bestDistance = Int.max
        while searchRange.length > 0 {
            let found = source.range(
                of: highlight.text,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            if NSIntersectionRange(found, interactiveView.pageSourceRange).length > 0 {
                guard let expected = highlight.expectedChapterOffset else {
                    interactiveView.setPlaybackHighlight(sourceRange: found)
                    return
                }
                let distance = abs(found.location - expected)
                if distance < bestDistance {
                    best = found
                    bestDistance = distance
                } else {
                    // Matches arrive in order, so the distance only grows from here.
                    break
                }
            }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        interactiveView.setPlaybackHighlight(sourceRange: best)
    }

    func playbackHighlightBounds(in view: UIView) -> CGRect? {
        interactiveView.playbackHighlightBounds(in: view)
    }

    /// The point is cell-local, matching collection tap routing.
    func ownsTap(at point: CGPoint) -> Bool {
        if let clip = paintClipView, !clip.isHidden,
           !clip.bounds.contains(clip.convert(point, from: self)) { return false }
        let local = interactiveView.convert(point, from: self)
        guard interactiveView.bounds.contains(local) else { return false }
        return interactiveView.textInteraction?.ownsTap(at: local) == true
            || interactiveView.interactionRegions.hitTest(local) != nil
            || interactiveView.imageTarget(at: local) != nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentTile = nil
        renderingDocumentRect = .zero
        paintClipView?.isHidden = true
        horizontalInset = 0
        leadingSpacing = 0
        verticalInset = 0
        onAccessibilityMenu = nil
        onLinkActivate = nil
        onImageTap = nil
        // Keep the surface attached: removing/recreating it re-registers all
        // ancestor gesture dependencies on every prefetched/reversed tile.
        // Clear the source/selection binding so chapter identity cannot leak.
        interactiveView.resetContinuousBinding()
    }

    private func installInteractiveView() {
        interactiveView.backgroundColor = .clear
        interactiveView.backgroundColorFill = .clear
        interactiveView.isOpaque = false
        interactiveView.clipsToBounds = true
        interactiveView.usesContinuousScrolling = true
        // Scroll bars and background artwork belong to the stationary host.
        interactiveView.pageBars = nil
        interactiveView.onAccessibilityAction = { [weak self] action in
            if action == .toggleMenu { self?.onAccessibilityMenu?() }
        }
        interactiveView.onLinkActivate = { [weak self] region in self?.onLinkActivate?(region) }
        interactiveView.onImageTap = { [weak self] image in self?.onImageTap?(image) }
        contentView.addSubview(interactiveView)
    }
}
