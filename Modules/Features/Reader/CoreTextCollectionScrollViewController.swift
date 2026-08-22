import AVKit
import Combine
import SwiftUI
import UIKit

/// UICollectionView-backed CoreText continuous reader.
/// Horizontal books scroll vertically; vertical-rl books scroll horizontally right-to-left.
final class CoreTextCollectionScrollViewController: UIViewController, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    private static let emphasisEditMenuIdentifier = NSString(string: "CoreTextCollectionScrollViewController.emphasis")

    static let chapterGap: CGFloat = 24
    static let verticalRTLChapterGap: CGFloat = 72

    private let engine: CoreTextScrollEngine
    private(set) var scrollAxis: CoreTextScrollAxis
    private var horizontalInset: CGFloat
    private var verticalInset: CGFloat
    var bottomMargin: CGFloat = 0
    var onProgressCommit: ((CoreTextReadingPosition) -> Void)?
    var onTap: (() -> Void)?
    var onInternalLinkTap: ((String) -> Void)?
    private(set) var lastAppliedRefreshTransactionID: UInt64 = 0

    private let collectionView: UICollectionView
    private var cancellables: Set<AnyCancellable> = []
    /// **Where the reader is, as a character in the book. The source of truth.**
    ///
    /// `contentOffset` is derived from this; never the reverse. Only four things write it: the
    /// handover from paged mode / cold start, a scroll the *user* performed, a TTS follow, and a
    /// navigation request. Chapter loads deliberately do not — that was the compensation model,
    /// and it could not be made to work. Two overlapping `performBatchUpdates` completions each
    /// computed their offset delta against geometry the other had already changed, which a device
    /// log caught red-handed: `insertCompensation … applied=27195.3` immediately followed by
    /// `… applied=13908.3`, a whole chapter down and back up again.
    private var readingPosition: CoreTextReadingPosition?
    /// Whether `readingPosition` has been put on screen at least once. Until it has, the reader is
    /// showing whatever the collection view happened to lay out, not a position anyone chose.
    private var hasAppliedReadingPosition = false
    /// Set while we are writing an offset ourselves, so scroll callbacks do not turn our own
    /// programmatic scroll back into a "the user moved" signal. Without it the restore overwrote
    /// the position it had just restored: the device log shows the saved offset flipping
    /// `off253 → off0 → off253` across successive reader instances.
    private var isApplyingReadingPosition = false
    private var hasKickedOffEngine = false
    private var pendingInitialChapter: Int = 0
    private var displayedCount: Int = 0
    private var lastWarmRow: Int?
    private var lastWarmUptime: TimeInterval = 0
    private var resliceTask: Task<Void, Never>?
    private var pendingVisibleRefreshCompletion: ((Bool) -> Void)?

    private var selectionChapter: Int?
    private var selectedText: String?
    private var latestEditMenuSourcePoint: CGPoint?
    private let interactor = TextSelectionInteractor()
    private var playbackHighlightText: String?
    /// True while a TTS-follow auto-scroll animation is in flight, so it isn't
    /// mistaken for the user manually scrolling away from the narration.
    private var isAutoScrollingPlayback = false
    private var textAnnotations: [CoreTextTextAnnotation] = []
    private var inlineVideoControllers: [String: AVPlayerViewController] = [:]
    var inlineVideoControllerCountForTesting: Int { inlineVideoControllers.count }
    private lazy var tapGesture: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    deinit {
        for (key, controller) in Array(inlineVideoControllers) {
            detachInlineVideoController(key: key, controller: controller)
        }
    }

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

        // Flow layout. `ReaderScrollLayout` exists and its geometry is proven pixel-identical, but
        // it is not wired in: the migration it belongs to (`Technotes/ViewportScrollArchitecture.md`)
        // is on hold pending an architecture change, and it buys the reader nothing until then.
        let layout = CoreTextScrollFlowLayout()
        layout.scrollDirection = axis.collectionScrollDirection
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
        let isTransparent = backgroundColor.cgColor.alpha < 0.999
        view.isOpaque = !isTransparent
        collectionView.isOpaque = !isTransparent
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
        let selectionHasNote = annotationCoveringSelection()
            .flatMap(\.note)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let colorActions = AnnotationColor.allCases.map { color in
            UIAction(
                title: emphasisColorName(for: color),
                image: emphasisColorImage(for: color),
                handler: { [weak self] _ in
                    self?.requestUnderline(style: .highlight, color: color)
                }
            )
        }
        let underlineAction = UIAction(
            title: localized("下劃線"),
            image: UIImage(systemName: "underline"),
            handler: { [weak self] _ in
                self?.requestUnderline(style: .underline, color: .yellow)
            }
        )

        if configuration.identifier as? NSString == Self.emphasisEditMenuIdentifier {
            return UIMenu(children: colorActions + [underlineAction])
        }

        var actions = suggestedActions
        actions.append(UIAction(
            title: localized("替換"),
            image: UIImage(systemName: "eraser"),
            handler: { [weak self] _ in
                self?.requestReplaceRule()
            }
        ))
        actions.append(UIAction(
            title: localized("重點"),
            image: UIImage(systemName: "highlighter"),
            handler: { [weak self] _ in
                self?.presentEmphasisEditMenu()
            }
        ))
        // 同分頁模式：沒訂閱時換鎖頭，實際分流在 ReaderView。
        let canEditNote = ReaderPremiumVisibilityPolicy(
            isProActive: SubscriptionStore.shared.isProActive
        ).allowsParagraphNoteEditing
        actions.append(UIAction(
            title: localized(selectionHasNote ? "編輯筆記" : "筆記"),
            image: UIImage(systemName: canEditNote ? "note.text" : "lock.fill"),
            handler: { [weak self] _ in
                self?.requestNoteEdit()
            }
        ))
        return UIMenu(children: actions)
    }

    private func presentSelectionEditMenu(at sourcePoint: CGPoint) {
        latestEditMenuSourcePoint = sourcePoint
        editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: sourcePoint
        ))
    }

    private func presentEmphasisEditMenu() {
        let sourcePoint = latestEditMenuSourcePoint ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        editMenuInteraction.dismissMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
                identifier: Self.emphasisEditMenuIdentifier,
                sourcePoint: sourcePoint
            ))
        }
    }

    private func emphasisColorName(for color: AnnotationColor) -> String {
        switch color {
        case .yellow: return localized("黃色")
        case .green: return localized("綠色")
        case .blue: return localized("藍色")
        case .pink: return localized("粉色")
        case .orange: return localized("橙色")
        }
    }

    private func emphasisColorImage(for color: AnnotationColor) -> UIImage? {
        let size = CGSize(width: 22, height: 22)
        let swatchRect = CGRect(x: 3, y: 3, width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath(roundedRect: swatchRect, cornerRadius: 3)
            color.uiColor.setFill()
            path.fill()
            UIColor.separator.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    @objc private func underlineSelection(_ sender: Any?) {
        requestUnderline(style: .underline, color: .yellow)
    }

    private func requestReplaceRule() {
        guard let selectedText, !selectedText.isEmpty else { return }
        NotificationCenter.default.post(
            name: .coreTextReplaceSelectionRequested,
            object: self,
            userInfo: ["request": CoreTextReplaceSelectionRequest(selectedText: selectedText)]
        )
        clearSelection()
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

    // MARK: - 筆記

    private func annotationCoveringSelection() -> CoreTextTextAnnotation? {
        guard let chapter = selectionChapter,
              let range = currentSelectionRange,
              range.length > 0
        else { return nil }
        return AnnotationStore.annotationFullyContaining(
            spineIndex: chapter,
            range: range,
            in: textAnnotations
        )
    }

    /// 選字選單的「筆記」。已有標註就編輯它的筆記；純選取則把選取範圍送出去，
    /// 由閱讀器補上預設標註後再開編輯頁。
    private func requestNoteEdit() {
        if let annotation = annotationCoveringSelection() {
            postNoteEditRequest(for: annotation)
            clearSelection()
            return
        }
        guard let chapter = selectionChapter,
              let range = currentSelectionRange,
              range.length > 0
        else { return }
        NotificationCenter.default.post(
            name: .coreTextNoteEditRequested,
            object: self,
            userInfo: [
                "request": CoreTextNoteEditRequest(
                    position: CoreTextReadingPosition(spineIndex: chapter, charOffset: range.location),
                    length: range.length,
                    excerpt: selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            ]
        )
        clearSelection()
    }

    private func postNoteEditRequest(for annotation: CoreTextTextAnnotation) {
        NotificationCenter.default.post(
            name: .coreTextNoteEditRequested,
            object: self,
            userInfo: [
                "request": CoreTextNoteEditRequest(
                    position: CoreTextReadingPosition(
                        spineIndex: annotation.spineIndex,
                        charOffset: annotation.startOffset
                    ),
                    length: annotation.range.length,
                    excerpt: annotationExcerpt(annotation),
                    existingNote: annotation.note ?? "",
                    style: annotation.style,
                    color: annotation.color
                )
            ]
        )
    }

    private func annotationExcerpt(_ annotation: CoreTextTextAnnotation) -> String {
        guard let chunk = engine.chunks.first(where: { $0.chapterIndex == annotation.spineIndex })
        else { return "" }
        let clamped = NSIntersectionRange(
            annotation.range,
            NSRange(location: 0, length: chunk.attributedString.length)
        )
        guard clamped.length > 0 else { return "" }
        return chunk.attributedString
            .attributedSubstring(from: clamped)
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc override func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        kickoffEngineIfNeeded()
        applyReadingPositionIfPossible()
        reconcileInlineVideos()
    }

    func setInitialPosition(chapter: Int, charOffset: Int) {
        // Entry point for both "open the book" and "switch from paged to scroll" — the two cases
        // that land wrong. If the target logged here is already wrong, the fault is upstream in
        // whoever computed the handover position, not in this controller.
        posTrace("setInitialPosition", "target=(ch\(chapter),off\(charOffset))")
        readingPosition = CoreTextReadingPosition(spineIndex: chapter, charOffset: charOffset)
        hasAppliedReadingPosition = false
        pendingInitialChapter = chapter
        applyReadingPositionIfPossible()
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
            warmChunks(around: visibleProgressRow(), force: true)
            collectionView.reloadData()
            reconcileInlineVideos()
        }
    }

    func updateBackgroundColor(_ color: UIColor) {
        view.backgroundColor = color
        collectionView.backgroundColor = color
        let isTransparent = color.cgColor.alpha < 0.999
        view.isOpaque = !isTransparent
        collectionView.isOpaque = !isTransparent
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
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = trimmed != playbackHighlightText
        playbackHighlightText = trimmed
        for cell in collectionView.visibleCells.compactMap({ $0 as? CoreTextChunkCollectionCell }) {
            cell.applyPlaybackHighlight(text: playbackHighlightText)
        }
        if changed, !(trimmed?.isEmpty ?? true) {
            // Defer one runloop so cells finish recomputing their highlight rects.
            DispatchQueue.main.async { [weak self] in self?.autoScrollToPlaybackHighlightIfNeeded() }
        }
    }

    /// Auto page-turn for scroll mode: keep the sentence TTS is speaking on screen.
    /// Only nudges when the highlight has drifted into the lower part of the viewport,
    /// and only when it's already on screen — if the user has scrolled away to browse,
    /// the highlight isn't visible so nothing is yanked.
    private func autoScrollToPlaybackHighlightIfNeeded() {
        guard scrollAxis == .vertical,
              collectionView.window != nil,
              !isAutoScrollingPlayback
        else { return }

        var highlightRect: CGRect?
        for cell in collectionView.visibleCells.compactMap({ $0 as? CoreTextChunkCollectionCell }) {
            if let rect = cell.playbackHighlightBounds(in: collectionView) {
                highlightRect = rect
                break
            }
        }
        guard let rect = highlightRect else { return }

        let topInset = collectionView.adjustedContentInset.top
        let viewportTop = collectionView.contentOffset.y + topInset
        let viewportHeight = collectionView.bounds.height - topInset - collectionView.adjustedContentInset.bottom
        guard viewportHeight > 0 else { return }

        // Nudge only once the spoken line passes ~72% down the screen, then place it
        // ~30% from the top so there's read-ahead context below it.
        let triggerY = viewportTop + viewportHeight * 0.72
        guard rect.maxY > triggerY else { return }

        let desiredOffset = rect.minY - topInset - viewportHeight * 0.3
        let clamped = clampedScrollOffset(CGPoint(x: collectionView.contentOffset.x, y: desiredOffset))
        // Only ever nudge forward: if the clamp pulls the target back to where we already are (or
        // above it), the highlight is close enough and moving would fight the reader.
        guard clamped.y > collectionView.contentOffset.y + 1 else { return }

        isAutoScrollingPlayback = true
        setScrollOffset(clamped, source: .ttsFollow, animated: true)
    }

    func requestReslice(at chapter: Int, charOffset: Int = 0) {
        requestReslice(at: chapter, charOffset: charOffset, completion: nil)
    }

    private func requestReslice(
        at chapter: Int,
        charOffset: Int = 0,
        completion: ((Bool) -> Void)?
    ) {
        let extent = currentContentExtent
        let imageExtent = currentImageContentWidth
        let viewportExtent = currentViewportExtent
        guard extent > 0 else { return }
        resliceTask?.cancel()
        pendingVisibleRefreshCompletion = completion
        resliceTask = Task { [weak self] in
            guard let self = self else { return }
            self.hasAppliedReadingPosition = false
            self.readingPosition = CoreTextReadingPosition(
                spineIndex: chapter,
                charOffset: charOffset
            )
            let succeeded = await self.engine.reslice(
                restoreAt: chapter,
                contentWidth: extent,
                imageContentWidth: imageExtent,
                viewportExtent: viewportExtent
            )
            guard !Task.isCancelled else { return }
            guard succeeded else {
                let completion = self.pendingVisibleRefreshCompletion
                self.pendingVisibleRefreshCompletion = nil
                completion?(false)
                self.resliceTask = nil
                return
            }
            self.applyReadingPositionIfPossible(force: true)
            self.resliceTask = nil
        }
    }

    func applyVisibleRefresh(
        _ commit: ReaderVisibleRefreshCommit,
        completion: @escaping (UInt64, ReaderVisibleRefreshOutcome) -> Void
    ) {
        guard commit.mode == .scroll,
              commit.transactionID != lastAppliedRefreshTransactionID
        else { return }
        guard currentContentExtent > 0 else {
            completion(
                commit.transactionID,
                .failed(.scrollViewportUnavailable)
            )
            return
        }

        requestReslice(
            at: commit.position.spineIndex,
            charOffset: commit.position.charOffset
        ) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded else {
                completion(
                    commit.transactionID,
                    .failed(.scrollLayoutUnavailable(commit.position.spineIndex))
                )
                return
            }
            self.lastAppliedRefreshTransactionID = commit.transactionID
            completion(commit.transactionID, .applied)
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

    /// One screen along the scroll axis — the floor a chapter with a publication-authored
    /// backdrop image is padded to. Deliberately the full viewport, not the inset content
    /// box: paged mode paints that backdrop across the entire page including its margins
    /// (`CoreTextPageView.drawContent`), and the padding exists to match it.
    private var currentViewportExtent: CGFloat {
        switch scrollAxis {
        case .vertical:
            return view.bounds.height
        case .horizontalRTL:
            return view.bounds.width
        }
    }

    private func kickoffEngineIfNeeded() {
        guard !hasKickedOffEngine else { return }
        let extent = currentContentExtent
        let imageExtent = currentImageContentWidth
        let viewportExtent = currentViewportExtent
        guard extent > 0 else { return }
        hasKickedOffEngine = true
        Task { [weak self] in
            guard let self = self else { return }
            await self.engine.start(
                initialChapter: self.pendingInitialChapter,
                contentWidth: extent,
                imageContentWidth: imageExtent,
                viewportExtent: viewportExtent
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
        case .reset(let restorePosition):
            posTrace(
                "event.reset",
                "restore=\(restorePosition.map { "(ch\($0.spineIndex),off\($0.charOffset))" } ?? "nil") "
                    + "held=\(readingPosition.map { "(ch\($0.spineIndex),off\($0.charOffset))" } ?? "nil")"
            )
            // A reset with no position is no longer destructive. The engine used to be the only
            // thing that knew where the reader was, so `restore=nil` — which is what every reslice
            // outside this controller sends — meant the position was simply gone and whatever
            // offset survived the rebuild was an accident. The controller now holds it, so an
            // engine reset can only ever *override* it, never erase it.
            if let restorePosition {
                readingPosition = restorePosition
            }
            hasAppliedReadingPosition = false
            displayedCount = engine.chunks.count
            lastWarmRow = nil
            collectionView.reloadData()
            applyReadingPositionIfPossible(force: true)
        case .chunksInserted(let range, _):
            applyChunkInsertion(range)
        }

        reconcileInlineVideos()
    }

    /// Brings the collection view in line with `engine.chunks` after an insertion, then puts the
    /// reader back where they were.
    ///
    /// There is no offset arithmetic here at all any more. The previous version captured the
    /// current offset and an anchor frame *before* the batch update and applied the difference
    /// afterwards, which is only correct if nothing else changes in between — and chapter loads
    /// are concurrent, so something else routinely did. Re-applying the reading position needs no
    /// before-picture, so overlapping insertions cannot interfere with each other.
    private func applyChunkInsertion(_ range: Range<Int>) {
        let total = engine.chunks.count
        let actualOld = displayedCount
        let expectedOld = max(0, total - range.count)
        posTrace(
            "insert",
            "range=\(range.lowerBound)..<\(range.upperBound) actualOld=\(actualOld) "
                + "expectedOld=\(expectedOld) applied=\(hasAppliedReadingPosition)"
        )

        // Count desync: concurrent chapter loads leave `displayedCount` out of step with
        // `engine.chunks`, so an incremental `insertItems(at:)` would raise. A full reload is
        // correct here precisely because the position no longer rides on the offset.
        if actualOld == expectedOld, actualOld > 0, collectionView.window != nil {
            collectionView.performBatchUpdates {
                self.displayedCount = total
                self.collectionView.insertItems(
                    at: range.map { IndexPath(item: $0, section: 0) }
                )
            } completion: { [weak self] _ in
                guard let self else { return }
                self.collectionView.layoutIfNeeded()
                self.applyReadingPositionIfPossible(force: true)
            }
            return
        }

        displayedCount = total
        lastWarmRow = nil
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        applyReadingPositionIfPossible(force: true)
    }

    /// Puts `readingPosition` back on screen.
    ///
    /// Called after **every** structural change — initial layout, chapter insertion, reset,
    /// reload. That is the whole model: rather than working out how far the content moved and
    /// compensating, the reader is simply put where it belongs again. The answer does not depend
    /// on what changed, or on the order changes arrived in, so overlapping chapter loads cannot
    /// produce a wrong result the way overlapping compensations did.
    ///
    /// - Parameter force: re-apply even if the position is already on screen. Structural changes
    ///   pass `true`; idle layout passes pass `false` so the user's own scrolling is left alone.
    @discardableResult
    private func applyReadingPositionIfPossible(force: Bool = false) -> Bool {
        guard force || !hasAppliedReadingPosition else { return false }
        guard let target = readingPosition else { return false }
        guard let row = engine.chunkIndex(
            forChapter: target.spineIndex,
            charOffset: target.charOffset
        ), row < engine.chunks.count else {
            // Called from `viewDidLayoutSubviews` too, so deferring is normal early on. It matters
            // only if it keeps deferring — or if it resolves once content has *changed* under it.
            posTrace(
                "restore.deferred",
                "target=(ch\(target.spineIndex),off\(target.charOffset)) chunks=\(engine.chunks.count)"
            )
            return false
        }
        let chunk = engine.chunks[row]
        posTrace(
            "restore.resolve",
            "target=(ch\(target.spineIndex),off\(target.charOffset)) row=\(row) force=\(force) "
                + "chunkChapter=\(chunk.chapterIndex) chunkStart=\(chunk.charRange.location) "
                + "withinChunkChars=\(target.charOffset - chunk.charRange.location)"
        )
        guard scrollToRow(row, charOffset: target.charOffset) else { return false }
        warmChunks(around: row, force: true)
        hasAppliedReadingPosition = true
        let completion = pendingVisibleRefreshCompletion
        pendingVisibleRefreshCompletion = nil
        completion?(true)
        return true
    }

    /// Puts `charOffset` — not the chunk that contains it — at the top of the viewport.
    ///
    /// This is where "switching from paged to scroll runs away" came from. The handover position is
    /// character-granular, but the restore was `scrollToItem(at: .top)`, which can only express
    /// *rows*: it pinned the chunk's upper edge to the viewport top and silently discarded
    /// `charOffset - chunk.charRange.location`. Chunks are capped at
    /// `CoreTextChunkSlicer.defaultHeightCap` (2000pt) against a viewport nearer 800pt, so the
    /// discard was worth up to roughly two and a half screens. The quantity was already being
    /// logged, as `restore.resolve`'s `lostWithinChunk`.
    @discardableResult
    private func scrollToRow(_ row: Int, charOffset: Int) -> Bool {
        // Re-entrancy guard, not a delay. Writing `contentOffset` can provoke another layout pass,
        // and this is called from `viewDidLayoutSubviews`; the old code sidestepped that with a
        // `DispatchQueue.main.async` hop, which also decoupled the write from the change that
        // caused it. Refusing re-entry is the same protection without the timing dependency.
        guard !isApplyingReadingPosition else { return false }
        guard collectionView.window != nil,
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0,
              collectionView.numberOfItems(inSection: 0) > row
        else {
            posTrace("restore.blocked", "row=\(row) bounds=\(collectionView.bounds.size)")
            return false
        }
        isApplyingReadingPosition = true
        defer { isApplyingReadingPosition = false }

        let path = IndexPath(item: row, section: 0)
        collectionView.layoutIfNeeded()

        // The frame we are aiming at, and what the offset actually became. If `targetFrame`
        // disagrees with the item's real position the geometry is wrong; if it agrees but the
        // final offset does not follow it, something moved us after the fact.
        let targetFrame = collectionView.layoutAttributesForItem(at: path)?.frame

        // Horizontal RTL stays on `scrollToItem`. `topOffset(forCharacterIndex:)` deliberately
        // refuses vertical writing — its lines run along x, so it would answer in the wrong axis —
        // and this file's mirrored inset arithmetic is unverified. Vertical CJK therefore still
        // restores to the chunk edge: a known remaining gap, not an oversight.
        guard scrollAxis == .vertical,
              let frame = targetFrame,
              row < engine.chunks.count
        else {
            collectionView.scrollToItem(
                at: path,
                at: scrollAxis.initialScrollPosition,
                animated: false
            )
            posTrace(
                "offset.restore",
                "row=\(row) viaScrollToItem=yes axis=\(scrollAxis) "
                    + "targetFrame=\(targetFrame.map { "\($0)" } ?? "nil")"
            )
            return true
        }

        // `nil` from `topOffset` is an answer, not a failure: an image-only chunk, or an offset
        // sitting on the chunk's first character, both belong at the chunk's own top edge.
        //
        // The landed offset can differ from the one computed here by up to half a device pixel —
        // `contentOffset` is quantised, measured at 1/6pt on a 3x screen. That is the resolution
        // of the API, not slack in the arithmetic, which `ScrollOffsetEquivalenceTests` pins
        // separately and exactly.
        let chunk = engine.chunks[row]
        let withinChunk = chunk.topOffset(forCharacterIndex: charOffset) ?? 0
        setScrollOffset(
            CGPoint(
                x: collectionView.contentOffset.x,
                y: frame.minY + withinChunk - collectionView.adjustedContentInset.top
            ),
            source: .restore,
            detail: "row=\(row) off=\(charOffset) chunkStart=\(chunk.charRange.location) "
                + "withinChunk=\(String(format: "%.1f", withinChunk)) "
                + "frameY=\(String(format: "%.1f", frame.minY))"
        )
        return true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if interactor.hasSelection {
            clearSelection()
            return
        }

        let point = gesture.location(in: collectionView)

        // 筆記圓圈畫在正文之上，落在它上面的點擊就是要開筆記，先於連結／圖片處理。
        if let (cell, _, localPoint) = hitTestChunk(at: point),
           let annotationID = cell.noteMarkerAnnotationID(atLocalPoint: localPoint),
           let annotation = textAnnotations.first(where: { $0.id == annotationID }) {
            postNoteEditRequest(for: annotation)
            return
        }

        if let (_, chunk, localPoint) = hitTestChunk(at: point),
           let href = attachmentLinkTarget(in: chunk, at: localPoint)?.href {
            if let note = FootnoteStore.text(spineIndex: chunk.chapterIndex, href: href),
               let anchor = footnoteAnchor(at: point) {
                FootnotePopoverHost.present(
                    text: note,
                    from: self,
                    sourceView: anchor.sourceView,
                    sourceRect: anchor.sourceRect
                )
                return
            }
            onInternalLinkTap?(href)
            return
        }
        if let media = mediaAttachment(at: point) {
            handleMediaTap(media)
            return
        }

        if let (_, chunk, localPoint) = hitTestChunk(at: point),
           let idx = chunk.stringIndex(atLocalPoint: localPoint),
           let href = HTMLAttributedStringBuilder.linkHref(at: idx, in: chunk.attributedString) {
            if let note = FootnoteStore.text(spineIndex: chunk.chapterIndex, href: href),
               let anchor = footnoteAnchor(at: point) {
                FootnotePopoverHost.present(
                    text: note,
                    from: self,
                    sourceView: anchor.sourceView,
                    sourceRect: anchor.sourceRect
                )
                return
            }
            onInternalLinkTap?(href)
            return
        }

        onTap?()
    }

    private func mediaAttachment(at point: CGPoint) -> EPUBMediaAttachment? {
        guard let (_, chunk, localPoint) = hitTestChunk(at: point) else { return nil }
        let attachments = chunk.attachments + chunk.blockRenderables.compactMap(\.imageAttachment)
        return attachments.first { attachment in
            attachment.mediaAttachment != nil
                && attachment.rect.insetBy(dx: -8, dy: -8).contains(localPoint)
        }?.mediaAttachment
    }

    private func attachmentLinkTarget(
        in chunk: CoreTextChunk,
        at point: CGPoint
    ) -> CoreTextPaginator.RenderedAttachment.LinkTarget? {
        let attachments = chunk.attachments + chunk.blockRenderables.compactMap(\.imageAttachment)
        return attachments.lazy.compactMap { $0.linkTarget(at: point) }.first
    }

    private func footnoteAnchor(at pointInCollection: CGPoint) -> (sourceView: UIView, sourceRect: CGRect)? {
        guard let (cell, _, localPoint) = hitTestChunk(at: pointInCollection) else { return nil }
        let anchorSize: CGFloat = 12
        let origin = CGPoint(
            x: localPoint.x - anchorSize / 2,
            y: localPoint.y - anchorSize / 2
        )
        return (
            sourceView: cell.drawView,
            sourceRect: CGRect(origin: origin, size: CGSize(width: anchorSize, height: anchorSize))
        )
    }

    private func presentEPUBMedia(_ media: EPUBMediaAttachment) {
        let controller = UIHostingController(rootView: EPUBMediaPlayerView(media: media))
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = media.kind == .video ? [.medium(), .large()] : [.medium()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    func handleMediaTap(_ media: EPUBMediaAttachment) {
        if media.kind == .video {
            startInlineVideo(media)
        } else {
            presentEPUBMedia(media)
        }
    }

    private func startInlineVideo(_ media: EPUBMediaAttachment) {
        guard let visible = visibleVideoAttachments().first(where: { $0.media.sourceHref == media.sourceHref }) else {
            presentEPUBMedia(media)
            return
        }
        embedInlineVideo(media: visible.media, frame: visible.frame)
    }

    private func reconcileInlineVideos() {
        let visibleVideos = visibleVideoAttachments()
        let visibleKeys = Set(visibleVideos.map(\.media.sourceHref))
        for (key, controller) in Array(inlineVideoControllers) where !visibleKeys.contains(key) {
            detachInlineVideoController(key: key, controller: controller)
        }
        for video in visibleVideos where EPUBVideoPlaybackManager.shared.isActive(video.media) {
            embedInlineVideo(media: video.media, frame: video.frame)
        }
    }

    private func embedInlineVideo(media: EPUBMediaAttachment, frame: CGRect) {
        let controller: AVPlayerViewController
        if let existing = inlineVideoControllers[media.sourceHref] {
            controller = existing
        } else {
            controller = AVPlayerViewController()
            controller.view.backgroundColor = .black
            controller.videoGravity = .resizeAspect
            controller.allowsPictureInPicturePlayback = true
            addChild(controller)
            controller.didMove(toParent: self)
            inlineVideoControllers[media.sourceHref] = controller
        }

        if controller.view.superview !== view {
            view.addSubview(controller.view)
        }
        controller.view.frame = frame

        let startedFresh = !EPUBVideoPlaybackManager.shared.isActive(media)
        Task { @MainActor [weak self, weak controller] in
            guard let player = await EPUBVideoPlaybackManager.shared.player(for: media) else {
                if let self, let controller {
                    self.detachInlineVideoController(key: media.sourceHref, controller: controller)
                }
                return
            }
            controller?.player = player
            if startedFresh { player.play() }
        }
    }

    private func visibleVideoAttachments() -> [(media: EPUBMediaAttachment, frame: CGRect)] {
        collectionView.visibleCells.compactMap { $0 as? CoreTextChunkCollectionCell }
            .flatMap { cell -> [(media: EPUBMediaAttachment, frame: CGRect)] in
                guard let chunk = cell.currentChunk else { return [] }
                let attachments = chunk.attachments + chunk.blockRenderables.compactMap(\.imageAttachment)
                return attachments.compactMap { attachment in
                    guard let media = attachment.mediaAttachment, media.kind == .video else { return nil }
                    let frame = cell.drawView.convert(attachment.rect, to: view)
                    guard frame.intersects(view.bounds.insetBy(dx: -32, dy: -32)) else { return nil }
                    return (media, frame)
                }
            }
    }

    private func detachInlineVideoController(key: String, controller: AVPlayerViewController) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        controller.player = nil
        inlineVideoControllers[key] = nil
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
            presentSelectionEditMenu(at: viewPoint)
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

    /// **The one definition of "where the reader is": the character under the viewport's leading
    /// edge.**
    ///
    /// Three definitions used to coexist, and no clamp or compensation can reconcile them. Chapter
    /// tracking and insert anchoring read the leading edge (here). The position that actually gets
    /// *saved*, `visibleCanonicalPosition`, read `bounds.midY` — the centre. The restore put its
    /// target back at the leading edge. Paged mode's position is the page's first character, so it
    /// is a leading edge too. Saving the centre and restoring the top cannot round-trip: every
    /// paged↔scroll switch moved the reader by half a viewport, on top of the chunk-granularity
    /// loss that `scrollToInitialRow` documents.
    private var visibleAnchorPoint: CGPoint {
        switch scrollAxis {
        case .vertical:
            let visibleY = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            return CGPoint(x: collectionView.bounds.midX, y: max(0, visibleY))
        case .horizontalRTL:
            // Vertical writing flows right to left, so the leading edge is the right one.
            let rightX = collectionView.contentOffset.x + collectionView.bounds.width
                - collectionView.adjustedContentInset.right - 1
            return CGPoint(x: max(0, rightX), y: collectionView.bounds.midY)
        }
    }

    private func visibleProgressIndexPath() -> IndexPath? {
        guard !engine.chunks.isEmpty else { return nil }
        return collectionView.indexPathForItem(at: visibleAnchorPoint)
    }

    // MARK: - Scroll offset: the single writer

    /// Who is moving the reader. Appears in `⟲ scrollpos`, so a wrong position can be attributed
    /// to one writer instead of guessed at.
    ///
    /// Down to two. `insertCompensation`, `reload` and `reloadFallback` are gone with the
    /// compensation model: every structural change now ends in `restore`, because the reader is
    /// put back at their reading position rather than nudged by however much the content moved.
    private enum ScrollOffsetSource: String {
        case restore
        case ttsFollow
    }

    /// **The only place `contentOffset` is written.**
    ///
    /// Six call sites used to set it independently, each with its own clamping — and two of those
    /// clamps disagreed, which is how a restore could land 16pt below the true top. Funnelling
    /// them here is the first step of making the reading position, not the scroll offset, the
    /// thing that decides where the reader is: a single writer is what later lets that position
    /// be re-applied instead of compensated for.
    private func setScrollOffset(
        _ proposed: CGPoint,
        source: ScrollOffsetSource,
        animated: Bool = false,
        detail: String = ""
    ) {
        let clamped = clampedScrollOffset(proposed)
        let before = collectionView.contentOffset
        if animated {
            UIView.animate(
                withDuration: 0.35,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction],
                animations: { self.collectionView.contentOffset = clamped },
                completion: { [weak self] _ in self?.didFinishAnimatedScroll(source: source) }
            )
        } else {
            collectionView.setContentOffset(clamped, animated: false)
        }
        posTrace(
            "offset.\(source.rawValue)",
            "from=\(String(format: "%.1f", scrollAxis == .vertical ? before.y : before.x)) "
                + "proposed=\(String(format: "%.1f", scrollAxis == .vertical ? proposed.y : proposed.x)) "
                + "applied=\(String(format: "%.1f", scrollAxis == .vertical ? clamped.y : clamped.x)) "
                + "clamped=\(clamped != proposed) animated=\(animated) \(detail)"
        )
    }

    /// Keeps the offset inside the scrollable range.
    ///
    /// Vertical uses the content-inset-aware bounds. The reader's natural resting offset at the
    /// top of the content is `-contentInset.top`, not zero: `reloadPreservingVisiblePosition`
    /// used to clamp to zero and so pushed the reader 16pt down from the top whenever a restore
    /// proposed anything negative — visible in device logs as `proposedY=-167.7 → 0.0`.
    ///
    /// Horizontal RTL keeps exactly the bounds it already had. Its inset relationship is mirrored
    /// and unverified here, and changing it on reasoning alone is what this whole effort has been
    /// paying for.
    private func clampedScrollOffset(_ proposed: CGPoint) -> CGPoint {
        switch scrollAxis {
        case .vertical:
            let minY = -collectionView.adjustedContentInset.top
            let maxY = max(
                minY,
                collectionView.contentSize.height - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            return CGPoint(x: proposed.x, y: min(max(minY, proposed.y), maxY))
        case .horizontalRTL:
            let minX = -max(0, collectionView.contentSize.width - collectionView.bounds.width)
            return CGPoint(x: min(max(minX, proposed.x), 0), y: proposed.y)
        }
    }

    private func didFinishAnimatedScroll(source: ScrollOffsetSource) {
        guard source == .ttsFollow else { return }
        isAutoScrollingPlayback = false
        commitProgress()
    }

    // MARK: - Position diagnostics
    //
    // Reading position on entering scroll mode has been reported wrong from a device — both when
    // reopening a book and, intermittently, when switching from paged to scroll (switching back is
    // fine). Three attempts at reasoning from the code picked the wrong cause, so this traces the
    // actual sequence instead. Filter Console on `⟲ scrollpos`.
    //
    // Deliberately event-scoped, never per scroll tick: restore, insert, reload and the mode
    // handover are the only places the position is decided.

    private func posTrace(_ event: String, _ detail: String = "") {
        AppLogger.render("⟲ scrollpos.\(event) \(detail) \(geometrySnapshot)")
    }

    /// The numbers that distinguish "we aimed at the wrong place" from "we aimed correctly and
    /// something moved us afterwards".
    private var geometrySnapshot: String {
        let axisOffset = scrollAxis == .vertical
            ? collectionView.contentOffset.y
            : collectionView.contentOffset.x
        let axisContent = scrollAxis == .vertical
            ? collectionView.contentSize.height
            : collectionView.contentSize.width
        // `chunks` vs `fragments` must match; a gap means the geometry store lost items and every
        // index after the gap resolves to the wrong chunk.
        return String(
            format: "| chunks=%d displayed=%d fragments=%d order=%@ extent=%.1f content=%.1f offset=%.1f window=%@",
            engine.chunks.count,
            displayedCount,
            engine.geometryFragmentCount,
            "\(engine.geometryChapterOrder)",
            engine.loadedScrollExtent,
            axisContent,
            axisOffset,
            collectionView.window == nil ? "no" : "yes"
        )
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
            // Same sink as the centre tap, so VoiceOver reaches the reader toolbar.
            chunkCell.onAccessibilityMenu = { [weak self] in self?.onTap?() }
            chunkCell.bind(
                chunk: chunk,
                axis: scrollAxis,
                horizontalInset: horizontalInset,
                verticalInset: verticalInset,
                leadingSpacing: chapterGap(for: indexPath.item),
                viewportSize: collectionView.bounds.size
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
            reconcileInlineVideos()
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

        reconcileInlineVideos()

        guard let path = visibleProgressIndexPath(), path.item < chunks.count else { return }

        if lastWarmRow != path.item {
            warmChunks(around: path.item)
        }
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

    /// The only place the screen is allowed to redefine `readingPosition`.
    ///
    /// Guarded against our own writes. Without the guard the cycle closes on itself:
    /// `applyReadingPositionIfPossible` → `setContentOffset` → a scroll callback →
    /// `commitProgress` → `readingPosition` overwritten with wherever the restore happened to
    /// land. That is how a precise saved offset degraded to the chapter start between reader
    /// instances (`off253 → off0` in the device log).
    private func commitProgress() {
        guard !isApplyingReadingPosition else { return }
        guard let pos = visibleCanonicalPosition() else { return }
        readingPosition = pos
        ReaderPositionSentry.shared.observeCommit(pos, source: .scrollSettle)
        AppLogger.render(
            "[ProgressTrace][ScrollVC] commit spine=\(pos.spineIndex) charOffset=\(pos.charOffset)"
        )
        onProgressCommit?(pos)
    }

    private func warmChunks(around row: Int, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || row != lastWarmRow else { return }
        guard force || now - lastWarmUptime >= 0.08 else { return }
        lastWarmRow = row
        lastWarmUptime = now
        if force {
            // Immediate, on-main: the visible region must be ready before reload.
            engine.warmChunks(around: row, radius: 2)
        } else {
            // During scrolling: build frames off-main to avoid hitching.
            engine.warmChunksAhead(around: row, radius: 2)
        }
        // The visible window moved, so this is also where frames that fell far behind
        // are released. Bounding materialized frames by distance replaces the eviction
        // that used to ride on cell reuse.
        engine.trimMaterializedChunks(around: row)
    }

    private func visibleCanonicalPosition() -> CoreTextReadingPosition? {
        guard !engine.chunks.isEmpty else { return nil }

        // Anchored on `visibleAnchorPoint` — the same edge the restore aims at — so that saving
        // and restoring are inverses of each other. This used to read `bounds.midY`, half a
        // viewport away from where it would later be put back.
        //
        // The hazard the old comment recorded is still live and still worth knowing:
        // `collectionView.bounds` already has its origin shifted by `contentOffset` (UIScrollView
        // semantics), so adding `contentOffset` to anything derived from `bounds` double-counts
        // it, throws the hit test past the content, and drops every caller into the fallback
        // below — which is what made `reloadPreservingVisiblePosition` snap to the chunk start
        // and produced the "scroll down, stop, jump back" symptom.
        if let (_, chunk, localPoint) = hitTestChunk(at: visibleAnchorPoint) {
            let char = chunk.stringIndex(atLocalPoint: localPoint) ?? chunk.charRange.location
            return CoreTextReadingPosition(spineIndex: chunk.chapterIndex, charOffset: char)
        }

        // Deliberately no chunk-start fallback. Returning the chunk's first character when the
        // hit test fails looks harmless and is not: it is a *fabricated* position that then gets
        // saved over the real one, which is how the reader's progress walked backwards to the
        // chapter start. Not knowing where the reader is means not writing anything down.
        posTrace("commit.unresolved", "anchor=\(visibleAnchorPoint)")
        return nil
    }
}


private final class CoreTextScrollFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
}
