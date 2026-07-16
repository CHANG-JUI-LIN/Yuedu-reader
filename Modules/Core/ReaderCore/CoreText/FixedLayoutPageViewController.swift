import UIKit
import WebKit

struct FixedLayoutZoomMetrics {
    static func fitScale(pageSize: CGSize, availableSize: CGSize) -> CGFloat? {
        guard pageSize.width > 0, pageSize.height > 0,
              availableSize.width > 0, availableSize.height > 0 else { return nil }
        return min(
            availableSize.width / pageSize.width,
            availableSize.height / pageSize.height
        )
    }

    static func centeredInsets(pageSize: CGSize, boundsSize: CGSize, zoomScale: CGFloat) -> UIEdgeInsets {
        let scaledWidth = pageSize.width * zoomScale
        let scaledHeight = pageSize.height * zoomScale
        return UIEdgeInsets(
            top: max((boundsSize.height - scaledHeight) / 2, 0),
            left: max((boundsSize.width - scaledWidth) / 2, 0),
            bottom: max((boundsSize.height - scaledHeight) / 2, 0),
            right: max((boundsSize.width - scaledWidth) / 2, 0)
        )
    }
}

private final class FixedLayoutZoomScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            return zoomScale > minimumZoomScale + 0.01
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

@MainActor
final class FixedLayoutPageViewController: UIViewController, PageIndexProviding {
    private(set) var globalPageIndex: Int = 0

    private let scrollView: FixedLayoutZoomScrollView = {
        let sv = FixedLayoutZoomScrollView(frame: .zero)
        sv.backgroundColor = .clear
        sv.bounces = false
        sv.bouncesZoom = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 4.0
        sv.zoomScale = 1.0
        sv.contentInsetAdjustmentBehavior = .never
        return sv
    }()

    private let contentView = UIView()

    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.zoomScale = 1.0
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 1.0
        wv.isUserInteractionEnabled = true
        return wv
    }()

    private var pageSize: CGSize = .zero
    private var requestedAvailableSize: CGSize = .zero
    private var shouldResetZoomOnNextLayout = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        view.addSubview(scrollView)

        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)

        webView.backgroundColor = .clear
        contentView.addSubview(webView)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = true
        scrollView.addGestureRecognizer(doubleTap)

        updateZoomLayout(resetZoom: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        updateZoomLayout(resetZoom: shouldResetZoomOnNextLayout)
        shouldResetZoomOnNextLayout = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resetZoom(animated: false)
    }

    func configure(globalPage: Int) {
        self.globalPageIndex = globalPage
    }

    func load(
        html: String,
        baseURL: URL?,
        pageSize: CGSize,
        availableSize: CGSize
    ) {
        self.pageSize = pageSize
        self.requestedAvailableSize = availableSize
        shouldResetZoomOnNextLayout = true
        webView.loadHTMLString(html, baseURL: baseURL)
        updateZoomLayout(resetZoom: true)
    }

    private func resetZoom(animated: Bool) {
        guard scrollView.zoomScale > scrollView.minimumZoomScale else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
    }

    private func updateZoomLayout(resetZoom: Bool) {
        let availableSize = view.bounds.size.width > 0 && view.bounds.size.height > 0
            ? view.bounds.size
            : requestedAvailableSize
        guard let fitScale = FixedLayoutZoomMetrics.fitScale(
            pageSize: pageSize,
            availableSize: availableSize
        ) else { return }

        contentView.transform = .identity
        contentView.frame = CGRect(origin: .zero, size: pageSize)
        webView.frame = contentView.bounds
        scrollView.contentSize = pageSize
        scrollView.minimumZoomScale = fitScale
        scrollView.maximumZoomScale = max(fitScale * 4.0, fitScale + 0.01)

        if resetZoom || scrollView.zoomScale < fitScale {
            scrollView.setZoomScale(fitScale, animated: false)
        }

        updateCenteredInsets()
    }

    private func updateCenteredInsets() {
        scrollView.contentInset = FixedLayoutZoomMetrics.centeredInsets(
            pageSize: pageSize,
            boundsSize: scrollView.bounds.size,
            zoomScale: scrollView.zoomScale
        )
    }

    @objc private func handleDoubleTap(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended else { return }
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            resetZoom(animated: true)
            return
        }

        let targetScale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 2.5)
        guard targetScale > scrollView.minimumZoomScale else { return }
        let point = sender.location(in: contentView)
        let width = scrollView.bounds.width / targetScale
        let height = scrollView.bounds.height / targetScale
        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        scrollView.zoom(to: rect, animated: true)
    }
}

extension FixedLayoutPageViewController: UIScrollViewDelegate {
    nonisolated func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        MainActor.assumeIsolated {
            contentView
        }
    }

    nonisolated func scrollViewDidZoom(_ scrollView: UIScrollView) {
        MainActor.assumeIsolated {
            updateCenteredInsets()
        }
    }
}
