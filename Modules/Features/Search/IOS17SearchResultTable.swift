import SwiftUI
import UIKit

extension IOS17SearchResultTableRow {
    @MainActor
    @inline(never)
    init(searchBook book: SearchBook) {
        self.init(
            id: book.id,
            content: SearchBookListRowContent(result: book),
            coverURL: book.coverUrl
        )
    }

    /// A shelf copy, its cover as the shelf decides it.
    @MainActor
    init(shelfBook book: ReadingBook, colorScheme: ColorScheme, filledCover: String?) {
        let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: colorScheme, filledCover: filledCover)
        self.init(
            id: book.id,
            content: SearchBookListRowContent(shelfBook: book),
            coverURL: plan.catalogFallback != nil ? (book.coverUrl ?? "") : "",
            shelfCover: IOS17ShelfCover(own: plan.ownCover, usesCatalogCover: plan.catalogFallback != nil,
                                        defaultCover: plan.defaultCover)
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
    var onSearchGutenberg: () -> Void = {}
    var onSelectWork: (String) -> Void = { _ in }
    var onSelectShelfBook: (UUID) -> Void = { _ in }

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
            onLoadMore: onLoadMore,
            onSearchGutenberg: onSearchGutenberg,
            onSelectWork: onSelectWork,
            onSelectShelfBook: onSelectShelfBook
        )
    }
}

@MainActor
final class IOS17SearchResultTableViewController: UITableViewController {
    fileprivate enum Section: Hashable {
        case shelf
        case results
        case library
    }

    fileprivate enum Item: Hashable {
        case shelfBook(UUID)
        case result(UUID)
        case loadMore
        case notice
        case gutenbergSearch
        case work(String)
    }

    private static let resultCellIdentifier = "IOS17SearchResultCell"
    private static let loadMoreCellIdentifier = "IOS17SearchLoadMoreCell"
    private static let noticeCellIdentifier = "IOS17SearchNoticeCell"
    private static let libraryCellIdentifier = "IOS17SearchLibraryCell"

