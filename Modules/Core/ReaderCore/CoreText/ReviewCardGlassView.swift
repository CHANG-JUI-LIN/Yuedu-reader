import UIKit

/// The live part of a template card (`ReviewCardImage`): the system's glass behind each of its
/// `data-yd-glass` panels, and the card's text above it. Glass samples the page behind it as it
/// is shown, so a page bitmap cannot hold it; the page puts one of these where the card is.
///
/// iOS 26 draws Liquid Glass (`UIGlassEffect`); earlier systems the thin system material, the
/// nearest glass they have. Taps pass through to the page.
@MainActor
final class ReviewCardGlassView: UIView {
    private(set) var image: ReviewCardImage?
    private let imageView = UIImageView()
    private var panelViews: [UIVisualEffectView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The glass takes the card's dark or light look (`ReviewCardImage.isNight`): the reader's
    /// night theme is not the system's dark mode. `opacity` (the card's CSS opacity) fades its
    /// text only: a visual effect view under a translucent ancestor stops drawing its glass.
    func configure(image: ReviewCardImage, opacity: CGFloat) {
        imageView.alpha = opacity
        guard self.image !== image else { return }
        overrideUserInterfaceStyle = image.isNight ? .dark : .light
        self.image = image
        imageView.image = image
        if panelViews.count != image.glassPanels.count {
            panelViews.forEach { $0.removeFromSuperview() }
            panelViews = image.glassPanels.map { _ in
                let panel = UIVisualEffectView(effect: Self.glassEffect)
                insertSubview(panel, belowSubview: imageView)
                return panel
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        guard let image else { return }
        for (view, panel) in zip(panelViews, image.glassPanels) {
            let placed = panel.placed(in: bounds, imageSize: image.size)
            view.frame = placed.rect
            if #available(iOS 26.0, *) {
                view.cornerConfiguration = .corners(radius: .fixed(placed.cornerRadius))
            } else {
                view.layer.cornerRadius = placed.cornerRadius
                view.layer.cornerCurve = .continuous
                view.clipsToBounds = true
            }
        }
    }

    private static var glassEffect: UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect(style: .regular)
        }
        return UIBlurEffect(style: .systemThinMaterial)
    }
}
