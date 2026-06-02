import UIKit

// MARK: - Webtoon page cell
//
// Full-width image cell. Loads lazily on display (via `load()`), unloads on
// reuse/exit (memory), and reports its real aspect ratio to the layout once the
// image arrives.

final class MangaWebtoonCell: UICollectionViewCell {

    static let reuseID = "MangaWebtoonCell"

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loadTask: Task<Void, Never>?

    private var page: MangaPage?
    private var index = 0
    private var targetWidth: CGFloat = 0
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

    func configure(page: MangaPage, index: Int, targetWidth: CGFloat, onRatio: @escaping (Int, CGFloat) -> Void) {
        self.page = page
        self.index = index
        self.targetWidth = targetWidth
        self.onRatio = onRatio
    }

    func load() {
        guard let page else { return }
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await MangaImageLoader.loadImage(for: page, targetWidth: targetWidth)
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            guard let image, image.size.width > 0 else { return }
            self.imageView.image = image
            self.onRatio?(self.index, image.size.height / image.size.width)
        }
    }

    func unload() {
        loadTask?.cancel()
        imageView.image = nil
        spinner.stopAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        unload()
    }
}
