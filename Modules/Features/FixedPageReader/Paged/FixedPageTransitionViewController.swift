import UIKit

// MARK: - Chapter transition page
//
// Displayed between chapters in paged mode (adapted from Aidoku's ReaderInfoPageView),
// showing the boundary between previous and next chapters.

final class FixedPageTransitionViewController: UIViewController {

    enum Direction {
        case next(currentTitle: String, nextTitle: String?)
        case previous(currentTitle: String, prevTitle: String?)
    }

    let direction: Direction

    init(direction: Direction) {
        self.direction = direction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 16
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let icon = UIImageView()
        icon.tintColor = .systemGray
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let headerLabel = UILabel()
        headerLabel.font = .systemFont(ofSize: 15, weight: .medium)
        headerLabel.textColor = .secondaryLabel
        headerLabel.textAlignment = .center

        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        let hintLabel = UILabel()
        hintLabel.font = .systemFont(ofSize: 13, weight: .regular)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.textAlignment = .center

        switch direction {
        case .next(let currentTitle, let nextTitle):
            icon.image = UIImage(systemName: "forward.end.circle")
            headerLabel.text = currentTitle
            if let next = nextTitle, !next.isEmpty {
                titleLabel.text = String(format: localized("下一章：%@"), next)
                hintLabel.text = localized("繼續翻頁進入下一章")
            } else {
                titleLabel.text = localized("已是最後一章")
                hintLabel.text = ""
            }
        case .previous(let currentTitle, let prevTitle):
            icon.image = UIImage(systemName: "backward.end.circle")
            headerLabel.text = currentTitle
            if let prev = prevTitle, !prev.isEmpty {
                titleLabel.text = String(format: localized("上一章：%@"), prev)
                hintLabel.text = localized("繼續翻頁回到上一章")
            } else {
                titleLabel.text = localized("已是第一章")
                hintLabel.text = ""
            }
        }

        container.addArrangedSubview(icon)
        container.addArrangedSubview(headerLabel)
        container.addArrangedSubview(titleLabel)
        if !hintLabel.text!.isEmpty {
            container.addArrangedSubview(hintLabel)
        }

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}