    private var currentContent: IOS17SearchResultTableContent?
    private var rowsByID: [UUID: IOS17SearchResultTableRow] = [:]
    private var onSelect: (UUID) -> Void = { _ in }
    private var onLoadMore: () -> Void = {}
    private var onSearchGutenberg: () -> Void = {}
    private var onSelectWork: (String) -> Void = { _ in }
    private var onSelectShelfBook: (UUID) -> Void = { _ in }
    private var shelfRowsByID: [UUID: IOS17SearchResultTableRow] = [:]
    private var worksByID: [String: IOS17SearchLibrarySection.Work] = [:]
    private var dataSource: IOS17SearchResultDataSource!

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
        // Separators run from the text to the trailing margin, as the SwiftUI row's do.
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: DSLayout.searchListHorizontalInset + DSLayout.searchListCoverWidth
                + DSLayout.searchListCoverTextSpacing,
            bottom: 0,
            right: DSLayout.searchListHorizontalInset
        )
        tableView.estimatedRowHeight =
            DSLayout.searchListCoverHeight + DSSpacing.sm * 2
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
        onLoadMore: @escaping () -> Void,
        onSearchGutenberg: @escaping () -> Void,
        onSelectWork: @escaping (String) -> Void,
        onSelectShelfBook: @escaping (UUID) -> Void
    ) {
        loadViewIfNeeded()
        self.onSelectShelfBook = onSelectShelfBook
        self.onSelect = onSelect
        self.onLoadMore = onLoadMore
        self.onSearchGutenberg = onSearchGutenberg
        self.onSelectWork = onSelectWork
        guard content.requiresReload(comparedTo: currentContent) else { return }

        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            SourcePerfTrace.record(
                "search.iOS17.nativeTableApply",
                "\(content.rows.count) rows shelf=\(content.shelf.count) loadMore=\(content.showsLoadMore) works=\(content.library?.works.count ?? -1)",
                since: startedAt,
                thresholdMs: 4
            )
        }
        currentContent = content
        rowsByID = Dictionary(uniqueKeysWithValues: content.rows.map { ($0.id, $0) })
        shelfRowsByID = Dictionary(content.shelf.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        worksByID = Dictionary((content.library?.works ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !content.shelf.isEmpty {
            snapshot.appendSections([.shelf])
            var seen = Set<UUID>()
            snapshot.appendItems(content.shelf.filter { seen.insert($0.id).inserted }.map { .shelfBook($0.id) },
                                 toSection: .shelf)
        }
        let sourceItems = content.rows.map { Item.result($0.id) }
            + (content.showsLoadMore ? [.loadMore] : [])
            + (content.sourcesNotice != nil && content.rows.isEmpty ? [.notice] : [])
        if !sourceItems.isEmpty || (content.library == nil && content.shelf.isEmpty) {
            snapshot.appendSections([.results])
            snapshot.appendItems(sourceItems, toSection: .results)
        }
        if let library = content.library {
            snapshot.appendSections([.library])
            var seen = Set<String>()
            let works = library.works.filter { seen.insert($0.id).inserted }
            snapshot.appendItems([.gutenbergSearch] + works.map { .work($0.id) }, toSection: .library)
        }
        // Headers name the parts only when more than one can be there.
        dataSource.titlesSections = content.library != nil || !content.shelf.isEmpty
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .shelfBook(let id):
            onSelectShelfBook(id)
        case .result(let id):
            onSelect(id)
        case .loadMore:
            onLoadMore()
        case .notice:
            break
        case .gutenbergSearch:
            onSearchGutenberg()
        case .work(let id):
            onSelectWork(id)
        }
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .notice
    }

    private func configureDataSource() {
        dataSource = IOS17SearchResultDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case .shelfBook(let id):
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: Self.resultCellIdentifier,
                        for: indexPath
                    ) as? IOS17SearchResultTableCell,
                    let row = self.shelfRowsByID[id]
                else {
                    return nil
                }
                cell.configure(with: row)
                return cell

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

            case .notice:
                var configuration = UIListContentConfiguration.cell()
                configuration.text = self.currentContent?.sourcesNotice
                configuration.textProperties.color = UIColor(DSColor.textSecondary)
                configuration.textProperties.font = self.font(.subheadline)
                return self.plainCell(Self.noticeCellIdentifier, configuration: configuration, traits: .staticText)

            case .gutenbergSearch:
                var configuration = UIListContentConfiguration.cell()
                configuration.text = String(
                    format: localized("在 Project Gutenberg 搜尋「%@」"),
                    self.currentContent?.library?.query ?? ""
                )
                configuration.image = UIImage(systemName: "magnifyingglass")
                configuration.textProperties.color = .tintColor
                configuration.textProperties.font = self.font(.body)
                configuration.imageProperties.tintColor = .tintColor
                let cell = self.plainCell(Self.libraryCellIdentifier, configuration: configuration, traits: .button)
                cell.accessibilityIdentifier = "publicLibrary.searchGutenberg"
                return cell

            case .work(let id):
                var configuration = UIListContentConfiguration.subtitleCell()
                configuration.text = self.worksByID[id]?.title
                configuration.secondaryText = self.worksByID[id]?.author
                configuration.textProperties.color = UIColor(DSColor.textPrimary)
                configuration.textProperties.font = self.font(.body)
                configuration.secondaryTextProperties.color = UIColor(DSColor.textSecondary)
                configuration.secondaryTextProperties.font = self.font(.caption)
                configuration.textToSecondaryTextVerticalPadding = DSSpacing.xs
                return self.plainCell(Self.libraryCellIdentifier, configuration: configuration, traits: .button)
            }
        }
        dataSource.defaultRowAnimation = .none
    }
}

extension IOS17SearchResultTableViewController {
    fileprivate func font(_ style: GlobalAppTypography.Style) -> UIFont {
        GlobalAppTypography.uiFont(
            style,
            postScriptName: GlobalAppTypography.activePostScriptName,
            compatibleWith: traitCollection
        )
    }

    fileprivate func plainCell(
        _ identifier: String,
        configuration: UIListContentConfiguration,
        traits: UIAccessibilityTraits
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        cell.contentConfiguration = configuration
        cell.backgroundColor = .clear
        cell.accessibilityTraits = traits
        cell.accessibilityIdentifier = nil
        return cell
    }
}

/// Names the sources' and the libraries' parts when the table holds both.
@MainActor
fileprivate final class IOS17SearchResultDataSource: UITableViewDiffableDataSource<IOS17SearchResultTableViewController.Section, IOS17SearchResultTableViewController.Item> {
    var titlesSections = false

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard titlesSections else { return nil }
        switch sectionIdentifier(for: section) {
        case .shelf: return localized("書架")
        case .results: return localized("來源配置")
        case .library: return localized("公有書庫")
        case nil: return nil
        }
    }
}

