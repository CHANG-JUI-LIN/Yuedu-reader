import Combine
import UIKit

/// 把 `CoreTextScrollEngine` 渲染成垂直 UITableView 的 view controller。
final class CoreTextScrollViewController: UIViewController {

    // MARK: - Inputs

    private let engine: CoreTextScrollEngine
    private var horizontalInset: CGFloat
    private var verticalInset: CGFloat
    /// 進度回呼：可見的最上 chunk 對應的 (chapter, charOffset, percentage)
    var onProgressChange: ((Int, Int, Double) -> Void)?
    /// 點擊：通知外部切換頂底欄
    var onTap: (() -> Void)?

    // MARK: - State

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var cancellables: Set<AnyCancellable> = []
    private var pendingInitialScroll: (chapter: Int, charOffset: Int)?
    private var hasAppliedInitialScroll = false
    private var hasKickedOffEngine = false
    private var pendingInitialChapter: Int = 0
    private var pendingInitialCharOffset: Int = 0
    private var displayedCount: Int = 0

    // 文字選取
    private var selectionChapter: Int?
    private var anchorIndex: Int?
    private var focusIndex: Int?
    private var selectedText: String?

    // MARK: - Init

    init(engine: CoreTextScrollEngine,
         horizontalInset: CGFloat,
         verticalInset: CGFloat,
         backgroundColor: UIColor) {
        self.engine = engine
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = backgroundColor
        tableView.backgroundColor = backgroundColor
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.contentInsetAdjustmentBehavior = .never
        // 由 heightForRowAt 直接給精確高度，不走 self-sizing
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.register(CoreTextChunkCell.self, forCellReuseIdentifier: CoreTextChunkCell.reuseIdentifier)
        tableView.contentInset = UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.cancelsTouchesInView = false
        tableView.addGestureRecognizer(longPress)

        bindEngine()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copy(_:)) && (selectedText?.isEmpty == false)
    }

    @objc override func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    @objc private func handleTap() {
        if anchorIndex != nil || focusIndex != nil {
            clearSelection()
            return
        }
        onTap?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: tableView)
        switch gesture.state {
        case .began:
            guard let (cell, chunk, localPoint) = hitTestChunk(at: point) else {
                clearSelection()
                return
            }
            guard let idx = chunk.stringIndex(atLocalPoint: localPoint) else { return }
            selectionChapter = chunk.chapterIndex
            anchorIndex = idx
            focusIndex = idx
            refreshSelectionOverlays()
            _ = cell // 抑制未使用警告
        case .changed:
            guard let chapter = selectionChapter,
                  let (_, chunk, localPoint) = hitTestChunk(at: point),
                  chunk.chapterIndex == chapter,
                  let idx = chunk.stringIndex(atLocalPoint: localPoint) else { return }
            focusIndex = idx
            refreshSelectionOverlays()
        case .ended:
            updateSelectedText()
            guard let text = selectedText, !text.isEmpty else { clearSelection(); return }
            becomeFirstResponder()
            let menuRect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
            let viewPoint = tableView.convert(menuRect.origin, to: view)
            UIMenuController.shared.showMenu(
                from: view,
                rect: CGRect(origin: viewPoint, size: menuRect.size)
            )
            _ = text
        case .cancelled, .failed:
            clearSelection()
        default:
            break
        }
    }

    private func hitTestChunk(at pointInTableView: CGPoint) -> (cell: CoreTextChunkCell, chunk: CoreTextChunk, localPoint: CGPoint)? {
        guard let path = tableView.indexPathForRow(at: pointInTableView),
              let cell = tableView.cellForRow(at: path) as? CoreTextChunkCell,
              let chunk = cell.currentChunk else { return nil }
        let local = tableView.convert(pointInTableView, to: cell.drawView)
        return (cell, chunk, local)
    }

    private var currentSelectionRange: NSRange? {
        guard let a = anchorIndex, let f = focusIndex else { return nil }
        let start = min(a, f)
        let end = max(a, f)
        return NSRange(location: start, length: end - start + 1)
    }

    private func refreshSelectionOverlays() {
        let chapter = selectionChapter
        let range = currentSelectionRange
        for cell in tableView.visibleCells.compactMap({ $0 as? CoreTextChunkCell }) {
            if let chapter = chapter {
                cell.applySelection(chapterIndex: chapter, chapterRange: range)
            } else {
                cell.applySelection(chapterIndex: -1, chapterRange: nil)
            }
        }
    }

    private func updateSelectedText() {
        guard let chapter = selectionChapter,
              let range = currentSelectionRange,
              range.length > 0 else { selectedText = nil; return }
        // 章節層級的 attributedString 與所有同章 chunk 共享，取任一可見 chunk 即可
        if let chunk = engine.chunks.first(where: { $0.chapterIndex == chapter }) {
            let s = chunk.attributedString
            guard range.location + range.length <= s.length else { selectedText = nil; return }
            selectedText = (s.string as NSString).substring(with: range)
        } else {
            selectedText = nil
        }
    }

    private func clearSelection() {
        selectionChapter = nil
        anchorIndex = nil
        focusIndex = nil
        selectedText = nil
        refreshSelectionOverlays()
        if #available(iOS 13.0, *) {
            UIMenuController.shared.hideMenu()
        } else {
            UIMenuController.shared.setMenuVisible(false, animated: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        kickoffEngineIfNeeded()
    }

    private func kickoffEngineIfNeeded() {
        guard !hasKickedOffEngine else { return }
        let width = view.bounds.width - 2 * horizontalInset
        guard width > 0 else { return }
        hasKickedOffEngine = true
        let chapter = pendingInitialChapter
        print("[ScrollEngine] kickoff(VC) width=\(width) chapter=\(chapter)")
        Task { [weak self] in
            guard let self = self else { return }
            await self.engine.start(initialChapter: chapter, contentWidth: width)
        }
    }

    // MARK: - Engine binding

    private func bindEngine() {
        engine.events
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handle(event: event)
            }
            .store(in: &cancellables)

        // 初次：若 chunks 已有值（例如 reuse engine）也要同步
        displayedCount = engine.chunks.count
        if !engine.chunks.isEmpty {
            tableView.reloadData()
        }
    }

    private func handle(event: CoreTextScrollEngine.Event) {
        switch event {
        case .reset:
            displayedCount = engine.chunks.count
            tableView.reloadData()
        case .insertedAtBottom(let count, _):
            let total = engine.chunks.count
            let expectedOld = max(0, total - count)
            // 不信事件給的 count，用實際 displayedCount 與 chunks.count 的差來算，避免 race
            let actualOld = displayedCount
            guard actualOld == expectedOld else {
                // 不一致：直接 reload 保險
                displayedCount = total
                tableView.reloadData()
                applyPendingInitialScrollIfPossible()
                return
            }
            let paths = (actualOld..<total).map { IndexPath(row: $0, section: 0) }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                displayedCount = total
                tableView.insertRows(at: paths, with: .none)
                tableView.endUpdates()
            }
        case .insertedAtTop(let count, let addedHeight, _):
            let total = engine.chunks.count
            let actualOld = displayedCount
            guard actualOld + count == total else {
                displayedCount = total
                tableView.reloadData()
                applyPendingInitialScrollIfPossible()
                return
            }
            let beforeOffset = tableView.contentOffset
            let paths = (0..<count).map { IndexPath(row: $0, section: 0) }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                displayedCount = total
                tableView.insertRows(at: paths, with: .none)
                tableView.endUpdates()
                tableView.setContentOffset(
                    CGPoint(x: beforeOffset.x, y: beforeOffset.y + addedHeight),
                    animated: false
                )
            }
        }

        applyPendingInitialScrollIfPossible()
    }

    // MARK: - Public

    /// 初始定位（章節 + 字元偏移），須在引擎切完該章後才生效
    func setInitialPosition(chapter: Int, charOffset: Int) {
        pendingInitialScroll = (chapter, charOffset)
        pendingInitialChapter = chapter
        applyPendingInitialScrollIfPossible()
    }

    /// 設定變動：水平/垂直 inset 變了就重排
    func updateInsets(horizontal: CGFloat, vertical: CGFloat) {
        let widthChanged = abs(horizontal - horizontalInset) > 0.5
        horizontalInset = horizontal
        verticalInset = vertical
        tableView.contentInset = UIEdgeInsets(top: vertical, left: 0, bottom: vertical, right: 0)
        if widthChanged {
            requestReslice(at: visibleTopChapter())
        } else {
            displayedCount = engine.chunks.count
            tableView.reloadData()
        }
    }

    /// 重切（字級 / 行高 / 字距 / 段距 / 主題變動）
    func requestReslice(at chapter: Int) {
        let width = view.bounds.width - 2 * horizontalInset
        guard width > 0 else { return }
        Task { [weak self] in
            guard let self = self else { return }
            self.hasAppliedInitialScroll = false
            self.pendingInitialScroll = (chapter, 0)
            await self.engine.reslice(restoreAt: chapter, contentWidth: width)
        }
    }

    private func visibleTopChapter() -> Int {
        let chunks = engine.chunks
        guard !chunks.isEmpty else { return pendingInitialChapter }
        let y = max(0, tableView.contentOffset.y + tableView.adjustedContentInset.top)
        if let path = tableView.indexPathForRow(at: CGPoint(x: 0, y: y)),
           path.row < chunks.count {
            return chunks[path.row].chapterIndex
        }
        return chunks.first?.chapterIndex ?? 0
    }

    func updateBackgroundColor(_ color: UIColor) {
        view.backgroundColor = color
        tableView.backgroundColor = color
    }

    private func applyPendingInitialScrollIfPossible() {
        guard !hasAppliedInitialScroll, let target = pendingInitialScroll else { return }
        guard let row = engine.chunkIndex(forChapter: target.chapter, charOffset: target.charOffset) else { return }
        guard row < engine.chunks.count else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
            self.hasAppliedInitialScroll = true
        }
    }
}

