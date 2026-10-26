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

    /// A saved library's book, its cover asked for as the SwiftUI row's `HomeCoverArtwork`
    /// asks for it.
    init(libraryMatch match: LibrarySearchMatch) {
        switch match.card.cover {
        case .reference(.remote(let url, let headers), let session):
            self.init(id: match.id, content: match.rowContent, coverURL: url.absoluteString,
                      remoteCover: IOS17RemoteCover(headers: headers, session: session))
        case .reference(.copyFile(let path), _):
            self.init(id: match.id, content: match.rowContent, coverURL: "",
                      shelfCover: IOS17ShelfCover(own: .indexedCover(path: path), usesCatalogCover: false, defaultCover: nil))
        case .reference(.generated, _), .reference(nil, _), .shelf, .placeholder:
            self.init(id: match.id, content: match.rowContent, coverURL: "")
        }
    }
}

extension IOS17SearchResultTableRow {
    /// A work of the tab root's one list (unified search 4c-3): its cover as its lead's part
    /// asks for it, its words the work's.
    @MainActor
    init(unified row: UnifiedSearchRow, colorScheme: ColorScheme, filledCover: (ReadingBook) -> String?) {
        let base: IOS17SearchResultTableRow = switch row.lead {
        case .shelf(let match): IOS17SearchResultTableRow(shelfBook: match.book, colorScheme: colorScheme,
                                                          filledCover: filledCover(match.book))
        case .library(let match): IOS17SearchResultTableRow(libraryMatch: match)
        case .bookSource(let book): IOS17SearchResultTableRow(searchBook: book)
        case .publicLibrary: IOS17SearchResultTableRow(id: row.id, content: row.content, coverURL: "")
        }
        self.init(id: row.id, content: row.content, coverURL: base.coverURL, shelfCover: base.shelfCover,
                  remoteCover: base.remoteCover)
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
    /// A work of the tab root's list, by its row's id.
    var onSelectWork: (UUID) -> Void = { _ in }

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
            onSelectWork: onSelectWork
        )
    }
}

@MainActor
final class IOS17SearchResultTableViewController: UITableViewController {
    fileprivate enum Section: Hashable {
        /// The sources' results, where the page is not the tab's root.
        case results
        /// The tab root's status line above its works.
        case leading
        /// The tab root's works of one kind, under its header (search 9c).
        case group(ContentKind)
        /// The status lines under the works.
        case trailing
    }

    fileprivate enum Item: Hashable {
        case result(UUID)
        case work(UUID)
        /// A status line of the works' list, by its place in `statusLines`.
        case notice(Int)
    }

    private static let resultCellIdentifier = "IOS17SearchResultCell"
    private static let noticeCellIdentifier = "IOS17SearchNoticeCell"
    private static let headerIdentifier = "IOS17SearchGroupHeader"

