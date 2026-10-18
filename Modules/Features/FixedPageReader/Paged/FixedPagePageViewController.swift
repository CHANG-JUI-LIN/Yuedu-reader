import UIKit
import VisionKit

// MARK: - Page
//
// One page of a spread: the whole image fitted into the page's slot, with a spinner while
// it loads, a retry button when it fails, and Live Text. It does not zoom; the spread
// around it does, and asks it to re-render for the zoom (`refineImage(forZoomScale:)`).

final class FixedPagePageViewController: UIViewController {

    /// Where a two-page spread's spine is, seen from this page. The page sits against it
    /// rather than in the middle of its half, so the two pages meet at the spine.
    enum SpineSide {
        case none
        case left
        case right
    }

    let pageIndex: Int
    private let page: FixedPage
    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: CGFloat

    var onImageLoaded: ((UIImage) -> Void)?
    var spineSide: SpineSide = .none {
        didSet { if isViewLoaded { layoutImage() } }
    }

    let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private(set) var loadTask: Task<Void, Never>?
    private(set) var refineTask: Task<Void, Never>?
    private var liveTextTask: Task<Void, Never>?
    private var imageAnalysisInteraction: ImageAnalysisInteraction?

    /// Whether Live Text's button shows (`FixedPageZoom.showsLiveTextButton`). Kept so an
    /// analysis that lands later honours it.
    private(set) var showsLiveTextButton = false

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

        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)

        // Live Text (VisionKit) support
        if fixedPageReaderConfiguration.isLiveTextEnabled, ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = .automatic
            interaction.isSupplementaryInterfaceHidden = !showsLiveTextButton
            imageView.addInteraction(interaction)
            self.imageAnalysisInteraction = interaction
        }

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

    /// The whole page fitted into its slot — the paged modes' `fitPage` — centred, or
    /// against the spine in a spread. It used to fill the slot's width and cut off what fell
    /// below: in landscape, most of a portrait page, out of reach even when zoomed.
    private func layoutImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let originX: CGFloat
        switch spineSide {
        case .none: originX = (bounds.width - size.width) / 2
        case .left: originX = 0
        case .right: originX = bounds.width - size.width
        }
        imageView.frame = CGRect(origin: CGPoint(x: originX, y: (bounds.height - size.height) / 2), size: size)
    }

    private func load() {
        retryButton.isHidden = true
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: page,
                targetWidth: targetWidth,
                cropBorders: fixedPageReaderConfiguration.cropBorders
            )
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            if let image {
                self.baseImage = image
                self.renderedWidthMultiple = 1
                self.imageView.image = image
                // UI tests find a page only once its image is on screen
                // (DetailReaderBackSwipeUITests). VoiceOver never reads an
                // identifier, and it leaves the image unfocusable as before.
                self.imageView.accessibilityIdentifier = "fixed_page_image"
                self.layoutImage()
                self.onImageLoaded?(image)
                self.analyzeLiveText(for: image)
            } else {
                self.retryButton.isHidden = false
            }
        }
    }

    private func analyzeLiveText(for image: UIImage) {
        guard fixedPageReaderConfiguration.isLiveTextEnabled, ImageAnalyzer.isSupported else { return }
        liveTextTask?.cancel()
        liveTextTask = Task { [weak self] in
            let analyzer = ImageAnalyzer()
            let config = ImageAnalyzer.Configuration([.text])
            do {
                let analysis = try await analyzer.analyze(image, configuration: config)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, let interaction = self.imageAnalysisInteraction else { return }
                    interaction.analysis = analysis
                    interaction.setLiveTextButtonHidden(!self.showsLiveTextButton)
                }
            } catch {
                // Ignore background analysis failures
            }
        }
    }

    /// Re-rasterize a vector-backed page (PDF, fixed-layout EPUB) for the spread's zoom
    /// scale, and go back to the 1x render once zoomed out. An image page has no detail
    /// beyond its own pixels, so it stays put.
    func refineImage(forZoomScale zoomScale: CGFloat) {
        guard page.renderSource.isRasterizedOnDemand, targetWidth > 0, baseImage != nil else { return }

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
        guard desiredWidth > targetWidth * renderedWidthMultiple * 1.2 else { return }

        refineTask?.cancel()
        refineTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: self.page,
                targetWidth: desiredWidth,
                renderScale: renderScale,
                cropBorders: self.fixedPageReaderConfiguration.cropBorders
            )
            if Task.isCancelled { return }
            guard let image else { return }
            self.imageView.image = image
            self.renderedWidthMultiple = desiredWidth / self.targetWidth
        }
    }

    func setShowsLiveTextButton(_ shows: Bool) {
        guard shows != showsLiveTextButton else { return }
        showsLiveTextButton = shows
        imageAnalysisInteraction?.setLiveTextButtonHidden(!shows)
    }

    @objc private func retry() { load() }

    func clearImage() {
        loadTask?.cancel()
        refineTask?.cancel()
        liveTextTask?.cancel()
        imageView.image = nil
        imageView.accessibilityIdentifier = nil
        baseImage = nil
        renderedWidthMultiple = 1
    }
}
