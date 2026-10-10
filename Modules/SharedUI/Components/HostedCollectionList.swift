import SwiftUI
import UIKit

// MARK: - Why this is UIKit
//
// SwiftUI `List` calls its `ForEach` closure for every element on every update — measured
// twice per element with 3,000 book sources (see the note in `BookSourceRowViews.swift`).
// That is fine for a few hundred rows and fatal for tens of thousands: opening 書源管理 with
// 50,000 sources built 100,000 row values up front and grew the process by 5.3 GB in a
// Debug simulator run (10,000 sources: +745 MB), and every checkbox tap, keystroke or
// validation publication repeated the whole pass.
//
// This is a `UICollectionView` list whose cells host the *same SwiftUI rows* through
// `UIHostingConfiguration`, so SwiftUI only ever builds the rows that are on screen. It is
// the one path for these screens on every iOS version — not a large-list fallback.

/// A request to bring one item into view. `serial` distinguishes repeated requests for the
/// same item (pin a source, move it, pin it again).
struct HostedCollectionListScrollRequest<Item: Hashable>: Equatable {
    let item: Item
    let serial: Int
}

/// A plain list that builds only the visible rows.
///
/// - `items` is the row order. When it changes, the list reloads (or animates the
///   difference when `animatesItemChanges` is set and Reduce Motion is off).
/// - `contentVersion` is bumped by the owner when something a row *shows* changed without
///   the row order changing — a selection, a toggle, a validation badge. Only the rows
///   on screen are rebuilt.
struct HostedCollectionList<Item: Hashable, Row: View>: UIViewControllerRepresentable {
    let items: [Item]
    let contentVersion: Int
    var animatesItemChanges = false
    var scrollRequest: HostedCollectionListScrollRequest<Item>? = nil
    /// Whether a separator is drawn under the item.
    let showsSeparator: (Item) -> Bool
    /// Items that keep the cell's system layout margins (a `List` row's default insets);
    /// every other row spans the full width and pads itself.
    var usesSystemMargins: (Item) -> Bool = { _ in false }
    /// Items drawn on the 毛玻璃／分組卡片 surface across the full cell — what a `List`
    /// section's `interfaceSectionSurface()` painted behind its rows.
    var drawsCellSurface: (Item) -> Bool = { _ in false }
    @ViewBuilder let row: (Item) -> Row

    func makeUIViewController(context: Context) -> HostedCollectionListController<Item, Row> {
        HostedCollectionListController(
            row: row, showsSeparator: showsSeparator, usesSystemMargins: usesSystemMargins,
            drawsCellSurface: drawsCellSurface)
    }

    func updateUIViewController(
        _ controller: HostedCollectionListController<Item, Row>,
        context: Context
    ) {
        controller.update(
            items: items,
            contentVersion: contentVersion,
            animated: animatesItemChanges && !context.environment.accessibilityReduceMotion,
            row: row,
            showsSeparator: showsSeparator,
            usesSystemMargins: usesSystemMargins,
            drawsCellSurface: drawsCellSurface
        )
        if let scrollRequest {
            controller.scroll(
                to: scrollRequest,
                animated: !context.environment.accessibilityReduceMotion
            )
        }
    }
}

@MainActor
final class HostedCollectionListController<Item: Hashable, Row: View>: UIViewController {
    /// A data item can appear more than once; diffable identity belongs to its
    /// occurrence in the list, not to the shared underlying value.
    private struct RowID: Hashable {
        let item: Item
        let occurrence: Int
    }
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, RowID>!
    private var items: [Item] = []
    private var contentVersion: Int?
    private var lastScrollSerial: Int?
    private var row: (Item) -> Row
    private var showsSeparator: (Item) -> Bool
    private var usesSystemMargins: (Item) -> Bool
    private var drawsCellSurface: (Item) -> Bool
    /// How many times a row view was built — the evidence that only visible rows are.
    private(set) var rowBuildCount = 0

