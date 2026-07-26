import SwiftUI
import UIKit

extension IOS17SearchResultTableRow {
    @MainActor
    @inline(never)
    init(searchBook book: SearchBook) {
        self.init(
            id: book.id,
            title: book.displayName,
            author: book.author,
            intro: book.displayIntro,
            coverURL: book.coverUrl,
            sourceCount: book.origins.count,
            showsAudiobookBadge: book.inferredContentKind() == .audio
        )
    }
}

/// Native iOS 17 search-result list.
///
/// Build 45 watchdog reports from iOS 17.0 and 17.7.2 both ended in
/// SwiftUI/AttributeGraph scene updates after the row-level hot functions had
/// been removed. Keep every result row out of SwiftUI on iOS 17: this bridge
/// passes one bounded value snapshot to a native table and resolves the full
/// `SearchBook` only after selection. Delete this compatibility renderer when
/// the deployment target reaches iOS 18.
@MainActor
struct IOS17SearchResultTable: UIViewControllerRepresentable {
    let content: IOS17SearchResultTableContent
    let onSelect: (UUID) -> Void
    let onLoadMore: () -> Void

    func makeUIViewController(context _: Context) -> IOS17SearchResultTableViewController {
        IOS17SearchResultTableViewController()
    }

    func updateUIViewController(
        _ viewController: IOS17SearchResultTableViewController,
        context _: Context
    ) {
        viewController.update(
            content: content,
            onSelect: onSelect,
            onLoadMore: onLoadMore
        )
    }
}

@MainActor
final class IOS17SearchResultTableViewController: UITableViewController {
    private enum Section: Hashable {
        case results
    }

    private enum Item: Hashable {
        case result(UUID)
        case loadMore
    }

    private static let resultCellIdentifier = "IOS17SearchResultCell"
    private static let loadMoreCellIdentifier = "IOS17SearchLoadMoreCell"

    private var currentContent: IOS17SearchResultTableContent?
    private var rowsByID: [UUID: IOS17SearchResultTableRow] = [:]
    private var onSelect: (UUID) -> Void = { _ in }
    private var onLoadMore: () -> Void = {}
    private var dataSource: UITableViewDiffableDataSource<Section, Item>!

    init() {
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(DSColor.separator)
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: DSSpacing.lg + DSLayout.searchResultCoverWidth + DSSpacing.md,
            bottom: 0,
            right: DSSpacing.lg
        )
        tableView.estimatedRowHeight =
            DSLayout.searchResultCoverHeight + DSSpacing.sm * 2
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(
            IOS17SearchResultTableCell.self,
            forCellReuseIdentifier: Self.resultCellIdentifier
        )
        configureDataSource()
    }

    @inline(never)
    func update(
        content: IOS17SearchResultTableContent,
        onSelect: @escaping (UUID) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        loadViewIfNeeded()
        self.onSelect = onSelect
        self.onLoadMore = onLoadMore
        guard content.requiresReload(comparedTo: currentContent) else { return }

        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            SourcePerfTrace.record(
                "search.iOS17.nativeTableApply",
                "\(content.rows.count) rows loadMore=\(content.showsLoadMore)",
                since: startedAt,
                thresholdMs: 4
            )
        }
        currentContent = content
        rowsByID = Dictionary(uniqueKeysWithValues: content.rows.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.results])
        snapshot.appendItems(content.rows.map { .result($0.id) })
        if content.showsLoadMore {
            snapshot.appendItems([.loadMore])
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .result(let id):
            onSelect(id)
        case .loadMore:
            onLoadMore()
        }
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Section, Item>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case .result(let id):
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: Self.resultCellIdentifier,
                        for: indexPath
                    ) as? IOS17SearchResultTableCell,
                    let row = self.rowsByID[id]
                else {
                    return nil
                }
                cell.configure(with: row)
                return cell

            case .loadMore:
                let cell =
                    tableView.dequeueReusableCell(
                        withIdentifier: Self.loadMoreCellIdentifier
                    )
                    ?? UITableViewCell(
                        style: .default,
                        reuseIdentifier: Self.loadMoreCellIdentifier
                    )
                var configuration = UIListContentConfiguration.cell()
                configuration.text = localized("載入更多")
                configuration.image = UIImage(systemName: "arrow.down.circle")
                configuration.textProperties.color = .tintColor
                configuration.textProperties.font = GlobalAppTypography.uiFont(
                    .subheadline,
                    postScriptName: GlobalAppTypography.activePostScriptName,
                    compatibleWith: self.traitCollection
                )
                configuration.imageProperties.tintColor = .tintColor
                configuration.textToSecondaryTextVerticalPadding = DSSpacing.xs
                cell.contentConfiguration = configuration
                cell.backgroundColor = .clear
                cell.accessibilityTraits = .button
                return cell
            }
        }
        dataSource.defaultRowAnimation = .none
    }
}

