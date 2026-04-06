/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import UIKit

@MainActor
final class SnapshotPageContentController: UIViewController {
    let pageIndex: Int
    private let provider: PageSnapshotProvider
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loadGeneration: Int = 0

    init(pageIndex: Int, provider: PageSnapshotProvider, backgroundColor: UIColor) {
        self.pageIndex = pageIndex
        self.provider = provider
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = backgroundColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        refresh()
    }

    func refresh(backgroundColor: UIColor? = nil) {
        if let backgroundColor {
            view.backgroundColor = backgroundColor
        }
        loadGeneration &+= 1
        let generation = loadGeneration

        if let image = provider.cachedSnapshot(for: pageIndex) {
            spinner.stopAnimating()
            imageView.image = image
            return
        }

        spinner.startAnimating()
        imageView.image = nil
        provider.requestSnapshot(for: pageIndex) { [weak self] image in
            guard let self else { return }
            guard generation == self.loadGeneration else { return }
            self.spinner.stopAnimating()
            self.imageView.image = image
        }
    }
}

@MainActor
final class ReaderPageViewController: UIPageViewController {
    private let renderer: EPUBPageRenderer
    private let snapshotProvider: PageSnapshotProvider
    private let pageTurnStyle: PageTurnStyle
    var onTapCenter: (() -> Void)?

    private var displayedPage: Int = 0
    private var coverPanGesture: UIPanGestureRecognizer?
    private let coverOverlayView = UIView()
    private let coverCurrentImageView = UIImageView()
    private let coverIncomingImageView = UIImageView()
    private let coverShadowView = UIView()
    private var coverTargetPage: Int?
    private var coverDirection: Int = 0

    init(
        renderer: EPUBPageRenderer,
        snapshotProvider: PageSnapshotProvider,
        pageTurnStyle: PageTurnStyle,
        onTapCenter: (() -> Void)? = nil
    ) {
        self.renderer = renderer
        self.snapshotProvider = snapshotProvider
        self.pageTurnStyle = pageTurnStyle
        self.onTapCenter = onTapCenter

        let transitionStyle: UIPageViewController.TransitionStyle =
            pageTurnStyle == .curl ? .pageCurl : .scroll
        super.init(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )

        dataSource = pageTurnStyle == .cover ? nil : self
        delegate = self
        isDoubleSided = false
        view.backgroundColor = renderer.themeBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCenterTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        if pageTurnStyle == .cover {
            setupCoverOverlayIfNeeded()
            for case let scrollView as UIScrollView in view.subviews {
                scrollView.isScrollEnabled = false
            }
        }

        updateCurrentPage(renderer.currentEpubPage, animated: false)
    }

    func updateCurrentPage(_ page: Int, animated: Bool) {
        guard renderer.totalPages > 0 else { return }
        let clamped = max(0, min(page, renderer.totalPages - 1))
        if displayedPage == clamped,
           let visible = viewControllers?.first as? SnapshotPageContentController,
           visible.pageIndex == clamped
        {
            refreshVisiblePage()
            snapshotProvider.warmWindow(around: clamped, radius: preloadRadius)
            return
        }
        let direction: NavigationDirection = clamped >= displayedPage ? .forward : .reverse
        displayedPage = clamped
        let controller = makeController(for: clamped)
        let shouldAnimate = pageTurnStyle != .none && pageTurnStyle != .cover && animated
        setViewControllers([controller], direction: direction, animated: shouldAnimate) { _ in }
        renderer.willDisplayPage(clamped, style: rendererStyle)
        snapshotProvider.warmWindow(around: clamped, radius: preloadRadius)
    }

    func refreshVisiblePage() {
        view.backgroundColor = renderer.themeBackgroundColor()
        for case let controller as SnapshotPageContentController in viewControllers ?? [] {
            controller.refresh(backgroundColor: renderer.themeBackgroundColor())
        }
    }

    private var rendererStyle: PageTurnStyle {
        switch pageTurnStyle {
        case .none:
            return .slide
        default:
            return pageTurnStyle
        }
    }

    private var preloadRadius: Int {
        switch pageTurnStyle {
        case .curl:
            return 1
        case .slide, .cover:
            return 2
        case .none:
            return 0
        }
    }

    private func makeController(for page: Int) -> SnapshotPageContentController {
        SnapshotPageContentController(
            pageIndex: page,
            provider: snapshotProvider,
            backgroundColor: renderer.themeBackgroundColor()
        )
    }

    private func pageIndex(for controller: UIViewController) -> Int? {
        (controller as? SnapshotPageContentController)?.pageIndex
    }

