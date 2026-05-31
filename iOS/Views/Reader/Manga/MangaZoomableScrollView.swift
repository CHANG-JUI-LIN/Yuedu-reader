import UIKit

// MARK: - Zoomable scroll view
//
// Ported from Aidoku's ZoomableScrollView (which itself derives from Apple's
// PhotoScroller sample). Centers a single `zoomView`, supports pinch + double-tap
// zoom. Used by the paged manga reader (one per page).

final class MangaZoomableScrollView: UIScrollView, UIScrollViewDelegate {

    var zoomView: UIView? {
        didSet { configureZoomView(replacing: oldValue) }
    }

    var zoomEnabled = true {
        didSet {
            isScrollEnabled = zoomEnabled
            zoomingTap.isEnabled = zoomEnabled
        }
    }

    private lazy var zoomingTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        return tap
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        maximumZoomScale = 5
        minimumZoomScale = 1
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        insetsLayoutMarginsFromSafeArea = false
        contentInsetAdjustmentBehavior = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        centerView()
    }

    private func configureZoomView(replacing oldView: UIView?) {
        if oldView !== zoomView {
            if zoomingTap.view === oldView {
                oldView?.removeGestureRecognizer(zoomingTap)
            }
            if oldView?.superview === self {
                oldView?.removeFromSuperview()
            }
        }

        guard let zoomView else { return }

        if zoomView.superview !== self {
            addSubview(zoomView)
        }
        if zoomingTap.view !== zoomView {
            zoomingTap.view?.removeGestureRecognizer(zoomingTap)
            zoomView.addGestureRecognizer(zoomingTap)
        }
        zoomView.isUserInteractionEnabled = true
    }

    func resetZoom() {
        setZoomScale(minimumZoomScale, animated: false)
    }

    func centerView() {
        let boundsSize = bounds.size
        var frameToCenter = zoomView?.frame ?? .zero

        frameToCenter.origin.x = frameToCenter.size.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.size.width) / 2 : 0
        frameToCenter.origin.y = frameToCenter.size.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.size.height) / 2 : 0

        zoomView?.frame = frameToCenter
    }

    @objc private func handleDoubleTap(_ sender: UITapGestureRecognizer) {
        guard zoomEnabled else { return }
        zoom(to: sender.location(in: sender.view), animated: true)
    }

    private func zoom(to point: CGPoint, animated: Bool) {
        let finalScale: CGFloat = (zoomScale == minimumZoomScale) ? 2 : minimumZoomScale
        var rect = CGRect.zero
        rect.size.width = bounds.size.width / finalScale
        rect.size.height = bounds.size.height / finalScale
        rect.origin.x = point.x - rect.size.width / 2
        rect.origin.y = point.y - rect.size.height / 2
        zoom(to: rect, animated: animated)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomEnabled ? zoomView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerView()
    }
}
