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
        DisplayListDrawer.draw(document.items(in: documentRect), in: context)
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

/// Collection view cell hosting one `BrowserScrollTileView`.
final class BrowserScrollTileCell: UICollectionViewCell {

    static let reuseIdentifier = "BrowserScrollTileCell"

    let tileView = BrowserScrollTileView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.addSubview(tileView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        tileView.frame = contentView.bounds
    }

    func configure(
        document: BrowserScrollDocument,
        documentRect: CGRect,
        backgroundFill: UIColor
    ) {
        tileView.backgroundFill = backgroundFill
        tileView.document = document
        tileView.documentRect = documentRect
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Drop the chapter reference so a recycled tile cannot briefly paint the
        // previous chapter's content at the new tile's offset.
        tileView.document = .empty
        tileView.documentRect = .zero
    }
}
