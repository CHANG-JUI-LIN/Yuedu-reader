import UIKit
import WebKit

@MainActor
protocol EPUBPageViewDelegate: AnyObject {
    func pageViewDidSettle(_ view: EPUBPageView)
    func pageViewDidUnsettle(_ view: EPUBPageView)
}

@MainActor
final class EPUBPageView: UIViewController {
    let globalPage: Int
    let chapterIndex: Int
    let localPage: Int
    
    private let imageView = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var webViewContainer = UIView()
    weak var delegate: EPUBPageViewDelegate?
    
    private var fetchTask: Task<Void, Never>?
    
    init(globalPage: Int, chapterIndex: Int, localPage: Int) {
        self.globalPage = globalPage
        self.chapterIndex = chapterIndex
        self.localPage = localPage
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        
        loadingIndicator.center = view.center
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(loadingIndicator)
        
        webViewContainer.frame = view.bounds
        webViewContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webViewContainer)
        
        loadSnapshot()
    }
    
    private func loadSnapshot() {
        // Snapshot loading is handled by EPUBPageViewController and PageSnapshotProvider
        // This will be managed by the container when needed
        loadingIndicator.startAnimating()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        delegate?.pageViewDidSettle(self)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        delegate?.pageViewDidUnsettle(self)
    }
    
    deinit {
        fetchTask?.cancel()
    }
    
    func mountWebView(_ webView: WKWebView) {
        webView.frame = webViewContainer.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webViewContainer.addSubview(webView)
        // Briefly delay hiding the snapshot to strictly avoid flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.imageView.isHidden = true
        }
    }
    
    func unmountWebView() {
        webViewContainer.subviews.forEach { $0.removeFromSuperview() }
        imageView.isHidden = false
    }
}
