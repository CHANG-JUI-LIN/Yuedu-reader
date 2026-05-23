import Combine
import UIKit

/// UICollectionView-backed CoreText continuous reader.
/// Horizontal books scroll vertically; vertical-rl books scroll horizontally right-to-left.
final class CoreTextCollectionScrollViewController: UIViewController, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {

    static let chapterGap: CGFloat = 24
    static let verticalRTLChapterGap: CGFloat = 72

    private let engine: CoreTextScrollEngine
    private(set) var scrollAxis: CoreTextScrollAxis
    private var horizontalInset: CGFloat
    private var verticalInset: CGFloat
    var bottomMargin: CGFloat = 0
    var onProgressCommit: ((ScrollProgress) -> Void)?
    var onTap: (() -> Void)?
    var onInternalLinkTap: ((String) -> Void)?

    private let collectionView: UICollectionView
    private var cancellables: Set<AnyCancellable> = []
    private var pendingInitialScroll: (chapter: Int, charOffset: Int)?
    private var hasAppliedInitialScroll = false
    private var hasKickedOffEngine = false
    private var pendingInitialChapter: Int = 0
    private var displayedCount: Int = 0
    private var pendingProgress: ScrollProgress?
    private var lastWarmRow: Int?

    private var selectionChapter: Int?
    private var selectedText: String?
    private let interactor = TextSelectionInteractor()
    private var playbackHighlightText: String?
    private var textAnnotations: [CoreTextTextAnnotation] = []
    private lazy var tapGesture: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    init(
        engine: CoreTextScrollEngine,
        axis: CoreTextScrollAxis,
        horizontalInset: CGFloat,
        verticalInset: CGFloat,
        backgroundColor: UIColor
    ) {
        self.engine = engine
        self.scrollAxis = axis
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset

        let layout = CoreTextScrollFlowLayout()
        layout.scrollDirection = axis.collectionScrollDirection
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
        collectionView.semanticContentAttribute = axis.semanticContentAttribute
    }

    required init?(coder: NSCoder) { fatalError() }

    private lazy var editMenuInteraction: UIEditMenuInteraction = {
        UIEditMenuInteraction(delegate: self)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addInteraction(editMenuInteraction)

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(CoreTextChunkCollectionCell.self, forCellWithReuseIdentifier: CoreTextChunkCollectionCell.reuseIdentifier)
        collectionView.contentInset = contentInset

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.allowsSelection = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        collectionView.addGestureRecognizer(tapGesture)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(longPress)

        configureTapPriority()
        bindEngine()
    }

    // MARK: - Gesture priority

    /// Mirrors CoreTextPageView.configureTapPriority: makes all other tap recognizers
    /// in the view hierarchy require the link-tap gesture to fail first.
    private func configureTapPriority() {
        // Walk up from the collection view through its superview chain
        var current: UIView? = collectionView
        while let view = current {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer !== tapGesture,
                      recognizer is UITapGestureRecognizer
                else { continue }
                recognizer.require(toFail: tapGesture)
            }
            current = view.superview
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return true
    }

    override var canBecomeFirstResponder: Bool { return true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard selectedText?.isEmpty == false else { return false }
        return action == #selector(copy(_:)) || action == #selector(underlineSelection(_:))
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard selectedText?.isEmpty == false else { return nil }
        var actions = suggestedActions
        actions.append(UIAction(
            title: localized("下劃線"),
            image: nil,
            handler: { [weak self] _ in
                self?.requestUnderline(style: .underline, color: .yellow)
            }
        ))
        actions.append(UIAction(
            title: localized("螢光筆"),
            image: nil,
            handler: { [weak self] _ in
                self?.requestUnderline(style: .highlight, color: .yellow)
            }
        ))
        return UIMenu(children: actions)
    }

    @objc private func underlineSelection(_ sender: Any?) {
        requestUnderline(style: .underline, color: .yellow)
    }