@MainActor
private final class IOS17SearchResultTableCell: UITableViewCell {
    /// Carries the cover's shadow; the image inside it is clipped to the corners.
    private let coverContainer = UIView()
    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let detailLabel = UILabel()

    private var representedRow: IOS17SearchResultTableRow?
    private var titleFont = UIFont.preferredFont(forTextStyle: .footnote)
    private var tagFont = UIFont.preferredFont(forTextStyle: .caption2)
    private var coverTask: Task<Void, Never>?
    /// Title and author of the row on screen, so the generated cover can be
    /// redrawn when the appearance flips under a cell that is already showing it.
    private var generatedCoverSeed: (title: String, author: String)?
    /// True once the book's real artwork has arrived — a trait change must not
    /// paint the generated cover back over it.
    private var showsRemoteCover = false

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
        representedRow = nil
        coverTask?.cancel()
        coverTask = nil
        coverImageView.image = nil
        generatedCoverSeed = nil
        showsRemoteCover = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coverImageView.layer.cornerRadius = DSRadius.searchListCover
        coverContainer.layer.shadowPath = UIBezierPath(
            roundedRect: coverContainer.bounds,
            cornerRadius: DSRadius.searchListCover
        ).cgPath
    }

    @inline(never)
    func configure(with row: IOS17SearchResultTableRow) {
        representedRow = row
        applyTitle()
        authorLabel.text = row.content.author
        authorLabel.isHidden = row.content.author.isEmpty
        detailLabel.text = row.content.detail
        accessibilityLabel = row.content.accessibilityLabel
        loadCover(for: row)
    }

    /// The title with the grey tag flowing after it, as `SearchBookListRow` draws it.
    private func applyTitle() {
        guard let content = representedRow?.content else {
            titleLabel.attributedText = nil
            return
        }
        let title = NSMutableAttributedString(
            string: content.title,
            attributes: [.font: titleFont, .foregroundColor: UIColor(DSColor.textPrimary)]
        )
        if let tag = content.titleTag {
            let mark = SearchTitleTag.mark(
                for: tag,
                titleFont: titleFont,
                tagFont: tagFont,
                scale: traitCollection.displayScale
            )
            let attachment = NSTextAttachment(image: mark.image)
            attachment.bounds = CGRect(
                x: 0,
                y: mark.baselineOffset,
                width: mark.image.size.width,
                height: mark.image.size.height
            )
            title.append(NSAttributedString(string: " ", attributes: [.font: titleFont]))
            // A template attachment is tinted with the text colour of its run.
            let tagRun = NSMutableAttributedString(attachment: attachment)
            tagRun.addAttribute(
                .foregroundColor,
                value: UIColor(DSColor.textSecondary),
                range: NSRange(location: 0, length: tagRun.length)
            )
            title.append(tagRun)
        }
        titleLabel.attributedText = title
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
        coverContainer.layer.shadowOpacity = 1
        coverContainer.layer.shadowRadius = DSLayout.searchListCoverShadowRadius
        coverContainer.layer.shadowOffset = CGSize(width: 0, height: DSLayout.searchListCoverShadowY)
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerCurve = .continuous
        coverImageView.isAccessibilityElement = false
        coverContainer.addSubview(coverImageView)

        for label in [titleLabel, authorLabel, detailLabel] {
            label.isAccessibilityElement = false
        }

        let informationStack = UIStackView(
            arrangedSubviews: [titleLabel, authorLabel, detailLabel]
        )
        informationStack.axis = .vertical
        informationStack.alignment = .leading
        informationStack.spacing = 0

        let rowStack = UIStackView(
            arrangedSubviews: [coverContainer, informationStack]
        )
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = DSLayout.searchListCoverTextSpacing
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: DSLayout.searchListHorizontalInset
            ),
            rowStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -DSLayout.searchListHorizontalInset
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
                equalToConstant: DSLayout.searchListCoverWidth
            ),
            coverContainer.heightAnchor.constraint(
                equalToConstant: DSLayout.searchListCoverHeight
            ),
            coverImageView.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
        ])
    }

    private func applyTypography() {
        let postScriptName = GlobalAppTypography.activePostScriptName
        titleFont = GlobalAppTypography.uiFont(
            .footnote,
            postScriptName: postScriptName,
            weight: .semibold,
            compatibleWith: traitCollection
        )
        tagFont = GlobalAppTypography.uiFont(
            .caption2,
            postScriptName: postScriptName,
            weight: .semibold,
            compatibleWith: traitCollection
        )
        let footnote = GlobalAppTypography.uiFont(
            .footnote,
            postScriptName: postScriptName,
            compatibleWith: traitCollection
        )
        authorLabel.font = footnote
        detailLabel.font = footnote
        // Accessibility sizes wrap instead of cutting a title to two lines.
        let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = isAccessibilitySize ? 4 : 2
        authorLabel.numberOfLines = isAccessibilitySize ? 2 : 1
        detailLabel.numberOfLines = isAccessibilitySize ? 2 : 1
        applyTitle()
    }

    private func applyColors() {
        authorLabel.textColor = UIColor(DSColor.textPrimary)
        detailLabel.textColor = UIColor(DSColor.textSecondary)
        coverImageView.backgroundColor = UIColor(DSColor.surfaceTertiary)
        coverContainer.layer.shadowColor = UIColor(DSColor.searchListCoverShadow).cgColor
        // Light/dark flipped under a cell that is still on the generated cover.
        if !showsRemoteCover { applyGeneratedCover() }
        applyTitle()
    }

    private func loadCover(for row: IOS17SearchResultTableRow) {
        coverTask?.cancel()
        coverTask = nil
        generatedCoverSeed = (row.content.title, row.content.author)

        if let shelfCover = row.shelfCover {
            loadShelfCover(shelfCover, for: row)
            return
        }

        if let cached = BookCoverLoader.cachedImage(for: row.coverURL) {
            showCover(cached, representedID: row.id)
            return
        }

        showsRemoteCover = false
        applyGeneratedCover()
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

    /// A shelf copy's cover in the shelf's order (`BookshelfCoverArtwork.load`): its own
    /// artwork, then its catalog cover, then 預設封面, then the generated cover.
    private func loadShelfCover(_ cover: IOS17ShelfCover, for row: IOS17SearchResultTableRow) {
        showsRemoteCover = false
        applyGeneratedCover()
        guard let size = CoverPixelSize.fitting(
            pointSize: CGSize(width: DSLayout.searchListCoverWidth, height: DSLayout.searchListCoverHeight),
            scale: traitCollection.displayScale
        ) else { return }
        coverTask = Task { [weak self] in
            if let own = cover.own {
                switch await CoverImagePipeline.shared.image(for: CoverImageRequest(source: own, size: size)) {
                case .image(let image):
                    self?.showCover(image, representedID: row.id)
                    return
                case .unavailable:
                    break
                case .superseded, .cancelled:
                    return
                }
            }
            if cover.usesCatalogCover {
                guard !row.coverURL.isEmpty,
                      let image = await BookCoverLoader.loadImage(
                          urlString: row.coverURL,
                          headers: BookCoverLoader.headers(sourceBaseURL: nil, sourceHeaders: [:])
                      ) else { return }
                guard !Task.isCancelled else { return }
                self?.showCover(image, representedID: row.id)
                return
            }
            guard let fallback = cover.defaultCover,
                  case .image(let image) = await CoverImagePipeline.shared.image(for: CoverImageRequest(source: fallback, size: size)),
                  !Task.isCancelled else { return }
            self?.showCover(image, representedID: row.id)
        }
    }

    private func showCover(_ image: UIImage, representedID: UUID) {
        guard representedRow?.id == representedID else { return }
        coverImageView.image = image
        showsRemoteCover = true
    }

    /// What a result with no artwork shows: the same generated cover the shelf
    /// draws, rather than the grey title card this cell used to inline.
    private func applyGeneratedCover() {
        guard let seed = generatedCoverSeed else {
            coverImageView.image = nil
            return
        }
        let settings = GlobalSettings.shared
        coverImageView.image = GeneratedBookCoverRenderer.image(
            title: seed.title,
            author: seed.author,
            size: CGSize(
                width: DSLayout.searchListCoverWidth,
                height: DSLayout.searchListCoverHeight
            ),
            colorScheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light,
            drawsName: settings.defaultCoverDrawsBookName,
            drawsAuthor: settings.defaultCoverDrawsBookAuthor,
            scale: traitCollection.displayScale
        )
    }
}