@MainActor
private final class IOS17SearchResultTableCell: UITableViewCell {
    private let coverContainer = UIView()
    private let coverImageView = UIImageView()
    private let coverTitleLabel = UILabel()
    private let audiobookBadge = UIImageView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let introLabel = UILabel()
    private let sourceBadge = UIStackView()
    private let sourceIcon = UIImageView()
    private let sourceLabel = UILabel()

    private var representedID: UUID?
    private var coverTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildViewHierarchy()
        applyTypography()
        applyColors()
        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self,
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self,
        ]) { (cell: IOS17SearchResultTableCell, _: UITraitCollection) in
            cell.applyTypography()
            cell.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        coverTask?.cancel()
        coverTask = nil
        coverImageView.image = nil
        coverImageView.isHidden = true
        coverTitleLabel.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coverContainer.layer.cornerRadius = DSRadius.sm
        sourceBadge.layer.cornerRadius = sourceBadge.bounds.height / 2
        audiobookBadge.layer.cornerRadius =
            DSLayout.searchResultAudiobookBadgeSize / 2
    }

    @inline(never)
    func configure(with row: IOS17SearchResultTableRow) {
        representedID = row.id
        titleLabel.text = row.title
        authorLabel.text = row.author
        authorLabel.isHidden = row.author.isEmpty
        introLabel.text = row.intro
        introLabel.isHidden = row.intro.isEmpty
        coverTitleLabel.text = row.title
        sourceLabel.text = "\(row.sourceCount) " + localized("源")
        audiobookBadge.isHidden = !row.showsAudiobookBadge
        sourceBadge.backgroundColor = UIColor(
            row.sourceCount > 1 ? DSColor.accent : DSColor.surfaceTertiary
        )
        sourceIcon.tintColor = UIColor(
            row.sourceCount > 1 ? DSColor.textOnAccent : DSColor.textSecondary
        )
        sourceLabel.textColor = UIColor(
            row.sourceCount > 1 ? DSColor.textOnAccent : DSColor.textSecondary
        )

        accessibilityLabel = [
            row.title,
            row.author,
            row.intro,
            "\(row.sourceCount) " + localized("源"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "，")

        loadCover(for: row)
    }

    private func buildViewHierarchy() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        let selectedView = UIView()
        selectedView.backgroundColor = UIColor(DSColor.highlight)
        selectedBackgroundView = selectedView

        coverContainer.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.clipsToBounds = true
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.isAccessibilityElement = false

        coverTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        coverTitleLabel.numberOfLines = 6
        coverTitleLabel.isAccessibilityElement = false

        audiobookBadge.translatesAutoresizingMaskIntoConstraints = false
        audiobookBadge.image = UIImage(systemName: "headphones")
        audiobookBadge.contentMode = .center
        audiobookBadge.tintColor = UIColor(DSColor.textOnAccent)
        audiobookBadge.backgroundColor = UIColor(DSColor.accent)
        audiobookBadge.clipsToBounds = true
        audiobookBadge.isAccessibilityElement = false

        coverContainer.addSubview(coverTitleLabel)
        coverContainer.addSubview(coverImageView)
        coverContainer.addSubview(audiobookBadge)

        titleLabel.numberOfLines = 1
        authorLabel.numberOfLines = 1
        introLabel.numberOfLines = 2
        for label in [titleLabel, authorLabel, introLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
        }

        let informationStack = UIStackView(
            arrangedSubviews: [titleLabel, authorLabel, introLabel]
        )
        informationStack.axis = .vertical
        informationStack.alignment = .fill
        informationStack.spacing = DSSpacing.xs

        sourceIcon.image = UIImage(systemName: "globe")
        sourceIcon.contentMode = .scaleAspectFit
        sourceIcon.isAccessibilityElement = false
        sourceLabel.numberOfLines = 1
        sourceLabel.adjustsFontForContentSizeCategory = true
        sourceLabel.isAccessibilityElement = false

        sourceBadge.axis = .horizontal
        sourceBadge.alignment = .center
        sourceBadge.spacing = DSSpacing.xs
        sourceBadge.isLayoutMarginsRelativeArrangement = true
        sourceBadge.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: DSSpacing.xs,
            leading: DSSpacing.sm,
            bottom: DSSpacing.xs,
            trailing: DSSpacing.sm
        )
        sourceBadge.addArrangedSubview(sourceIcon)
        sourceBadge.addArrangedSubview(sourceLabel)
        sourceBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rowStack = UIStackView(
            arrangedSubviews: [coverContainer, informationStack, sourceBadge]
        )
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = DSSpacing.md
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: DSSpacing.lg
            ),
            rowStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -DSSpacing.lg
            ),
            rowStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: DSSpacing.sm
            ),
            rowStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -DSSpacing.sm
            ),
            coverContainer.widthAnchor.constraint(
                equalToConstant: DSLayout.searchResultCoverWidth
            ),
            coverContainer.heightAnchor.constraint(
                equalToConstant: DSLayout.searchResultCoverHeight
            ),
            coverImageView.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
            coverTitleLabel.leadingAnchor.constraint(
                equalTo: coverContainer.leadingAnchor,
                constant: DSSpacing.sm
            ),
            coverTitleLabel.trailingAnchor.constraint(
                equalTo: coverContainer.trailingAnchor,
                constant: -DSSpacing.sm
            ),
            coverTitleLabel.topAnchor.constraint(
                equalTo: coverContainer.topAnchor,
                constant: DSSpacing.sm
            ),
            audiobookBadge.widthAnchor.constraint(
                equalToConstant: DSLayout.searchResultAudiobookBadgeSize
            ),
            audiobookBadge.heightAnchor.constraint(
                equalToConstant: DSLayout.searchResultAudiobookBadgeSize
            ),
            audiobookBadge.trailingAnchor.constraint(
                equalTo: coverContainer.trailingAnchor,
                constant: -DSSpacing.xs
            ),
            audiobookBadge.bottomAnchor.constraint(
                equalTo: coverContainer.bottomAnchor,
                constant: -DSSpacing.xs
            ),
        ])
    }

    private func applyTypography() {
        let postScriptName = GlobalAppTypography.activePostScriptName
        titleLabel.font = GlobalAppTypography.uiFont(
            .headline,
            postScriptName: postScriptName,
            compatibleWith: traitCollection
        )
        authorLabel.font = GlobalAppTypography.uiFont(
            .caption,
            postScriptName: postScriptName,
            compatibleWith: traitCollection
        )
        introLabel.font = GlobalAppTypography.uiFont(
            .caption,
            postScriptName: postScriptName,
            compatibleWith: traitCollection
        )
        sourceLabel.font = GlobalAppTypography.uiFont(
            .caption2,
            postScriptName: postScriptName,
            weight: .medium,
            compatibleWith: traitCollection
        )
        coverTitleLabel.font = GlobalAppTypography.uiFont(
            .caption2,
            postScriptName: postScriptName,
            weight: .medium,
            compatibleWith: traitCollection
        )
        sourceIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: sourceLabel.font
        )
        audiobookBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: sourceLabel.font
        )
    }

    private func applyColors() {
        titleLabel.textColor = UIColor(DSColor.textPrimary)
        authorLabel.textColor = UIColor(DSColor.textSecondary)
        introLabel.textColor = UIColor(DSColor.textSecondary)
        coverTitleLabel.textColor = UIColor(DSColor.textSecondary)
        coverContainer.backgroundColor = UIColor(DSColor.surfaceTertiary)
        audiobookBadge.tintColor = UIColor(DSColor.textOnAccent)
        audiobookBadge.backgroundColor = UIColor(DSColor.accent)
    }

    private func loadCover(for row: IOS17SearchResultTableRow) {
        coverTask?.cancel()
        coverTask = nil

        if let cached = BookCoverLoader.cachedImage(for: row.coverURL) {
            showCover(cached, representedID: row.id)
            return
        }

        coverImageView.image = nil
        coverImageView.isHidden = true
        coverTitleLabel.isHidden = false
        guard !row.coverURL.isEmpty else { return }

        coverTask = Task { [weak self] in
            let headers = BookCoverLoader.headers(
                sourceBaseURL: nil,
                sourceHeaders: [:]
            )
            let image = await BookCoverLoader.loadImage(
                urlString: row.coverURL,
                headers: headers
            )
            guard !Task.isCancelled, let image else { return }
            self?.showCover(image, representedID: row.id)
        }
    }

    private func showCover(_ image: UIImage, representedID: UUID) {
        guard self.representedID == representedID else { return }
        coverImageView.image = image
        coverImageView.isHidden = false
        coverTitleLabel.isHidden = true
    }
}
