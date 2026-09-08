    import UIKit

// MARK: - Fixed page spread view controller
//
// Represents a single visible page or a two-page spread (side-by-side) in paged
// mode, ported and adapted from Aidoku's ReaderDoublePageViewController.

final class FixedPageSpreadViewController: UIViewController {

    let spreadIndex: Int
    let pages: [FixedPage]
    let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    let targetWidth: CGFloat

    var primaryPageIndex: Int {
        pages.first?.id ?? 0
    }

    private let scrollView = FixedPageZoomableScrollView()
    private let stackView = UIStackView()
    private var pageControllers: [FixedPagePageViewController] = []

    init(
        spreadIndex: Int,
        pages: [FixedPage],
        fixedPageReaderConfiguration: FixedPageReaderConfiguration,
        targetWidth: CGFloat
    ) {
        self.spreadIndex = spreadIndex
        self.pages = pages
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
        scrollView.zoomEnabled = fixedPageReaderConfiguration.isZoomEnabled
        view.addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.alignment = .fill
        stackView.spacing = 0
        scrollView.addSubview(stackView)
        scrollView.zoomView = stackView

        installPages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSpread()
    }

    private func installPages() {
        let isRTL = fixedPageReaderConfiguration.progression == .rightToLeft
        let singleTargetW = pages.count > 1 ? targetWidth / 2 : targetWidth

        var controllers = pages.map { page in
            let vc = FixedPagePageViewController(
                page: page,
                index: page.id,
                fixedPageReaderConfiguration: fixedPageReaderConfiguration,
                targetWidth: singleTargetW
            )
            vc.isEmbeddedInSpread = true
            return vc
        }

        // In RTL double-page mode, the lower-index page is on the right
        if isRTL && controllers.count == 2 {
            controllers.reverse()
        }

        pageControllers = controllers
        for vc in pageControllers {
            addChild(vc)
            stackView.addArrangedSubview(vc.view)
            vc.didMove(toParent: self)
        }
    }

    private func layoutSpread() {
        let bounds = scrollView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        scrollView.resetZoom()
        stackView.frame = CGRect(origin: .zero, size: bounds.size)
        scrollView.contentSize = bounds.size
        scrollView.centerView()
    }

    func clearPages() {
        for vc in pageControllers {
            vc.clearImage()
        }
    }
}
