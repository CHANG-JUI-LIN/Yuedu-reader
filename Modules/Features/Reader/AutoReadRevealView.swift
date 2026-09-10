import UIKit

/// Lets `AutoReadController` move the curtain without going through SwiftUI.
///
/// The reveal advances every frame; routing that through `@Published` would
/// re-evaluate the entire reader body sixty times a second. The paged host points
/// this at its reveal view, and the controller calls straight through it.
@MainActor
final class ReaderAutoReadRevealHandle {
    var setProgress: ((Double) -> Void)?
}

/// The 自動閱讀 curtain: the next page, unmasked from the top down.
///
/// legado's `AutoPager.onDraw` in one view. Nothing translates and nothing
/// animates — the next page is drawn over the current one and a clip rectangle
/// grows from `y = 0` to `y = progress * height`, with a hairline in the reader's
/// accent colour marking the edge. When the edge reaches the bottom the reader
/// turns the page instantly, unanimated, and the curtain restarts from the top.
///
/// This is why the reader's 仿真／覆蓋／滑動 setting has no effect during auto-read:
/// legado bypasses its `PageDelegate` entirely here, and so do we.
final class AutoReadRevealView: UIView {

    private let pageImageView = UIImageView()
    private let edgeLine = UIView()
    private let revealMask = CALayer()

    /// Which page the current image is of, so the snapshot is taken once per page
    /// rather than once per frame.
    private(set) var imagePageIndex: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        pageImageView.contentMode = .scaleToFill
        pageImageView.frame = bounds
        pageImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        revealMask.backgroundColor = UIColor.black.cgColor
        revealMask.anchorPoint = .zero
        pageImageView.layer.mask = revealMask
        addSubview(pageImageView)

        edgeLine.isUserInteractionEnabled = false
        addSubview(edgeLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPageImage(_ image: UIImage?, pageIndex: Int?) {
        pageImageView.image = image
        imagePageIndex = pageIndex
        // A page with no snapshot yet must not leave the previous page's picture
        // hanging over the live one.
        isHidden = image == nil
    }

    func setEdgeColor(_ color: UIColor) {
        edgeLine.backgroundColor = color
    }

    /// - Parameter progress: 0…1 of one page.
    func setProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let revealed = (bounds.height * clamped).rounded()
        // The mask is a plain layer; without this its frame change would animate
        // over the next 0.25s and lag a frame behind the line.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: revealed)
        // legado draws one *device* pixel, not one point.
        let thickness = 1 / max(1, traitCollection.displayScale)
        edgeLine.frame = CGRect(
            x: 0,
            y: max(0, revealed - thickness),
            width: bounds.width,
            height: thickness
        )
        edgeLine.isHidden = revealed <= 0
        CATransaction.commit()
    }
}
