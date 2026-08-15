import UIKit

// MARK: - Single paged page
//
// One zoomable, aspect-fit image page for the paged reader (port of Aidoku's
// ReaderPageViewController, slimmed). Loads via Nuke with source headers; shows a
// spinner while loading and a retry button on failure.

final class FixedPagePageViewController: UIViewController {

    let pageIndex: Int
    private let page: FixedPage
    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: CGFloat

    private let scrollView = FixedPageZoomableScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    /// The 1x render, kept so zooming back out drops the large one.
    private var baseImage: UIImage?
    /// Width multiple the currently displayed image was rendered at.
    private var renderedWidthMultiple: CGFloat = 1

    init(
        page: FixedPage,
        index: Int,
        fixedPageReaderConfiguration: FixedPageReaderConfiguration,
        targetWidth: CGFloat
    ) {
        self.page = page
        self.pageIndex = index
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
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
        scrollView.zoomEnabled = fixedPageReaderConfiguration.isZoomEnabled
        scrollView.zoomView = imageView
        scrollView.onZoomSettled = { [weak self] scale in self?.refineImage(forZoomScale: scale) }

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
        // Zoom is gone, so is the reason to hold a zoomed-in render.
        refineImage(forZoomScale: 1)
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
            let image = await FixedPageImageLoader.loadImage(for: page, targetWidth: targetWidth)
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            if let image {
                self.baseImage = image
                self.renderedWidthMultiple = 1
                self.imageView.image = image
                self.layoutImage()
            } else {
                self.retryButton.isHidden = false
            }
        }
    }

    /// Re-rasterize a vector-backed page (PDF, fixed-layout EPUB) at the zoomed-in
    /// scale. An image page has no detail beyond its own pixels, so it stays put.
    private func refineImage(forZoomScale zoomScale: CGFloat) {
        guard page.renderSource != .image, targetWidth > 0, baseImage != nil else { return }

        if zoomScale <= 1.05 {
            refineTask?.cancel()
            if renderedWidthMultiple > 1 {
                imageView.image = baseImage
                renderedWidthMultiple = 1
            }
            return
        }

        let renderScale = FixedPageImageLoader.defaultRenderScale
        let maxPointWidth = FixedPageImageLoader.maxRasterPixelWidth / renderScale
        let desiredWidth = min(targetWidth * zoomScale, maxPointWidth)
        // Skip re-rendering for a marginal gain over what is already on screen.
        guard desiredWidth > targetWidth * renderedWidthMultiple * 1.2 else { return }

        refineTask?.cancel()
        refineTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: self.page,
                targetWidth: desiredWidth,
                renderScale: renderScale
            )
            if Task.isCancelled { return }
            guard let image else { return }
            self.imageView.image = image
            self.renderedWidthMultiple = desiredWidth / self.targetWidth
        }
    }

    @objc private func retry() { load() }

    func clearImage() {
        loadTask?.cancel()
        refineTask?.cancel()
        imageView.image = nil
        baseImage = nil
        renderedWidthMultiple = 1
        scrollView.resetZoom()
    }
}