    private func requestUnderline(style: AnnotationStyle, color: AnnotationColor) {
        guard let chapter = selectionChapter,
              let range = currentSelectionRange,
              range.length > 0
        else { return }
        NotificationCenter.default.post(
            name: .coreTextUnderlineSelectionRequested,
            object: self,
            userInfo: [
                "request": CoreTextUnderlineSelectionRequest(
                    position: CoreTextReadingPosition(spineIndex: chapter, charOffset: range.location),
                    length: range.length,
                    excerpt: selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    removesExistingUnderline: false,
                    style: style,
                    color: color
                )
            ]
        )
        clearSelection()
    }

    @objc override func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        kickoffEngineIfNeeded()
        applyPendingInitialScrollIfPossible()
    }

    func setInitialPosition(chapter: Int, charOffset: Int) {
        pendingInitialScroll = (chapter, charOffset)
        pendingInitialChapter = chapter
        applyPendingInitialScrollIfPossible()
    }

    func update(axis: CoreTextScrollAxis, horizontal: CGFloat, vertical: CGFloat, bottomMargin: CGFloat = 0) {
        let oldExtent = currentContentExtent
        let oldImageExtent = currentImageContentWidth
        let restoreChapter = visibleProgressChapter()
        let axisChanged = axis != scrollAxis
        scrollAxis = axis
        horizontalInset = horizontal
        verticalInset = vertical
        self.bottomMargin = bottomMargin
        collectionView.contentInset = contentInset
        collectionView.semanticContentAttribute = axis.semanticContentAttribute
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = axis.collectionScrollDirection
            layout.invalidateLayout()
        }

        let newExtent = currentContentExtent
        let newImageExtent = currentImageContentWidth
        if axisChanged
            || abs(newExtent - oldExtent) > 0.5
            || abs(newImageExtent - oldImageExtent) > 0.5 {
            requestReslice(at: restoreChapter)
        } else {
            displayedCount = engine.chunks.count
            engine.warmChunks(around: visibleProgressRow(), radius: 6)
            collectionView.reloadData()
        }
    }

    func updateBackgroundColor(_ color: UIColor) {
        view.backgroundColor = color
        collectionView.backgroundColor = color
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        textAnnotations = annotations
        // Refresh visible cells
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: indexPath) as? CoreTextChunkCollectionCell {
                cell.applyAnnotations(annotations)
            }
        }
    }

    func setPlaybackHighlight(text: String?) {
        playbackHighlightText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        for cell in collectionView.visibleCells.compactMap({ $0 as? CoreTextChunkCollectionCell }) {
            cell.applyPlaybackHighlight(text: playbackHighlightText)
        }
    }

    func requestReslice(at chapter: Int, charOffset: Int = 0) {
        let extent = currentContentExtent
        let imageExtent = currentImageContentWidth
        guard extent > 0 else { return }
        Task { [weak self] in
            guard let self = self else { return }
            self.hasAppliedInitialScroll = false
            self.pendingInitialScroll = (chapter, charOffset)
            await self.engine.reslice(
                restoreAt: chapter,
                contentWidth: extent,
                imageContentWidth: imageExtent
            )
        }
    }

    private var contentInset: UIEdgeInsets {
        switch scrollAxis {
        case .vertical:
            return UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0)
        case .horizontalRTL:
            return UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        }
    }

    private var currentContentExtent: CGFloat {
        switch scrollAxis {
        case .vertical:
            return max(0, view.bounds.width - 2 * horizontalInset)
        case .horizontalRTL:
            return max(0, view.bounds.height - verticalInset - bottomMargin)
        }
    }

    private var currentImageContentWidth: CGFloat {
        switch scrollAxis {
        case .vertical:
            return currentContentExtent
        case .horizontalRTL:
            return max(0, view.bounds.width - 2 * horizontalInset)
        }
    }

    private func kickoffEngineIfNeeded() {
        guard !hasKickedOffEngine else { return }
        let extent = currentContentExtent
        let imageExtent = currentImageContentWidth
        guard extent > 0 else { return }
        hasKickedOffEngine = true
        Task { [weak self] in
            guard let self = self else { return }
            await self.engine.start(
                initialChapter: self.pendingInitialChapter,
                contentWidth: extent,
                imageContentWidth: imageExtent
            )
        }
    }

    private func bindEngine() {
        engine.events
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handle(event: event)
            }
            .store(in: &cancellables)

        engine.$textAnnotations
            .receive(on: RunLoop.main)
            .sink { [weak self] annotations in
                self?.textAnnotations = annotations
                for indexPath in self?.collectionView.indexPathsForVisibleItems ?? [] {
                    if let cell = self?.collectionView.cellForItem(at: indexPath) as? CoreTextChunkCollectionCell {
                        cell.applyAnnotations(annotations)
                    }
                }
            }
            .store(in: &cancellables)

        displayedCount = engine.chunks.count
        if !engine.chunks.isEmpty {
            collectionView.reloadData()
        }
    }

    private func handle(event: CoreTextScrollEngine.Event) {
        switch event {
        case .reset:
            displayedCount = engine.chunks.count
            pendingProgress = nil
            lastWarmRow = nil
            collectionView.reloadData()
        case .insertedAtBottom(let count, _):
            insertItems(count: count, atBottom: true, addedExtent: 0)
        case .insertedAtTop(let count, let addedExtent, _):
            insertItems(count: count, atBottom: false, addedExtent: addedExtent)
        }

        applyPendingInitialScrollIfPossible()
    }

    private func insertItems(count: Int, atBottom: Bool, addedExtent: CGFloat) {
        let total = engine.chunks.count
        let actualOld = displayedCount
        let expectedOld = max(0, total - count)
        guard actualOld == expectedOld else {
            displayedCount = total
            collectionView.reloadData()
            return
        }

        engine.warmChunks(around: atBottom ? actualOld : count, radius: 6)
        guard actualOld > 0, collectionView.window != nil else {
            displayedCount = total
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            return
        }

        let offset = collectionView.contentOffset
        let anchorPath = atBottom ? nil : visibleProgressIndexPath()
        let anchorFrame = anchorPath.flatMap {
            collectionView.layoutAttributesForItem(at: $0)?.frame
        }
        let paths: [IndexPath] = atBottom
            ? (actualOld..<total).map { IndexPath(item: $0, section: 0) }
            : (0..<count).map { IndexPath(item: $0, section: 0) }
        displayedCount = total
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: paths)
        } completion: { [weak self] _ in
            guard let self = self, !atBottom else { return }
            self.collectionView.layoutIfNeeded()
            if let anchorPath,
               let anchorFrame,
               let newFrame = self.collectionView.layoutAttributesForItem(
                   at: IndexPath(item: anchorPath.item + count, section: anchorPath.section)
               )?.frame {
                self.collectionView.setContentOffset(
                    CGPoint(
                        x: offset.x + newFrame.minX - anchorFrame.minX,
                        y: offset.y + newFrame.minY - anchorFrame.minY
                    ),
                    animated: false
                )
            } else if self.scrollAxis == .vertical {
                self.collectionView.setContentOffset(
                    CGPoint(x: offset.x, y: offset.y + addedExtent),
                    animated: false
                )
            }
        }
    }

    private func applyPendingInitialScrollIfPossible() {
        guard !hasAppliedInitialScroll, let target = pendingInitialScroll else { return }
        guard let row = engine.chunkIndex(forChapter: target.chapter, charOffset: target.charOffset),
              row < engine.chunks.count else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.scrollToInitialRow(row) else { return }
            self.engine.warmChunks(around: row, radius: 6)
            self.hasAppliedInitialScroll = true
            self.pendingInitialScroll = nil
        }
    }

    @discardableResult
    private func scrollToInitialRow(_ row: Int) -> Bool {
        guard collectionView.window != nil,
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0,
              collectionView.numberOfItems(inSection: 0) > row
        else { return false }

        let path = IndexPath(item: row, section: 0)
        collectionView.layoutIfNeeded()

        switch scrollAxis {
        case .vertical:
            collectionView.scrollToItem(
                at: path,
                at: scrollAxis.initialScrollPosition,
                animated: false
            )
            return true
        case .horizontalRTL:
            guard let attributes = collectionView.layoutAttributesForItem(at: path),
                  collectionView.contentSize.width > 0
            else { return false }
            let visibleWidth = collectionView.bounds.width
            let minOffsetX = -collectionView.adjustedContentInset.left
            let maxOffsetX = max(
                minOffsetX,
                collectionView.contentSize.width - visibleWidth + collectionView.adjustedContentInset.right
            )
            let desiredOffsetX = attributes.frame.maxX - visibleWidth + collectionView.adjustedContentInset.right
            let offsetX = min(max(desiredOffsetX, minOffsetX), maxOffsetX)
            collectionView.setContentOffset(
                CGPoint(
                    x: offsetX,
                    y: collectionView.contentOffset.y
                ),
                animated: false
            )
            return true
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if interactor.hasSelection {
            clearSelection()
            return
        }

        let point = gesture.location(in: collectionView)
        if let (_, chunk, localPoint) = hitTestChunk(at: point),
           let idx = chunk.stringIndex(atLocalPoint: localPoint),
           let href = HTMLAttributedStringBuilder.linkHref(at: idx, in: chunk.attributedString) {
            onInternalLinkTap?(href)
            return
        }

        onTap?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let (_, chunk, localPoint) = hitTestChunk(at: point),
                  let idx = chunk.stringIndex(atLocalPoint: localPoint) else {
                clearSelection()
                return
            }
            selectionChapter = chunk.chapterIndex
            interactor.textAnnotations = textAnnotations
            interactor.beginSelection(
                at: idx,
                in: chunk.attributedString,
                spineIndex: selectionChapter!,
                maxLength: chunk.attributedString.length
            )
            refreshSelectionOverlays()
        case .changed:
            guard let chapter = selectionChapter,
                  let (_, chunk, localPoint) = hitTestChunk(at: point),
                  chunk.chapterIndex == chapter,
                  let idx = chunk.stringIndex(atLocalPoint: localPoint) else { return }
            interactor.updateSelection(to: idx, maxLength: chunk.attributedString.length)
            refreshSelectionOverlays()
        case .ended:
            guard let chapter = selectionChapter,
                  let chunk = engine.chunks.first(where: { $0.chapterIndex == chapter })
            else { clearSelection(); return }
            interactor.finalizeSelection(in: chunk.attributedString)
            selectedText = interactor.selectedTextForCopy
            guard let text = selectedText, !text.isEmpty else { clearSelection(); return }
            becomeFirstResponder()
            let viewPoint = collectionView.convert(point, to: view)
            editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: viewPoint))
            _ = text
        case .cancelled, .failed:
            clearSelection()
        default:
            break
        }
    }

    private func hitTestChunk(at pointInCollection: CGPoint) -> (cell: CoreTextChunkCollectionCell, chunk: CoreTextChunk, localPoint: CGPoint)? {
        guard let path = collectionView.indexPathForItem(at: pointInCollection),
              let cell = collectionView.cellForItem(at: path) as? CoreTextChunkCollectionCell,
              let chunk = cell.currentChunk else { return nil }
        let local = collectionView.convert(pointInCollection, to: cell.drawView)
        return (cell, chunk, local)
    }

    private var currentSelectionRange: NSRange? {
        interactor.selectedRange
    }

    private func refreshSelectionOverlays() {
        let chapter = selectionChapter
        let range = currentSelectionRange
        for cell in collectionView.visibleCells.compactMap({ $0 as? CoreTextChunkCollectionCell }) {
            if let chapter = chapter {
                cell.applySelection(chapterIndex: chapter, chapterRange: range)
            } else {
                cell.applySelection(chapterIndex: -1, chapterRange: nil)
            }
        }
    }

    private func clearSelection() {
        selectionChapter = nil
        interactor.clear()
        selectedText = nil
        refreshSelectionOverlays()
        editMenuInteraction.dismissMenu()
    }

    private func visibleProgressRow() -> Int {
        guard let row = visibleProgressIndexPath()?.item, row < engine.chunks.count else { return 0 }
        return row
    }

    private func visibleProgressChapter() -> Int {
        let chunks = engine.chunks
        guard !chunks.isEmpty else { return pendingInitialChapter }
        let row = visibleProgressRow()
        return chunks.indices.contains(row) ? chunks[row].chapterIndex : (chunks.first?.chapterIndex ?? 0)
    }

    private func visibleProgressIndexPath() -> IndexPath? {
        guard !engine.chunks.isEmpty else { return nil }
        switch scrollAxis {
        case .vertical:
            let visibleY = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            return collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: max(0, visibleY)))
        case .horizontalRTL:
            let rightX = collectionView.contentOffset.x + collectionView.bounds.width - collectionView.adjustedContentInset.right - 1
            return collectionView.indexPathForItem(at: CGPoint(x: max(0, rightX), y: collectionView.bounds.midY))
        }
    }

    private func chapterGap(for row: Int) -> CGFloat {
        guard row > 0, row < engine.chunks.count else { return 0 }
        guard engine.chunks[row].chapterIndex != engine.chunks[row - 1].chapterIndex else { return 0 }
        return scrollAxis == .horizontalRTL ? Self.verticalRTLChapterGap : Self.chapterGap
    }
}

extension CoreTextCollectionScrollViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CoreTextChunkCollectionCell.reuseIdentifier,
            for: indexPath
        )
        if let chunkCell = cell as? CoreTextChunkCollectionCell,
           indexPath.item < engine.chunks.count {
            let chunk = engine.chunks[indexPath.item]
            chunkCell.bind(
                chunk: chunk,
                axis: scrollAxis,
                horizontalInset: horizontalInset,
                verticalInset: verticalInset,
                leadingSpacing: chapterGap(for: indexPath.item)
            )
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard indexPath.item < engine.chunks.count else { return .zero }
        let chunk = engine.chunks[indexPath.item]
        let gap = chapterGap(for: indexPath.item)
        switch scrollAxis {
        case .vertical:
            return CGSize(width: collectionView.bounds.width, height: chunk.height + gap)
        case .horizontalRTL:
            return CGSize(width: chunk.width + gap, height: collectionView.bounds.height)
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.item < engine.chunks.count else { return }
        if !engine.chunks[indexPath.item].isMaterialized {
            engine.chunks[indexPath.item].materializeFrameIfNeeded()
        }
        if let chunkCell = cell as? CoreTextChunkCollectionCell {
            if let chapter = selectionChapter {
                chunkCell.applySelection(chapterIndex: chapter, chapterRange: currentSelectionRange)
            }
            chunkCell.applyPlaybackHighlight(text: playbackHighlightText)
            chunkCell.applyAnnotations(textAnnotations)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let chunks = engine.chunks
        guard !chunks.isEmpty else { return }

        let remainingVertical = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        let remainingHorizontal = scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.bounds.width)
        if scrollAxis == .vertical, remainingVertical < scrollView.bounds.height * 1.5,
           let lastChapter = chunks.last?.chapterIndex {
            engine.ensureChapterAhead(of: lastChapter)
        }
        if scrollAxis == .vertical, scrollView.contentOffset.y < scrollView.bounds.height * 1.5,
           let firstChapter = chunks.first?.chapterIndex {
            engine.ensureChapterBehind(of: firstChapter)
        }
        if scrollAxis == .horizontalRTL, min(scrollView.contentOffset.x, remainingHorizontal) < scrollView.bounds.width * 1.5,
           let visible = visibleProgressIndexPath(), visible.item < chunks.count {
            engine.ensureChapterAhead(of: chunks[visible.item].chapterIndex)
            engine.ensureChapterBehind(of: chunks[visible.item].chapterIndex)
        }

        guard let path = visibleProgressIndexPath(), path.item < chunks.count else { return }

        if lastWarmRow != path.item {
            lastWarmRow = path.item
            engine.warmChunks(around: path.item, radius: 6)
        }

        // Record position for commit-on-stop. No save / store update / SwiftUI state here.
        let chunk = chunks[path.item]
        let total = max(1, engine.chapterCount)
        let pct = Double(chunk.chapterIndex) / Double(total - 1 == 0 ? 1 : total - 1)
        pendingProgress = ScrollProgress(
            chapter: chunk.chapterIndex,
            charOffset: chunk.charRange.location,
            percentage: min(1, max(0, pct))
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitProgress()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { commitProgress() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        commitProgress()
    }

    private func commitProgress() {
        guard let pos = pendingProgress else { return }
        onProgressCommit?(pos)
    }
}

private final class CoreTextScrollFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
}
