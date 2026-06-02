import UIKit

@MainActor
final class ReaderSpreadPageViewController: UIViewController, PageIndexProviding, CoreTextReadingPositionProviding {
    let globalPageIndex: Int
    let primaryViewController: UIViewController
    let secondaryViewController: UIViewController?
    private let isRTL: Bool
    private let gutter: CGFloat
    private let backgroundUIColor: UIColor

    var coreTextReadingPosition: CoreTextReadingPosition? {
        if let provider = primaryViewController as? CoreTextReadingPositionProviding {
            return provider.coreTextReadingPosition
        }
        return nil
    }

    var containsPlaceholderPage: Bool {
        primaryViewController is PlaceholderPageViewController ||
            secondaryViewController is PlaceholderPageViewController
    }

    init(
        globalPageIndex: Int,
        primaryViewController: UIViewController,
        secondaryViewController: UIViewController?,
        isRTL: Bool,
        gutter: CGFloat,
        backgroundColor: UIColor
    ) {
        self.globalPageIndex = globalPageIndex
        self.primaryViewController = primaryViewController
        self.secondaryViewController = secondaryViewController
        self.isRTL = isRTL
        self.gutter = gutter
        self.backgroundUIColor = backgroundColor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundUIColor
        installPages()
    }

    func applyPlaybackHighlight(text: String?) {
        (primaryViewController as? CoreTextPageViewController)?.setPlaybackHighlight(text: text)
        (secondaryViewController as? CoreTextPageViewController)?.setPlaybackHighlight(text: text)
    }

    private func installPages() {
        let leftContainer = UIView()
        let gutterView = UIView()
        let rightContainer = UIView()
        [leftContainer, gutterView, rightContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.backgroundColor = backgroundUIColor
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            leftContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftContainer.topAnchor.constraint(equalTo: view.topAnchor),
            leftContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            gutterView.leadingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            gutterView.topAnchor.constraint(equalTo: view.topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: gutter),

            rightContainer.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            rightContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightContainer.topAnchor.constraint(equalTo: view.topAnchor),
            rightContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rightContainer.widthAnchor.constraint(equalTo: leftContainer.widthAnchor),
        ])

        let orderedPages: [UIViewController?] = isRTL
            ? [secondaryViewController, primaryViewController]
            : [primaryViewController, secondaryViewController]

        install(orderedPages[0], in: leftContainer)
        install(orderedPages[1], in: rightContainer)
    }

    private func install(_ child: UIViewController?, in container: UIView) {
        guard let child else { return }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.backgroundColor = backgroundUIColor
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }
}
