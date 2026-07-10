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

    private let collectionView: UICollectionView
    private var cancellables: Set<AnyCancellable> = []
    private var pendingInitialScroll: (chapter: Int, charOffset: Int)?
    private var hasAppliedInitialScroll = false
    private var hasKickedOffEngine = false
    private var pendingInitialChapter: Int = 0
    private var displayedCount: Int = 0
    private var lastWarmRow: Int?
    private var lastWarmUptime: TimeInterval = 0

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
            title: localized("重點"),
            image: UIImage(systemName: "highlighter"),
            handler: { [weak self] _ in
                self?.presentEmphasisEditMenu()
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
        reconcileInlineVideos()
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
        let minOffset = -topInset
        let maxOffset = max(minOffset, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let clamped = min(max(desiredOffset, minOffset), maxOffset)
        guard clamped > collectionView.contentOffset.y + 1 else { return }

        isAutoScrollingPlayback = true
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: { self.collectionView.contentOffset.y = clamped },
            completion: { [weak self] _ in
                guard let self else { return }
                self.isAutoScrollingPlayback = false
                self.commitProgress()
            }
        )
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
            lastWarmRow = nil
            collectionView.reloadData()
        case .insertedAtBottom(let count, _):
            insertItems(count: count, atBottom: true, addedExtent: 0)
        case .insertedAtTop(let count, let addedExtent, _):
            insertItems(count: count, atBottom: false, addedExtent: addedExtent)
        }

        applyPendingInitialScrollIfPossible()
        reconcileInlineVideos()
    }

    private func insertItems(count: Int, atBottom: Bool, addedExtent: CGFloat) {
        let total = engine.chunks.count
        let actualOld = displayedCount
        let expectedOld = max(0, total - count)

        // Count desync: concurrent chapter loads (fast scrolling) leave displayedCount
        // out of step with engine.chunks, so incremental insertItems(at:) is unsafe.
        // Reload but keep the reader's position — never reset to chapter start.
        guard actualOld == expectedOld else {
            reloadPreservingVisiblePosition()
            return
        }

        warmChunks(around: atBottom ? actualOld : count, force: true)
        guard actualOld > 0, collectionView.window != nil else {
            reloadPreservingVisiblePosition()
            return
        }

        // RTL columns (vertical writing): the frame-anchor offset math below is unreliable
        // (it can fling the offset to a garbage value). Restore by reading position instead.
        if !atBottom && scrollAxis == .horizontalRTL {
            reloadPreservingVisiblePosition()
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
        collectionView.performBatchUpdates {
            self.displayedCount = total
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

    /// Reloads the collection view while keeping the reader at the same content
    /// position. Used when incremental insertion can't be trusted (count desync,
    /// RTL prepend) so the reader never snaps back to the chapter start.
    private func reloadPreservingVisiblePosition() {
        let anchor = visibleCanonicalPosition()
        displayedCount = engine.chunks.count
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        guard let anchor,
              let row = engine.chunkIndex(forChapter: anchor.spineIndex, charOffset: anchor.charOffset),
              row < collectionView.numberOfItems(inSection: 0) else { return }
        let position: UICollectionView.ScrollPosition =
            scrollAxis == .vertical ? .centeredVertically : .centeredHorizontally
        collectionView.scrollToItem(at: IndexPath(item: row, section: 0), at: position, animated: false)
    }

    private func applyPendingInitialScrollIfPossible() {
        guard !hasAppliedInitialScroll, let target = pendingInitialScroll else { return }
        guard let row = engine.chunkIndex(forChapter: target.chapter, charOffset: target.charOffset),
              row < engine.chunks.count else { return }
        let chunkStart = engine.chunks[row].charRange.location
        print("[ProgressTrace][ScrollVC] restoreLanding target=(ch\(target.chapter),off\(target.charOffset)) -> row=\(row) chunkStartOffset=\(chunkStart) lostWithinChunk=\(target.charOffset - chunkStart)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.scrollToInitialRow(row) else { return }
            self.warmChunks(around: row, force: true)
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
            collectionView.scrollToItem(
                at: path,
                at: scrollAxis.initialScrollPosition,
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

    private func commitProgress() {
        guard let pos = visibleCanonicalPosition() else { return }
        print("[ProgressTrace][ScrollVC] commit(visibleCenter) spine=\(pos.spineIndex) charOffset=\(pos.charOffset)")
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
    }

    private func visibleCanonicalPosition() -> CoreTextReadingPosition? {
        guard !engine.chunks.isEmpty else { return nil }

        let visibleCenter = CGPoint(
            x: collectionView.bounds.midX + collectionView.contentOffset.x,
            y: collectionView.bounds.midY + collectionView.contentOffset.y
        )

        if let (_, chunk, localPoint) = hitTestChunk(at: visibleCenter) {
            let char = chunk.stringIndex(atLocalPoint: localPoint) ?? chunk.charRange.location
            return CoreTextReadingPosition(spineIndex: chunk.chapterIndex, charOffset: char)
        }

        guard let path = visibleProgressIndexPath(),
              path.item < engine.chunks.count else { return nil }
        let chunk = engine.chunks[path.item]
        return CoreTextReadingPosition(spineIndex: chunk.chapterIndex, charOffset: chunk.charRange.location)
    }
}

private final class CoreTextScrollFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
}