    init(
        row: @escaping (Item) -> Row,
        showsSeparator: @escaping (Item) -> Bool,
        usesSystemMargins: @escaping (Item) -> Bool = { _ in false },
        drawsCellSurface: @escaping (Item) -> Bool = { _ in false }
    ) {
        self.row = row
        self.showsSeparator = showsSeparator
        self.usesSystemMargins = usesSystemMargins
        self.drawsCellSurface = drawsCellSurface
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
            var separator = separator
            separator.topSeparatorVisibility = .hidden
            guard let self, let item = self.dataSource.itemIdentifier(for: indexPath)?.item else {
                separator.bottomSeparatorVisibility = .hidden
                return separator
            }
            separator.bottomSeparatorVisibility = self.showsSeparator(item) ? .visible : .hidden
            return separator
        }
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)

        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // Rows own their controls (checkbox, switch, menus); a cell-level selection
        // highlight would fire on every tap between them.
        collectionView.allowsSelection = false
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)
        self.collectionView = collectionView

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, with: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, RowID>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: item.item)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The navigation bar tracks one scroll view for its scroll-edge appearance. With
        // the list in UIKit, SwiftUI has none to hand it, so name this one on the
        // navigation stack's page.
        var page: UIViewController? = self
        while let candidate = page, let parent = candidate.parent, !(parent is UINavigationController) {
            page = parent
        }
        page?.setContentScrollView(collectionView, for: .top)
    }

    func update(
        items newItems: [Item],
        contentVersion newVersion: Int,
        animated: Bool,
        row: @escaping (Item) -> Row,
        showsSeparator: @escaping (Item) -> Bool,
        usesSystemMargins: @escaping (Item) -> Bool,
        drawsCellSurface: @escaping (Item) -> Bool
    ) {
        loadViewIfNeeded()
        self.row = row
        self.showsSeparator = showsSeparator
        self.usesSystemMargins = usesSystemMargins
        self.drawsCellSurface = drawsCellSurface

        if newItems != items || contentVersion == nil {
            let startedAt = SourcePerfTrace.now
            items = newItems
            contentVersion = newVersion
            var occurrences: [Item: Int] = [:]
            let rowIDs = newItems.map { item in
                let occurrence = occurrences[item, default: 0]
                occurrences[item] = occurrence + 1
                return RowID(item: item, occurrence: occurrence)
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, RowID>()
            snapshot.appendSections([0])
            snapshot.appendItems(rowIDs)
            if animated {
                dataSource.apply(snapshot, animatingDifferences: true)
                // An animated apply only inserts, deletes and moves; a row that moved *and*
                // changed (置頂 moves the row and adds its pin icon) keeps its old content.
                reconfigureVisibleRows()
            } else {
                dataSource.applySnapshotUsingReloadData(snapshot)
            }
            SourcePerfTrace.record(
                "hostedList.apply", "\(newItems.count) rows animated=\(animated)",
                since: startedAt, thresholdMs: 4)
            return
        }
        guard newVersion != contentVersion else { return }
        contentVersion = newVersion
        reconfigureVisibleRows()
    }

    func scroll(to request: HostedCollectionListScrollRequest<Item>, animated: Bool) {
        guard request.serial != lastScrollSerial else { return }
        lastScrollSerial = request.serial
        guard let indexPath = dataSource.indexPath(for: RowID(item: request.item, occurrence: 0)) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
    }

    /// Rebuilds only the cells on screen. Cells resize themselves when their content
    /// changes (`selfSizingInvalidation` is on by default since iOS 16).
    private func reconfigureVisibleRows() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = dataSource.itemIdentifier(for: indexPath)?.item,
                  let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
            else { continue }
            configure(cell, with: item)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, with item: Item) {
        rowBuildCount += 1
        let surface = drawsCellSurface(item)
        // The cell's background belongs to the hosting configuration: its `.background` is
        // installed as the cell's background configuration. Never assign one here — `.clear()`
        // after the content hid every row's surface, and swapping it on a recycled cell
        // tore the hosted background view out from under UIKit, which throws from
        // `_UISystemBackgroundView` (it crashed fast scrolling through 50,000 sources).
        // Rows without a surface get a clear background instead, and every cell keeps one
        // background type, so a recycled cell updates its hosted views in place.
        let configuration = UIHostingConfiguration { row(item) }
            .background {
                if surface {
                    HostedListCellSurface()
                } else {
                    Color.clear
                }
            }
        cell.contentConfiguration = usesSystemMargins(item)
            ? configuration
            : configuration.margins(.all, 0)
    }
}

/// The surface a `List` section card sat on (`interfaceSectionSurface()`), drawn across a
/// whole hosted cell.
private struct HostedListCellSurface: View {
    var body: some View {
        Color.clear.interfaceCardSurface()
    }
}

#Preview("大量列") {
    HostedCollectionList(
        items: Array(0..<50_000),
        contentVersion: 0,
        showsSeparator: { _ in true },
        drawsCellSurface: { $0 % 10 != 0 }
    ) { index in
        Text(index % 10 == 0 ? "分組 \(index / 10)" : "來源配置 \(index)")
            .font(index % 10 == 0 ? DSFont.headline : DSFont.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
    }
    .background(DSColor.groupedBackground)
}
