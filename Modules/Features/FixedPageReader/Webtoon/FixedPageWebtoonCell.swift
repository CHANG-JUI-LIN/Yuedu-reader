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
    private var isLiveTextEnabled = true
    private var onRatio: ((Int, CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        if ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = .automatic
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        page: FixedPage,
        index: Int,
        targetWidth: CGFloat,
        cropBorders: Bool = false,
        isLiveTextEnabled: Bool = true,
        onRatio: @escaping (Int, CGFloat) -> Void
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
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: page,
                targetWidth: targetWidth,
                cropBorders: cropBorders
            )
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            guard let image, image.size.width > 0 else { return }
            self.imageView.image = image
            self.onRatio?(self.index, image.size.height / image.size.width)
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
                    self?.imageAnalysisInteraction?.analysis = analysis
                }
            } catch {
                // Ignore background analysis failures
            }
        }
    }

    func unload() {
        loadTask?.cancel()
        liveTextTask?.cancel()
        imageView.image = nil
        spinner.stopAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        unload()
    }
}
