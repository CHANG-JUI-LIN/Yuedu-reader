import UIKit
import VisionKit

// MARK: - Webtoon page cell
//
// Full-width image cell. Loads lazily on display (via `load()`), unloads on
// reuse/exit (memory), reports its real aspect ratio to the layout once the
// image arrives, and provides Live Text support.

final class FixedPageWebtoonCell: UICollectionViewCell {

    static let reuseID = "FixedPageWebtoonCell"

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loadTask: Task<Void, Never>?
    private var liveTextTask: Task<Void, Never>?
    private var imageAnalysisInteraction: ImageAnalysisInteraction?

    private var page: FixedPage?
    private var index = 0
    private var targetWidth: CGFloat = 0
    private var cropBorders = false
    private var isLiveTextEnabled = false
    /// Reports a loaded image's height/width with the item index and the page it was
    /// loaded for. The index is the one this cell was configured with, which a prepended
    /// chapter can make stale before the cell is reconfigured; the page lets the reader
    /// tell (`FixedPageWebtoonViewController.pageImageDidLoad`).
    private var onRatio: ((Int, FixedPage, CGFloat) -> Void)?
    /// Whether Live Text's button shows (`FixedPageZoom.showsLiveTextButton`). Kept so an
    /// analysis that lands later honours it.
    private var showsLiveTextButton = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        // A page never paints over its neighbours, whatever its image or Live Text's
        // overlay does inside it.
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        if ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = .automatic
            interaction.isSupplementaryInterfaceHidden = !showsLiveTextButton
            imageView.addInteraction(interaction)
            self.imageAnalysisInteraction = interaction
        }

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        // A page drawn on demand is a bitmap at the display scale it was loaded for; on a
        // screen of another scale it is drawn again.
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            guard self.page?.renderSource.isRasterizedOnDemand == true else { return }
            self.load()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        page: FixedPage,
        index: Int,
        targetWidth: CGFloat,
        cropBorders: Bool = false,
        isLiveTextEnabled: Bool = false,
        onRatio: @escaping (Int, FixedPage, CGFloat) -> Void
    ) {
        self.page = page
        self.index = index
        self.targetWidth = targetWidth
        self.cropBorders = cropBorders
        self.isLiveTextEnabled = isLiveTextEnabled
        self.onRatio = onRatio
    }

    func load() {
        guard let page else { return }
        let index = self.index
        spinner.startAnimating()
        loadTask?.cancel()
        let renderScale = traitCollection.displayScale
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: page,
                targetWidth: targetWidth,
                renderScale: renderScale,
                cropBorders: cropBorders
            )
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            guard let image, image.size.width > 0 else { return }
            self.imageView.image = image
            // UI tests find a strip page by its position once its image is on screen
            // (DetailReaderBackSwipeUITests); cells are reused, so the index is in it.
            // VoiceOver never reads an identifier.
            self.imageView.accessibilityIdentifier = "webtoon_page_\(index)"
            self.onRatio?(index, page, image.size.height / image.size.width)
            self.analyzeLiveText(for: image)
        }
    }

    private func analyzeLiveText(for image: UIImage) {
        guard isLiveTextEnabled, ImageAnalyzer.isSupported else { return }
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

    func setShowsLiveTextButton(_ shows: Bool) {
        guard shows != showsLiveTextButton else { return }
        showsLiveTextButton = shows
        imageAnalysisInteraction?.setLiveTextButtonHidden(!shows)
    }

    func unload() {
        loadTask?.cancel()
        liveTextTask?.cancel()
        // The analysis belongs to the image going away: kept, a reused cell would pick
        // out the previous page's text over the next page until its own analysis lands.
        imageAnalysisInteraction?.analysis = nil
        imageView.image = nil
        imageView.accessibilityIdentifier = nil
        spinner.stopAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        unload()
    }
}
