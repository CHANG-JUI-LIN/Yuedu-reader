import UIKit
import WebKit

@MainActor
final class FixedLayoutPageViewController: UIViewController,    PageIndexProviding {
    private(set) var globalPageIndex: Int = 0

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
        wv.isUserInteractionEnabled = false
        return wv
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = .clear
        view.addSubview(webView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView.frame = view.bounds
    }

    func configure(globalPage: Int) {
        self.globalPageIndex = globalPage
    }

    func load(
        html: String,
        baseURL: URL,
        pageSize: CGSize,
        availableSize: CGSize
    ) {
        webView.loadHTMLString(html, baseURL: baseURL)
        applyScale(pageSize: pageSize, availableSize: availableSize)
    }

    private func applyScale(pageSize: CGSize, availableSize: CGSize) {
        guard pageSize.width > 0, pageSize.height > 0,
              availableSize.width > 0, availableSize.height > 0 else { return }

        let scale = min(
            availableSize.width / pageSize.width,
            availableSize.height / pageSize.height
        )
        let displaySize = CGSize(
            width: pageSize.width * scale,
            height: pageSize.height * scale
        )

        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
        webView.frame = CGRect(
            x: (availableSize.width - displaySize.width) / 2,
            y: (availableSize.height - displaySize.height) / 2,
            width: pageSize.width,
            height: pageSize.height
        )
    }
}
