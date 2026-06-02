import UIKit

// MARK: - Single paged page
//
// One zoomable, aspect-fit image page for the paged reader (port of Aidoku's
// ReaderPageViewController, slimmed). Loads via Nuke with source headers; shows a
// spinner while loading and a retry button on failure.

final class MangaPageViewController: UIViewController {

    let pageIndex: Int
    private let page: MangaPage
    private let targetWidth: CGFloat

    private let scrollView = MangaZoomableScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?

    init(page: MangaPage, index: Int, targetWidth: CGFloat) {
        self.page = page
        self.pageIndex = index
        self.targetWidth = targetWidth
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        scrollView.zoomView = imageView

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        retryButton.setTitle(localized("載入失敗，點擊重試"), for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImage()
    }

    private func layoutImage() {
        guard let image = imageView.image else { return }
        let bounds = scrollView.bounds
        guard bounds.width > 0, image.size.width > 0 else { return }
        scrollView.resetZoom()
        let height = bounds.width * (image.size.height / image.size.width)
        imageView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        scrollView.contentSize = imageView.frame.size
        scrollView.centerView()
    }

    private func load() {
        retryButton.isHidden = true
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await MangaImageLoader.loadImage(for: page, targetWidth: targetWidth)
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            if let image {
                self.imageView.image = image
                self.layoutImage()
            } else {
                self.retryButton.isHidden = false
            }
        }
    }

    @objc private func retry() { load() }

    func clearImage() {
        loadTask?.cancel()
        imageView.image = nil
        scrollView.resetZoom()
    }
}