    private func setupCoverOverlayIfNeeded() {
        guard coverPanGesture == nil else { return }

        coverOverlayView.translatesAutoresizingMaskIntoConstraints = false
        coverOverlayView.isHidden = true
        coverOverlayView.isUserInteractionEnabled = false
        coverOverlayView.clipsToBounds = true
        coverOverlayView.backgroundColor = .clear
        view.addSubview(coverOverlayView)

        NSLayoutConstraint.activate([
            coverOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coverOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coverOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            coverOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        coverCurrentImageView.contentMode = .scaleAspectFit
        coverCurrentImageView.clipsToBounds = true
        coverCurrentImageView.frame = view.bounds
        coverCurrentImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coverOverlayView.addSubview(coverCurrentImageView)

        coverIncomingImageView.contentMode = .scaleAspectFit
        coverIncomingImageView.clipsToBounds = true
        coverIncomingImageView.frame = view.bounds
        coverIncomingImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coverOverlayView.addSubview(coverIncomingImageView)

        coverShadowView.backgroundColor = UIColor.black.withAlphaComponent(0.16)
        coverShadowView.frame = CGRect(x: 0, y: 0, width: 18, height: view.bounds.height)
        coverShadowView.autoresizingMask = [.flexibleHeight]
        coverIncomingImageView.addSubview(coverShadowView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCoverPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        coverPanGesture = pan
    }

    @objc
    private func handleCoverPan(_ gesture: UIPanGestureRecognizer) {
        guard pageTurnStyle == .cover else { return }
        guard renderer.totalPages > 0 else { return }

        let width = max(view.bounds.width, 1)
        let translationX = gesture.translation(in: view).x
        let velocityX = gesture.velocity(in: view).x

        switch gesture.state {
        case .began:
            renderer.beginGestureInteraction(interruptedOffset: renderer.interruptAnimation())
            coverTargetPage = nil
            coverDirection = 0
            coverOverlayView.isHidden = false
            coverCurrentImageView.image = snapshotProvider.cachedSnapshot(for: displayedPage)
        case .changed:
            if coverTargetPage == nil {
                if translationX < -6, displayedPage < renderer.totalPages - 1 {
                    coverDirection = 1
                    coverTargetPage = displayedPage + 1
                } else if translationX > 6, displayedPage > 0 {
                    coverDirection = -1
                    coverTargetPage = displayedPage - 1
                }
                if let target = coverTargetPage {
                    coverIncomingImageView.image = snapshotProvider.cachedSnapshot(for: target)
                    if coverIncomingImageView.image == nil {
                        snapshotProvider.requestSnapshot(for: target, priority: -2) { [weak self] image in
                            self?.coverIncomingImageView.image = image
                        }
                    }
                }
            }

            guard coverTargetPage != nil else { return }
            renderer.updateGestureInteraction()
            let rawProgress = min(max(abs(translationX) / width, 0), 1)
            let commitProgress = max(0, min(rawProgress, 0.999))
            if coverDirection == 1 {
                coverIncomingImageView.frame.origin.x = width * (1 - commitProgress)
            } else {
                coverIncomingImageView.frame.origin.x = -width * (1 - commitProgress)
            }
            coverShadowView.alpha = 0.2 * commitProgress
        case .ended, .cancelled, .failed:
            guard let targetPage = coverTargetPage else {
                renderer.endGestureInteraction(targetPage: displayedPage)
                renderer.cancelInteractionPage(displayedPage, style: .cover)
                resetCoverOverlay()
                return
            }

            let progress = min(max(abs(translationX) / width, 0), 1)
            let shouldCommit = progress > 0.34 || abs(velocityX) > 560
            renderer.endGestureInteraction(targetPage: shouldCommit ? targetPage : displayedPage)

            let destinationX: CGFloat
            if shouldCommit {
                destinationX = 0
            } else {
                destinationX = coverDirection == 1 ? width : -width
            }

            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.coverIncomingImageView.frame.origin.x = destinationX
                self.coverShadowView.alpha = shouldCommit ? 0.2 : 0
            } completion: { _ in
                if shouldCommit {
                    self.displayedPage = targetPage
                    self.renderer.goToPage(targetPage)
                    self.renderer.settleInteractionPage(targetPage, style: .cover)
                    let controller = self.makeController(for: targetPage)
                    self.setViewControllers([controller], direction: .forward, animated: false) { _ in }
                    self.snapshotProvider.warmWindow(around: targetPage, radius: self.preloadRadius)
                } else {
                    self.renderer.cancelInteractionPage(self.displayedPage, style: .cover)
                }
                self.resetCoverOverlay()
            }
        default:
            break
        }
    }

    private func resetCoverOverlay() {
        coverOverlayView.isHidden = true
        coverCurrentImageView.image = nil
        coverIncomingImageView.image = nil
        coverIncomingImageView.frame = view.bounds
        coverShadowView.alpha = 0
        coverTargetPage = nil
        coverDirection = 0
    }

    @objc
    private func handleCenterTap() {
        onTapCenter?()
    }
}

extension ReaderPageViewController: UIPageViewControllerDataSource {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = pageIndex(for: viewController), page > 0 else { return nil }
        return makeController(for: page - 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = pageIndex(for: viewController), page < renderer.totalPages - 1 else { return nil }
        return makeController(for: page + 1)
    }
}

extension ReaderPageViewController: UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        guard let pending = pendingViewControllers.first,
              let page = pageIndex(for: pending)
        else { return }
          renderer.beginGestureInteraction(interruptedOffset: renderer.interruptAnimation())
        snapshotProvider.warmWindow(around: page, radius: preloadRadius)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard let visible = viewControllers?.first,
              let page = pageIndex(for: visible)
        else { return }

        if completed {
            displayedPage = page
            renderer.endGestureInteraction(targetPage: page)
            renderer.goToPage(page)
            renderer.settleInteractionPage(page, style: rendererStyle)
            snapshotProvider.warmWindow(around: page, radius: preloadRadius)
        } else {
            renderer.endGestureInteraction(targetPage: displayedPage)
            renderer.cancelInteractionPage(displayedPage, style: rendererStyle)
            snapshotProvider.warmWindow(around: displayedPage, radius: preloadRadius)
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation {
        .min
    }
}
*/