    private var currentContent: IOS17SearchResultTableContent?
    private var rowsByID: [UUID: IOS17SearchResultTableRow] = [:]
    /// The works' status lines in table order: the leading one, then the trailing ones.
    private var statusLines: [String] = []
    /// Each group's header.
    private var groupTitles: [ContentKind: String] = [:]
    private var onSelect: (UUID) -> Void = { _ in }
    private var onSelectWork: (UUID) -> Void = { _ in }
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
        tableView.separatorColor = DSUIColor.separator
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
        tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: Self.headerIdentifier)
        // Only the groups have headers; the status sections sit flush.
        tableView.sectionHeaderTopPadding = 0
        configureDataSource()
    }

    @inline(never)
    func update(
        content: IOS17SearchResultTableContent,
        onSelect: @escaping (UUID) -> Void,
        onSelectWork: @escaping (UUID) -> Void
    ) {
        loadViewIfNeeded()
        self.onSelect = onSelect
        self.onSelectWork = onSelectWork
        guard content.requiresReload(comparedTo: currentContent) else { return }

        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            SourcePerfTrace.record(
                "search.iOS17.nativeTableApply",
                "\(content.rows.count) rows works=\(content.works?.rows.count ?? -1)",
                since: startedAt,
                thresholdMs: 4
            )
        }
        currentContent = content
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let works = content.works {
            rowsByID = Dictionary(works.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            statusLines = [works.status.leading].compactMap { $0 } + works.status.trailing
            groupTitles = Dictionary(works.groups.map { ($0.kind, $0.title) }, uniquingKeysWith: { first, _ in first })
            let leadingCount = works.status.leading == nil ? 0 : 1
            if leadingCount == 1 {
                snapshot.appendSections([.leading])
                snapshot.appendItems([.notice(0)], toSection: .leading)
            }
            var seen = Set<UUID>()
            for group in works.groups {
                let items = group.rows.filter { seen.insert($0.id).inserted }.map { Item.work($0.id) }
                guard !items.isEmpty else { continue }
                snapshot.appendSections([.group(group.kind)])
                snapshot.appendItems(items, toSection: .group(group.kind))
            }
            let trailing = works.status.trailing.indices.map { Item.notice(leadingCount + $0) }
            if !trailing.isEmpty {
                snapshot.appendSections([.trailing])
                snapshot.appendItems(trailing, toSection: .trailing)
            }
        } else {
            rowsByID = Dictionary(content.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            statusLines = []
            snapshot.appendSections([.results])
            snapshot.appendItems(content.rows.map { .result($0.id) }, toSection: .results)
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .result(let id):
            onSelect(id)
        case .work(let id):
            onSelectWork(id)
        case .notice:
            break
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = groupTitle(section),
              let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: Self.headerIdentifier) else { return nil }
        var configuration = UIListContentConfiguration.plainHeader()
        configuration.text = title
        configuration.textProperties.font = font(.headline)
        configuration.textProperties.color = DSUIColor.textPrimary
        configuration.directionalLayoutMargins.leading = DSLayout.searchListHorizontalInset
        header.contentConfiguration = configuration
        // One element VoiceOver reads as a heading, as SwiftUI's section header is.
        header.isAccessibilityElement = true
        header.accessibilityLabel = title
        header.accessibilityTraits = .header
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        groupTitle(section) == nil ? 0 : UITableView.automaticDimension
    }

    /// The header of a group's section; nil for the status sections.
    private func groupTitle(_ section: Int) -> String? {
        guard case .group(let kind) = dataSource.sectionIdentifier(for: section) else { return nil }
        return groupTitles[kind]
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .notice, nil: false
        default: true
        }
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Section, Item>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case .result(let id), .work(let id):
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

            case .notice(let index):
                var configuration = UIListContentConfiguration.cell()
                configuration.text = self.statusLines.indices.contains(index) ? self.statusLines[index] : nil
                configuration.textProperties.color = DSUIColor.textSecondary
                configuration.textProperties.font = self.font(.subheadline)
                return self.plainCell(Self.noticeCellIdentifier, configuration: configuration, traits: .staticText)
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
            attributes: [.font: titleFont, .foregroundColor: DSUIColor.textPrimary]
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
                value: DSUIColor.textSecondary,
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
        authorLabel.textColor = DSUIColor.textPrimary
        detailLabel.textColor = DSUIColor.textSecondary
        coverImageView.backgroundColor = DSUIColor.surfaceTertiary
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

        let session = row.remoteCover?.session
        if let cached = BookCoverLoader.cachedImage(for: row.coverURL, session: session) {
            showCover(cached, representedID: row.id)
            return
        }

        showsRemoteCover = false
        applyGeneratedCover()
        guard !row.coverURL.isEmpty else { return }

        coverTask = Task { [weak self] in
            let headers = BookCoverLoader.headers(
                sourceBaseURL: nil,
                sourceHeaders: row.remoteCover?.headers ?? [:]
            )
            let image = await BookCoverLoader.loadImage(
                urlString: row.coverURL,
                headers: headers,
                session: session
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