// MARK: - UITableViewDataSource / Delegate

extension CoreTextScrollViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayedCount
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < engine.chunks.count else { return 0 }
        let chunk = engine.chunks[indexPath.row]
        return chunk.height + chapterTopSpacing(for: indexPath.row)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CoreTextChunkCell.reuseIdentifier, for: indexPath)
        if let chunkCell = cell as? CoreTextChunkCell, indexPath.row < engine.chunks.count {
            chunkCell.bind(
                chunk: engine.chunks[indexPath.row],
                horizontalInset: horizontalInset,
                topSpacing: chapterTopSpacing(for: indexPath.row)
            )
        }
        return cell
    }

    /// 跨章節時的視覺空白（pt）。第一個 chunk 不加；同章接續不加。
    private func chapterTopSpacing(for row: Int) -> CGFloat {
        guard row > 0, row < engine.chunks.count else { return 0 }
        let curr = engine.chunks[row].chapterIndex
        let prev = engine.chunks[row - 1].chapterIndex
        return curr != prev ? CoreTextScrollViewController.chapterGap : 0
    }

    static let chapterGap: CGFloat = 56

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < engine.chunks.count else { return }
        engine.chunks[indexPath.row].materializeFrameIfNeeded()
        // 補上選取反白（捲到新 cell 時）
        if let chunkCell = cell as? CoreTextChunkCell, let chapter = selectionChapter {
            chunkCell.applySelection(chapterIndex: chapter, chapterRange: currentSelectionRange)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let chunks = engine.chunks
        guard !chunks.isEmpty else { return }

        // 預載：剩餘 < 1.5 螢幕 → 載下一章
        let remaining = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        if remaining < scrollView.bounds.height * 1.5,
           let lastChapter = chunks.last?.chapterIndex {
            engine.ensureChapterAhead(of: lastChapter)
        }
        if scrollView.contentOffset.y < scrollView.bounds.height * 1.5,
           let firstChapter = chunks.first?.chapterIndex {
            engine.ensureChapterBehind(of: firstChapter)
        }

        // 進度：取最上方可見 cell
        let visibleY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        if let topPath = tableView.indexPathForRow(at: CGPoint(x: 0, y: max(0, visibleY))),
           topPath.row < chunks.count {
            let chunk = chunks[topPath.row]
            let total = max(1, engine.chapterCount)
            let pct = Double(chunk.chapterIndex) / Double(total - 1 == 0 ? 1 : total - 1)
            onProgressChange?(chunk.chapterIndex, chunk.charRange.location, min(1, max(0, pct)))
        }
    }
}
