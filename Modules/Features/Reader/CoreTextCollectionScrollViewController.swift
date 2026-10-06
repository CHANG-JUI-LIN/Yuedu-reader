import YueduCoreText
import os
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
    /// Vertical axis only. The bands come out of the collection view's frame so
    /// the text is genuinely clipped at the bars; the margins are ordinary
    /// `contentInset` inside what is left.
    private var barInsets: ReaderScrollBarInsets = .zero
    private var collectionTopConstraint: NSLayoutConstraint?
    private var collectionBottomConstraint: NSLayoutConstraint?
    var bottomMargin: CGFloat = 0
    var onProgressCommit: ((CoreTextReadingPosition) -> Void)?
    var onTap: (() -> Void)?
    /// The reader's finger started scrolling (never an app-driven scroll).
    var onUserScrollBegan: (() -> Void)?
    var onInternalLinkTap: ((String) -> Void)?
    private(set) var lastAppliedRefreshTransactionID: UInt64 = 0

    private let collectionView: UICollectionView
    let fragmentHost = ReaderViewportFragmentHost(frame: .zero)
    private var frameDiagnostics: ReaderScrollFrameDiagnostics?
    private var lastBridgeViewportSize: CGSize = .zero
    private var cancellables: Set<AnyCancellable> = []
    /// The latest explicit navigation target or settled reading checkpoint.
    ///
    /// Explicit restores derive `contentOffset` from this. Geometry changes during
    /// scrolling instead preserve the live painted anchor, including its fractional
    /// screen position. Only four things write this checkpoint: the
    /// handover from paged mode / cold start, a scroll the *user* performed, a TTS follow, and a
    /// navigation request. Chapter loads deliberately do not — that was the compensation model,
    /// and it could not be made to work. Two overlapping `performBatchUpdates` completions each
    /// computed their offset delta against geometry the other had already changed, which a device
    /// log caught red-handed: `insertCompensation … applied=27195.3` immediately followed by
    /// `… applied=13908.3`, a whole chapter down and back up again.
    /// Read freely; write only through `setReadingPosition`.
    ///
    /// The invariant above was documented and unenforced: four places assigned this and
    /// one of them told the sentry. Naming the writer at each site is what turns the
    /// comment into something the log can check — in particular the engine-reset write,
    /// which is the chapter-load path the invariant says must not move anyone.
    private var storedReadingPosition: CoreTextReadingPosition?
    private var readingPosition: CoreTextReadingPosition? { storedReadingPosition }

    private enum ReadingPositionWrite {
        var label: String {
            switch self {
            case .handoff: return "handoff"
            case .reslice: return "reslice"
            case .engineReset: return "engineReset"
            case .settle: return "settle"
            }
        }

        /// Opening the book, or arriving from paged mode. Declared upstream by
        /// `moveReaderSession`, so it is not re-reported here.
        case handoff
        /// Re-asserting the same position across a re-slice; not a move.
        case reslice
        /// The engine overriding what this controller held. The one write the invariant
        /// above says should not be able to move anyone — so it is checked, not trusted.
        case engineReset
        /// The reader came to rest.
        case settle(readerDriven: Bool)
    }

    private func setReadingPosition(
        _ position: CoreTextReadingPosition?,
        _ write: ReadingPositionWrite
    ) {
        let previous = storedReadingPosition
        storedReadingPosition = position

        switch write {
        case .handoff, .reslice:
            posTrace(
                "position.\(write.label)",
                "to=\(position.map(Self.describe) ?? "nil")"
            )
        case .engineReset:
            posTrace(
                "position.engineReset",
                "from=\(previous.map(Self.describe) ?? "nil") to=\(position.map(Self.describe) ?? "nil")"
            )
            // A reset is allowed to *hold* the position; it is not allowed to *change* it.
            if let previous, let position, previous != position {
                ReaderPositionSentry.shared.observeScrollGeometryChange(
                    expected: previous,
                    landed: position,
                    cause: .reload
                )
            }
        case let .settle(readerDriven):
            guard let position else { return }
            ReaderPositionSentry.shared.observeCommit(
                position, source: .scrollSettle, readerDriven: readerDriven
            )
        }
    }
    /// Whether `readingPosition` has been put on screen at least once. Until it has, the reader is
    /// showing whatever the collection view happened to lay out, not a position anyone chose.
    private var hasAppliedReadingPosition = false
    /// Set while we are writing an offset ourselves, so scroll callbacks do not turn our own
    /// programmatic scroll back into a "the user moved" signal. Without it the restore overwrote
    /// the position it had just restored: the device log shows the saved offset flipping
    /// `off253 → off0 → off253` across successive reader instances.
    private var isApplyingReadingPosition = false
    /// Where the reader was when the app last left the foreground, held until the next
    /// layout pass after it comes back. Coming back must not move anyone; this is what
    /// turns that sentence into something the log can check.
    private var positionAtResignActive: CoreTextReadingPosition?
    private var awaitingForegroundVerification = false
    /// Last observed content offset on the scrolling axis, for attributing movement.
    private var lastObservedAxisOffset: CGFloat?
    /// The previous committed position, so each commit can record how far it moved.
    private var lastCommittedPosition: CoreTextReadingPosition?
    private var hasKickedOffEngine = false
    private var pendingInitialChapter: Int = 0
    private struct ViewportItemID: Hashable {
        let spine: Int
        let ordinal: Int
    }
    private struct ViewportAnchor {
        let spine: Int
        let offset: Int
        let screenY: CGFloat
    }
    private var displayedViewportIDs: [ViewportItemID] = []
    private var displayedCount: Int = 0 {
        didSet { displayedViewportIDs = viewportItemIDs() }
    }
    private func viewportItemIDs() -> [ViewportItemID] {
        var ordinals: [Int: Int] = [:]
        return engine.chunks.map { item in
            let ordinal = ordinals[item.chapterIndex, default: 0]
            ordinals[item.chapterIndex] = ordinal + 1
            return ViewportItemID(spine: item.chapterIndex, ordinal: ordinal)
        }
    }
    private var isResolvingViewport = false
    /// A restore whose target was not laid out yet: the arriving layout re-applies
    /// it exactly. Dropped as soon as the user starts scrolling.
    private var restoreAwaitingLayout: CoreTextReadingPosition?
    /// Layout is requested ahead of the viewport in the direction of travel.
    private var lastViewportRequestY: CGFloat?
    private var viewportRequestDirection: CGFloat = 1
    private(set) var viewportCommitDiagnostics = ViewportCommitDiagnostics()
    private var awaitingMomentumOffset: CGFloat?
    #if DEBUG
    var onViewportDiagnostics: ((ViewportCommitDiagnostics) -> Void)?
    var onDeceleratingScroll: (() -> Void)?
    #endif
    private var lastWarmRow: Int?
    private var lastWarmUptime: TimeInterval = 0
    private var resliceTask: Task<Void, Never>?
    private var pendingVisibleRefreshCompletion: ((Bool) -> Void)?

    private var selectionChapter: Int?
    private var selectedText: String?
    private var latestEditMenuSourcePoint: CGPoint?
    private let interactor = TextSelectionInteractor()
    private var playbackHighlight: ReaderPlaybackHighlight?
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

        let layout: UICollectionViewLayout
        if axis == .vertical {
            layout = ReaderScrollLayout()
        } else {
            let flow = CoreTextScrollFlowLayout()
            flow.scrollDirection = axis.collectionScrollDirection
            flow.minimumLineSpacing = 0
            flow.minimumInteritemSpacing = 0
            layout = flow
        }
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(nibName: nil, bundle: nil)
        (layout as? ReaderScrollLayout)?.extentProvider = { [weak self] index in
            guard let self else { return 0 }
            return (self.engine.scrollExtent(at: index) ?? 0) + self.chapterGap(for: index)
        }
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

        // Leaving and returning is a structural change like any other: chapters may be
        // re-sliced, cells rebuilt, the viewport re-laid-out. The reader must come back to
        // the same place. Verified on the next layout pass rather than after a delay —
        // that pass is the real signal that the rebuild finished.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.positionAtResignActive = self.visibleCanonicalPosition()
                self.posTrace(
                    "phase.resign",
                    "at=\(self.positionAtResignActive.map(Self.describe) ?? "unresolved")"
                )
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.awaitingForegroundVerification = self.positionAtResignActive != nil
                self.posTrace("phase.active", "verifying=\(self.awaitingForegroundVerification)")
            }
        }

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // 上下滑動 is the only reading mode whose canvas is a real scroll view, so iOS
        // 26 paints its scroll-edge effect over the top of the page — an opaque band
        // under the toolbar that 翻頁 never gets, because a paged canvas is not a
        // scroll view. The reader owns every pixel of its surface; the two modes have
        // to read the same, with the text running under the glass controls.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
        }
        #endif
        collectionView.register(CoreTextChunkCollectionCell.self, forCellWithReuseIdentifier: CoreTextChunkCollectionCell.reuseIdentifier)
        collectionView.register(BrowserScrollTileCell.self, forCellWithReuseIdentifier: BrowserScrollTileCell.reuseIdentifier)
        collectionView.contentInset = contentInset

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.allowsSelection = false
        view.addSubview(collectionView)
        collectionView.insertSubview(fragmentHost, at: 0)
        let topConstraint = collectionView.topAnchor.constraint(
            equalTo: view.topAnchor,
            constant: barInsets.topBand
        )
        let bottomConstraint = view.bottomAnchor.constraint(
            equalTo: collectionView.bottomAnchor,
            constant: barInsets.bottomBand
        )
        collectionTopConstraint = topConstraint
        collectionBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            topConstraint,
            bottomConstraint,
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        collectionView.addGestureRecognizer(tapGesture)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        longPress.minimumPressDuration = 0.4
        longPress.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(longPress)

        configureTapPriority()
        bindEngine()
        if scrollAxis == .vertical { frameDiagnostics = ReaderScrollFrameDiagnostics(scrollView: collectionView) }
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
        let point = touch.location(in: collectionView)
        if let index = collectionView.indexPathForItem(at: point),
           let cell = collectionView.cellForItem(at: index) as? BrowserScrollTileCell {
            if gestureRecognizer is UILongPressGestureRecognizer { return false }
            if gestureRecognizer === tapGesture {
                return !cell.ownsTap(at: touch.location(in: cell))
            }
        }
        return true
    }

    override var canBecomeFirstResponder: Bool { return true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard selectedText?.isEmpty == false else { return false }
        return action == #selector(copy(_:))
            || (action == #selector(underlineSelection(_:)) && !selectionTouchesTranslation)
    }

    /// Whether the selection covers any of 整章翻譯's translated text.
    private var selectionTouchesTranslation: Bool {
        guard let chapter = selectionChapter, let range = currentSelectionRange else { return false }
        return engine.isTranslation(chapter: chapter, range: range)
    }

    /// The chunk text of a chapter — its own text, or with translations spliced in.
    private func displayedChapterText(_ chapter: Int) -> String? {
        engine.chunks.first(where: { $0.chapterIndex == chapter })?.attributedString.string
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

        // AI items only with Pro (`ReaderPremiumVisibilityPolicy.showsAISelectionActions`).
        let premium = ReaderPremiumVisibilityPolicy(isProActive: SubscriptionStore.shared.isProActive)
        // A translation is not the book's text: nothing to highlight, note or replace there,
        // and nothing the assistant could cite.
        if selectionTouchesTranslation {
            let lookup = premium.showsAISelectionActions && AIWordLookup.isCandidate(selectedText ?? "")
            return UIMenu(children: suggestedActions + (lookup ? [aiSelectionAction(.lookup)] : []))
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
        let canEditNote = premium.allowsParagraphNoteEditing
        actions.append(UIAction(
            title: localized(selectionHasNote ? "編輯筆記" : "筆記"),
            image: UIImage(systemName: canEditNote ? "note.text" : "lock.fill"),
            handler: { [weak self] _ in
                self?.requestNoteEdit()
            }
        ))
        if premium.showsAISelectionActions {
            for action in AIReadingAction.selectionMenu(for: selectedText ?? "") {
                actions.append(aiSelectionAction(action))
            }
        }
        return UIMenu(children: actions)
    }

    private func aiSelectionAction(_ action: AIReadingAction) -> UIAction {
        UIAction(title: action.title, image: UIImage(systemName: "sparkles")) { [weak self] _ in
            guard let self, let spine = selectionChapter, let range = currentSelectionRange,
                  let text = selectedText, range.length == text.utf16.count else { return }
            let stored = engine.bookRange(chapter: spine, range: range)
            pendingAISelection = .init(spineIndex: spine, range: stored ?? range, text: text, action: action,
                                       context: displayedChapterText(spine).map { AIWordLookup.context(in: $0, range: range) },
                                       isTranslation: stored == nil)
            editMenuInteraction.dismissMenu()
        }
    }

    private var pendingAISelection: CoreTextAISelectionRequest?

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in
            guard let self, let request = pendingAISelection else { return }
            pendingAISelection = nil
            clearSelection()
            NotificationCenter.default.post(name: .coreTextAISelectionRequested, object: self, userInfo: ["request": request])
        }
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
              range.length > 0,
              let stored = engine.bookRange(chapter: chapter, range: range)
        else { return }
        NotificationCenter.default.post(
            name: .coreTextUnderlineSelectionRequested,
            object: self,
            userInfo: [
                "request": CoreTextUnderlineSelectionRequest(
                    position: CoreTextReadingPosition(spineIndex: chapter, charOffset: stored.location),
                    length: stored.length,
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
              range.length > 0,
              let stored = engine.bookRange(chapter: chapter, range: range)
        else { return }
        NotificationCenter.default.post(
            name: .coreTextNoteEditRequested,
            object: self,
            userInfo: [
                "request": CoreTextNoteEditRequest(
                    position: CoreTextReadingPosition(spineIndex: chapter, charOffset: stored.location),
                    length: stored.length,
                    excerpt: selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            ]
        )
        clearSelection()
    }

    private func postNoteEditRequest(for annotation: CoreTextTextAnnotation) {
        guard let stored = engine.bookRange(chapter: annotation.spineIndex, range: annotation.range, annotationID: annotation.id)
        else { return }
        NotificationCenter.default.post(
            name: .coreTextNoteEditRequested,
            object: self,
            userInfo: [
                "request": CoreTextNoteEditRequest(
                    position: CoreTextReadingPosition(
                        spineIndex: annotation.spineIndex,
                        charOffset: stored.location
                    ),
                    length: stored.length,
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
        applyReadingPositionIfPossible(cause: .initialLayout)
        resolveVisibleViewport()
        verifyForegroundRestoreIfNeeded()
        reconcileInlineVideos()
    }

    /// The first layout pass after returning to the foreground, compared against where the
    /// reader was when the app left it.
    private func verifyForegroundRestoreIfNeeded() {
        guard awaitingForegroundVerification, let before = positionAtResignActive else { return }
        awaitingForegroundVerification = false
        positionAtResignActive = nil
        ReaderPositionSentry.shared.observeScrollGeometryChange(
            expected: before,
            landed: visibleCanonicalPosition(),
            cause: .foregroundResume
        )
    }

    private static func describe(_ position: CoreTextReadingPosition) -> String {
        "(ch\(position.spineIndex),off\(position.charOffset))"
    }

    func setInitialPosition(chapter: Int, charOffset: Int) {
        // Entry point for both "open the book" and "switch from paged to scroll" — the two cases
        // that land wrong. If the target logged here is already wrong, the fault is upstream in
        // whoever computed the handover position, not in this controller.
        posTrace("setInitialPosition", "target=(ch\(chapter),off\(charOffset))")
        setReadingPosition(
            CoreTextReadingPosition(spineIndex: chapter, charOffset: charOffset), .handoff
        )
        hasAppliedReadingPosition = false
        pendingInitialChapter = chapter
        applyReadingPositionIfPossible(cause: .initialLayout)
    }

    func update(
        axis: CoreTextScrollAxis,
        horizontal: CGFloat,
        vertical: CGFloat,
        bottomMargin: CGFloat = 0,
        barInsets: ReaderScrollBarInsets = .zero
    ) {
        let viewportSize = collectionView.bounds.size
        defer { lastBridgeViewportSize = viewportSize }
        // SwiftUI also updates this host for progress/chrome and engine publishes.
        // Engine events own content insertion/reset; unchanged vertical geometry
        // must not invalidate flow layout, reload cells, and redraw their tiles.
        // Keep the horizontal-RTL path unchanged in this scroll performance fix.
        if axis == .vertical, scrollAxis == .vertical,
           viewportSize == lastBridgeViewportSize,
           horizontal == horizontalInset, vertical == verticalInset,
           bottomMargin == self.bottomMargin, barInsets == self.barInsets {
            return
        }
        let oldExtent = currentContentExtent
        let oldImageExtent = currentImageContentWidth
        let restoreChapter = visibleProgressChapter()
        let axisChanged = axis != scrollAxis
        scrollAxis = axis
        if axis != .vertical { fragmentHost.reset() }
        horizontalInset = horizontal
        verticalInset = vertical
        self.bottomMargin = bottomMargin
        applyBarInsets(axis == .vertical ? barInsets : .zero)
        collectionView.contentInset = contentInset
        collectionView.semanticContentAttribute = axis.semanticContentAttribute
        if axisChanged {
            let layout: UICollectionViewLayout
            if axis == .vertical {
                let vertical = ReaderScrollLayout()
                vertical.extentProvider = { [weak self] index in
                    guard let self else { return 0 }
                    return (self.engine.scrollExtent(at: index) ?? 0) + self.chapterGap(for: index)
                }
                layout = vertical
            } else {
                let flow = CoreTextScrollFlowLayout()
                flow.scrollDirection = axis.collectionScrollDirection
                flow.minimumLineSpacing = 0
                flow.minimumInteritemSpacing = 0
                layout = flow
            }
            collectionView.setCollectionViewLayout(layout, animated: false)
        }
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

    func setTextAnnotations(_ stored: [CoreTextTextAnnotation]) {
        // Drawn and hit-tested in chunk text, which 整章翻譯 may have spliced translations into.
        let annotations = engine.displayed(stored)
        textAnnotations = annotations
        // Refresh visible cells
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: indexPath) as? CoreTextChunkCollectionCell {
                cell.applyAnnotations(annotations)
            } else if let cell = collectionView.cellForItem(at: indexPath) as? BrowserScrollTileCell {
                cell.applyAnnotations(annotations)
            }
        }
    }

    func setPlaybackHighlight(_ highlight: ReaderPlaybackHighlight?) {
        let changed = highlight != playbackHighlight
        playbackHighlight = highlight.map(engine.displayed)
        for cell in collectionView.visibleCells.compactMap({ $0 as? CoreTextChunkCollectionCell }) {
            cell.applyPlaybackHighlight(playbackHighlight)
        }
        for cell in collectionView.visibleCells.compactMap({ $0 as? BrowserScrollTileCell }) {
            cell.applyPlaybackHighlight(playbackHighlight)
        }
        if changed, highlight != nil {
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
        if highlightRect == nil {
            highlightRect = collectionView.visibleCells.compactMap { ($0 as? BrowserScrollTileCell)?.playbackHighlightBounds(in: collectionView) }.first
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
        requestReslice(to: CoreTextReadingPosition(spineIndex: chapter, charOffset: charOffset), completion: completion)
    }

    /// Keeps the whole position, including a place inside a translation (整章翻譯).
    private func requestReslice(
        to position: CoreTextReadingPosition,
        completion: ((Bool) -> Void)?
    ) {
        let chapter = position.spineIndex
        let extent = currentContentExtent
        let imageExtent = currentImageContentWidth
        let viewportExtent = currentViewportExtent
        guard extent > 0 else { return }
        resliceTask?.cancel()
        pendingVisibleRefreshCompletion = completion
        resliceTask = Task { [weak self] in
            guard let self = self else { return }
            self.hasAppliedReadingPosition = false
            self.setReadingPosition(position, .reslice)
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
            self.applyReadingPositionIfPossible(force: true, cause: .refresh)
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

        requestReslice(to: commit.position) { [weak self] succeeded in
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
            // Only the 上下邊距. The header/footer bands are gone from the frame,
            // not padded around inside it — padding does not clip, and text that
            // scrolled into a padded region drew straight over the bars.
            return UIEdgeInsets(
                top: barInsets.topMargin,
                left: 0,
                bottom: barInsets.bottomMargin,
                right: 0
            )
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
    /// What one "page" is worth in 捲動 mode: the visible band between the bars,
    /// which is what the reader actually sees move.
    var autoScrollViewportHeight: CGFloat {
        collectionView.bounds.height
    }

    /// 自動閱讀 in 捲動 mode: legado's `ContentTextView.scroll(-scrollOffset)`.
    ///
    /// Goes through `setScrollOffset` like everything else — six call sites once
    /// wrote `contentOffset` with their own clamping and two of them disagreed,
    /// which is how a restore could land 16pt off.
    ///
    /// - Returns: false once the content cannot move any further, which ends the
    ///   mode the way legado's `fillPage` returning false does.
    @discardableResult
    func autoScroll(by points: CGFloat) -> Bool {
        guard scrollAxis == .vertical, points > 0, points.isFinite else { return true }
        let before = collectionView.contentOffset
        setScrollOffset(
            CGPoint(x: before.x, y: before.y + points),
            source: .autoRead,
            animated: false
        )
        return collectionView.contentOffset.y > before.y
    }

    /// Assigned before the view loads; `viewDidLoad` builds the constraints from it.
    func setInitialBarInsets(_ insets: ReaderScrollBarInsets) {
        guard !isViewLoaded else {
            applyBarInsets(insets)
            collectionView.contentInset = contentInset
            return
        }
        barInsets = insets
    }

    /// Moves the two bands in or out of the collection view's frame.
    ///
    /// A frame change here alters the visible height, so the layout has to be
    /// invalidated: cells are sized against `collectionView.bounds`.
    private func applyBarInsets(_ newValue: ReaderScrollBarInsets) {
        guard newValue != barInsets else { return }
        barInsets = newValue
        collectionTopConstraint?.constant = newValue.topBand
        collectionBottomConstraint?.constant = newValue.bottomBand
        collectionView.collectionViewLayout.invalidateLayout()
        view.setNeedsLayout()
    }

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
        // The engine publishes these events on MainActor after committing both
        // chunks and chapterRanges. Commit the collection outline in the same
        // transaction: RunLoop.main's Combine scheduler waits for default mode
        // during a drag, leaving displayedCount stale and suspending viewport
        // layout until the finger lifts (Fixed Viewport.trace: 25.936–32.073s).
        engine.events
            .sink { [weak self] event in
                self?.handle(event: event)
            }
            .store(in: &cancellables)
        engine.onViewportSnapshot = { [weak self] spine, install in
            guard let self else { install(); return }
            viewportSnapshotArrived(spine: spine, install: install)
        }

        engine.$displayedTextAnnotations
            .receive(on: RunLoop.main)
            .sink { [weak self] annotations in
                self?.textAnnotations = annotations
                for indexPath in self?.collectionView.indexPathsForVisibleItems ?? [] {
                    if let cell = self?.collectionView.cellForItem(at: indexPath) as? CoreTextChunkCollectionCell {
                        cell.applyAnnotations(annotations)
                    } else if let cell = self?.collectionView.cellForItem(at: indexPath) as? BrowserScrollTileCell {
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
            fragmentHost.reset()
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
                setReadingPosition(restorePosition, .engineReset)
            }
            hasAppliedReadingPosition = false
            displayedCount = engine.chunks.count
            lastWarmRow = nil
            collectionView.reloadData()
            applyReadingPositionIfPossible(force: true, cause: .reload)
        case .chunksInserted(let range, _):
            applyChunkInsertion(range)
        }

        reconcileInlineVideos()
    }

    /// Commit new items and the live anchor correction together, for both paint
    /// backends. Only an initial/unresolved viewport uses the saved restore target.
    private func applyChunkInsertion(_ range: Range<Int>) {
        if hasAppliedReadingPosition, scrollAxis == .vertical,
           let anchor = visibleVerticalAnchor() {
            // A chapter arriving while the finger is moving must preserve the
            // live cell's source position, not the last scroll-end checkpoint.
            // Read the old cell itself: engine indices already include the insertion.
            // The anchor's chapter keeps its committed snapshot; a region it
            // still lacks is requested below and arrives as its own transaction.
            isResolvingViewport = true
            commitViewportGeometry(anchor: anchor, cause: "chapterInsertion")
            isResolvingViewport = false
            resolveVisibleViewport()
            return
        }
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
                self.applyReadingPositionIfPossible(force: true, cause: .chunkInsertion)
            }
            return
        }

        displayedCount = total
        lastWarmRow = nil
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        applyReadingPositionIfPossible(force: true, cause: .chunkInsertion)
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
    private func applyReadingPositionIfPossible(
        force: Bool = false,
        cause: ReaderPositionSentry.ScrollGeometryCause = .unspecified
    ) -> Bool {
        guard !isResolvingViewport, force || !hasAppliedReadingPosition else { return false }
        guard let target = readingPosition else { return false }
        defer { updateFragmentSurfaces() }
        if scrollAxis == .vertical, let chapter = engine.browserChapter(at: target.spineIndex),
           chapter.isViewportDriven {
            // Laid out on the chapter's thread. Until it arrives the reader lands on
            // the estimated position; the arriving layout re-applies this target.
            let bounds = CGRect(x: 0, y: chapter.documentY(for: target.charOffset),
                                width: engine.contentWidth, height: max(1, collectionView.bounds.height))
            let laidOut = chapter.materializedBounds.contains(bounds)
                && chapter.document.documentPoint(forCharOffset: target.charOffset) != nil
            restoreAwaitingLayout = laidOut ? nil : target
            engine.requestViewport(chapter: target.spineIndex, bounds: bounds, anchorOffset: target.charOffset)
        }
        // Chunk text offset: the same as the position's unless translations are spliced in.
        let targetOffset = engine.displayOffset(for: target)
        guard let row = engine.chunkIndex(
            forChapter: target.spineIndex,
            charOffset: targetOffset
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
                + "withinChunkChars=\(targetOffset - chunk.charRange.location)"
        )
        guard scrollToRow(row, charOffset: targetOffset) else { return false }
        warmChunks(around: row, force: true)
        // The whole contract of this method is that the reader ends up where they were.
        // Checking it here rather than at each caller is deliberate: every structural
        // change funnels through this one call, so a new one cannot be added without
        // being covered.
        ReaderPositionSentry.shared.observeScrollGeometryChange(
            expected: target,
            landed: visibleCanonicalPosition(),
            cause: cause
        )
        ReaderPositionSentry.shared.observeChunkOrder(
            engine.chunks.map(\.chapterIndex),
            cause: cause
        )
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
                y: frame.minY + chapterGap(for: row) + withinChunk - collectionView.adjustedContentInset.top
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
        let browserVideos = collectionView.visibleCells.compactMap { $0 as? BrowserScrollTileCell }
            .flatMap { cell -> [(media: EPUBMediaAttachment, frame: CGRect)] in
                guard let tile = cell.currentTile else { return [] }
                return cell.interactiveView.displayList.items.compactMap { item in
                    guard case .image(let image) = item,
                          let media = tile.chapter.mediaAttachments[image.nodeID], media.kind == .video else { return nil }
                    let frame = cell.interactiveView.convert(image.rect.rawValue, to: view)
                    guard frame.intersects(view.bounds.insetBy(dx: -32, dy: -32)) else { return nil }
                    return (media, frame)
                }
            }
        return browserVideos + collectionView.visibleCells.compactMap { $0 as? CoreTextChunkCollectionCell }
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
        /// 自動閱讀's continuous scroll. Sixty writes a second, so it is the one
        /// source that does not trace — see `setScrollOffset`.
        case autoRead
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
        // A per-frame source would fill the log with sixty identical lines a
        // second and drown the traces that exist to explain position bugs.
        guard source != .autoRead else { return }
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
        // Narration moved the reader, not their finger — and narration declares itself as
        // an intent, so this is accounted for without claiming the reader did it.
        commitProgress(readerDriven: false, reason: "programmatic")
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

    private func visibleVerticalAnchor() -> ViewportAnchor? {
        if let (cell, chunk, local) = hitTestChunk(at: visibleAnchorPoint),
           let offset = chunk.readingOffset(atVerticalOffset: local.y) {
            let lineY = chunk.topOffset(forCharacterIndex: offset) ?? 0
            let point = cell.drawView.convert(CGPoint(x: 0, y: lineY), to: collectionView)
            return ViewportAnchor(spine: chunk.chapterIndex, offset: offset,
                                  screenY: point.y - collectionView.contentOffset.y)
        }
        if let painted = fragmentHost.textAnchor(in: collectionView, visible: collectionView.bounds) {
            return ViewportAnchor(spine: painted.spine, offset: painted.offset,
                                  screenY: painted.lineY - collectionView.contentOffset.y)
        }
        // A cold jump or image-only viewport may have no painted text yet.
        // Keep the existing source/estimated geometry route for that case.
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let cells = collectionView.visibleCells.compactMap { $0 as? BrowserScrollTileCell }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard let cell = cells.first(where: { $0.frame.maxY > top }), let tile = cell.currentTile,
              tile.chapter.isViewportDriven else { return nil }
        let local = cell.interactiveView.convert(CGPoint(x: 0, y: top), from: collectionView)
        let offset = tile.chapter.sourceOffset(at: tile.documentRect.minY + max(0, cell.tileLocalPoint(fromRenderingPoint: local).y))
        let point = collectionView.convert(CGPoint(x: 0, y: tile.chapter.documentY(for: offset) - cell.renderingDocumentRect.minY),
                                           from: cell.interactiveView)
        return ViewportAnchor(spine: tile.chapter.spineIndex, offset: offset, screenY: point.y - collectionView.contentOffset.y)
    }

    /// Commit only after all demanded chapters have stable geometry. Existing
    /// cells keep their interaction owner; a snapshot revision refreshes paint.
    private(set) var viewportLayoutInvalidationCount = 0
    private static let viewportSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zhangruilin.yuedureader",
        category: "ReaderPerformance")

    private func commitViewportGeometry(geometryChanged: Bool = true,
                                        anchor: ViewportAnchor? = nil,
                                        cause: String = "viewport") {
        let start = SourcePerfTrace.now
        var paintUpdates = 0
        let oldIDs = displayedViewportIDs
        let newIDs = viewportItemIDs()
        let outlineChanged = oldIDs != newIDs
        let oldSize = collectionView.contentSize
        let before = collectionView.contentOffset
        let wasDragging = collectionView.isDragging
        let wasDecelerating = collectionView.isDecelerating
        var correction: CGFloat = 0
        var anchorY: CGFloat?
        let oldCount = displayedCount
        if let layout = collectionView.collectionViewLayout as? ReaderScrollLayout {
            // Resolve the new anchor from the new extents before UIKit changes any
            // cell or offset. Never consult an old index path after chapter insertion.
            let extents = engine.chunks.indices.map {
                (engine.scrollExtent(at: $0) ?? 0) + chapterGap(for: $0)
            }
            if let anchor,
               let row = engine.chunkIndex(forChapter: anchor.spine, charOffset: anchor.offset) {
                let origin = layout.snappedOrigin(extents.prefix(row).reduce(0, +))
                let within = engine.chunks[row].topOffset(forCharacterIndex: anchor.offset) ?? 0
                let y = origin + chapterGap(for: row) + within
                anchorY = y
                correction = y - anchor.screenY - before.y
            }
            if geometryChanged || outlineChanged || abs(correction) > 0.01 {
                let newSize = CGSize(width: collectionView.bounds.width, height: extents.reduce(0, +))
                let invalidate = {
                    self.viewportLayoutInvalidationCount += 1
                    layout.commitViewportGeometry(offsetAdjustment: CGPoint(x: 0, y: correction),
                                                  oldSize: oldSize, newSize: newSize)
                }
                UIView.performWithoutAnimation {
                    if outlineChanged {
                        let oldSet = Set(oldIDs), newSet = Set(newIDs)
                        let deletes = oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) }
                            .map { IndexPath(item: $0, section: 0) }
                        let inserts = newIDs.indices.filter { !oldSet.contains(newIDs[$0]) }
                            .map { IndexPath(item: $0, section: 0) }
                        collectionView.performBatchUpdates {
                            self.displayedCount = self.engine.chunks.count
                            self.collectionView.deleteItems(at: deletes)
                            self.collectionView.insertItems(at: inserts)
                            invalidate()
                        }
                    } else {
                        invalidate()
                    }
                    collectionView.layoutIfNeeded()
                }
            }
        }
        // Whatever this commit moved the offset by, keeping the anchor in place or the
        // offset inside a resized content, is the host's doing, not the reader's: move
        // the demand's baseline with it. Read as travel, a 0.3 pt correction turned the
        // demand around and laid out a whole screen nobody asked for.
        if let last = lastViewportRequestY {
            lastViewportRequestY = last + (collectionView.contentOffset.y - before.y)
        }
        if wasDecelerating, abs(correction) > 0.01 {
            awaitingMomentumOffset = collectionView.contentOffset.y
        }
        if let anchor, let anchorY {
            let error = anchorY - collectionView.contentOffset.y - anchor.screenY
            viewportCommitDiagnostics.record(correction: correction, screenError: error,
                wasDecelerating: wasDecelerating, isDecelerating: collectionView.isDecelerating,
                countChanged: oldCount != displayedCount, cause: cause)
            if Self.viewportSignposter.isEnabled {
                Self.viewportSignposter.emitEvent("viewport.anchorCommit",
                    "cause=\(cause) revision=\(self.engine.viewportGeometryRevision) spine=\(anchor.spine) anchor=\(anchor.offset) before=\(before.y) after=\(self.collectionView.contentOffset.y) correction=\(correction) screenError=\(error) oldTiles=\(oldCount) newTiles=\(self.displayedCount) dragBefore=\(wasDragging) dragAfter=\(self.collectionView.isDragging) decelBefore=\(wasDecelerating) decelAfter=\(self.collectionView.isDecelerating)")
            }
        }
        #if DEBUG
        onViewportDiagnostics?(viewportCommitDiagnostics)
        #endif
        for path in collectionView.indexPathsForVisibleItems {
            guard engine.chunks.indices.contains(path.item) else { continue }
            if let chunk = engine.chunks[path.item].legacyChunk,
               let cell = collectionView.cellForItem(at: path) as? CoreTextChunkCollectionCell {
                // The first retained chapter gains its inter-chapter gap when
                // its predecessor arrives. Update its local paint origin in the
                // same transaction, without invalidating unchanged glyph paint.
                cell.bind(chunk: chunk, axis: scrollAxis, horizontalInset: horizontalInset,
                          verticalInset: verticalInset, leadingSpacing: chapterGap(for: path.item),
                          viewportSize: collectionView.bounds.size)
                cell.layoutIfNeeded()
                continue
            }
            guard case .browser(let tile) = engine.chunks[path.item],
                  let cell = collectionView.cellForItem(at: path) as? BrowserScrollTileCell else { continue }
            let previousPaintUpdates = cell.paintUpdateCount
            cell.configure(tile: tile, horizontalInset: horizontalInset,
                           leadingSpacing: chapterGap(for: path.item), verticalInset: verticalInset,
                           rendersContentExternally: scrollAxis == .vertical && tile.chapter.isViewportDriven)
            paintUpdates += cell.paintUpdateCount - previousPaintUpdates
            cell.applyAnnotations(textAnnotations)
            cell.applyPlaybackHighlight(playbackHighlight)
        }
        SourcePerfTrace.record("browser.viewport.commit",
            "geometry=\(geometryChanged || outlineChanged) visibleRepaints=\(paintUpdates) tiles=\(displayedCount) offsetY=\(Int(collectionView.contentOffset.y))",
            since: start, thresholdMs: 0)
    }

    private func chapterOrigin(_ spine: Int) -> CGFloat? {
        guard let row = engine.chapterRanges[spine]?.first,
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame else { return nil }
        return frame.minY + chapterGap(for: row)
    }

    /// 捲動 mode has no pages, so one visible band between the bars counts as one —
    /// the same "page" 自動閱讀 advances by (`autoScrollViewportHeight`). Which of
    /// those pages of `spine` the top of the band is on, and how many the chapter
    /// spans. Estimated geometry (text not laid out yet) counts as it stands, so
    /// the total can settle while reading. Vertical axis only: nil for
    /// right-to-left vertical writing.
    func screenPagination(forChapter spine: Int) -> ChapterPagination? {
        let page = autoScrollViewportHeight
        guard scrollAxis == .vertical, page > 0, let top = chapterOrigin(spine),
              let last = engine.chapterRanges[spine]?.last,
              let bottom = collectionView.layoutAttributesForItem(at: IndexPath(item: last, section: 0))?.frame.maxY,
              bottom > top else { return nil }
        // Half a point of slack: a chapter exactly one screen tall is one page.
        let count = max(1, Int(ceil((bottom - top - 0.5) / page)))
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let index = min(count - 1, max(0, Int(floor((visibleTop - top + 0.5) / page))))
        return ChapterPagination(localPageIndex: index, displayPageCount: count)
    }

    /// Asks each visible viewport-driven chapter for its demand plus one screen
    /// ahead in the direction of travel. Never lays out: each chapter lays out on
    /// its own thread and its snapshot arrives as its own geometry transaction
    /// (`viewportSnapshotArrived`). Never restores the last *saved* position.
    private func resolveVisibleViewport() {
        guard scrollAxis == .vertical, !isResolvingViewport, !isApplyingReadingPosition,
              collectionView.bounds.height > 0, displayedCount == engine.chunks.count else { return }
        isResolvingViewport = true
        defer {
            updateFragmentSurfaces()
            isResolvingViewport = false
        }
        let visible = collectionView.bounds
        let movement = visible.minY - (lastViewportRequestY ?? visible.minY)
        lastViewportRequestY = visible.minY
        if movement != 0 { viewportRequestDirection = movement > 0 ? 1 : -1 }
        let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: visible) ?? []
        // Content fragments own paint. Crossing an interaction cell boundary
        // no longer demands that cell's entire screen-sized backing store.
        let paintWindow = visible.insetBy(dx: 0, dy: -1)
        let lead = visible.height
        let demandWindow = viewportRequestDirection > 0
            ? CGRect(x: paintWindow.minX, y: paintWindow.minY, width: paintWindow.width, height: paintWindow.height + lead)
            : CGRect(x: paintWindow.minX, y: paintWindow.minY - lead, width: paintWindow.width, height: paintWindow.height + lead)
        let demandAttributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: demandWindow) ?? []
        let spines = Set(demandAttributes.compactMap { attr -> Int? in
            guard engine.chunks.indices.contains(attr.indexPath.item) else { return nil }
            return engine.chunks[attr.indexPath.item].chapterIndex
        })
        let anchorY = visible.minY + collectionView.adjustedContentInset.top
        let painted = fragmentHost.textAnchor(in: collectionView, visible: visible)
        let anchorSpine = painted?.spine ?? attributes.first { $0.frame.minY <= anchorY && $0.frame.maxY > anchorY }
            .flatMap { engine.chunks.indices.contains($0.indexPath.item) ? engine.chunks[$0.indexPath.item].chapterIndex : nil }
        let chapter = anchorSpine.flatMap { engine.browserChapter(at: $0) }
        let origin = anchorSpine.flatMap { chapterOrigin($0) }
        // Keeps the text under the viewport top in place while estimates converge.
        let anchor = painted?.offset ?? chapter.flatMap { chapter in
            origin.map { chapter.sourceOffset(at: anchorY - $0) }
        }
        for spine in spines.sorted() {
            guard let origin = chapterOrigin(spine), let chapter = engine.browserChapter(at: spine),
                  chapter.isViewportDriven else { continue }
            let demand = CGRect(x: 0, y: max(0, demandWindow.minY - origin), width: engine.contentWidth,
                                height: max(1, min(chapter.document.contentHeight, demandWindow.maxY - origin) - max(0, demandWindow.minY - origin)))
            engine.requestViewport(chapter: spine, bounds: demand, anchorOffset: spine == anchorSpine ? anchor : nil)
        }
        // Residency is separate from demand. Keep the previous reversal
        // window without forcing every retained chapter to lay out now.
        let retention = collectionView.collectionViewLayout.layoutAttributesForElements(
            in: collectionView.bounds.insetBy(dx: 0, dy: -2000)) ?? []
        let retainedSpines = Set(retention.compactMap { attr -> Int? in
            guard engine.chunks.indices.contains(attr.indexPath.item) else { return nil }
            return engine.chunks[attr.indexPath.item].chapterIndex
        })
        engine.trimViewportChapters(keeping: retainedSpines.union(spines))
    }

    /// A chapter's layout arrived from its thread: one geometry transaction.
    /// The anchor is read before the new geometry is installed — the text on
    /// screen, or, while a restore still waits for its layout, the restore target.
    private func viewportSnapshotArrived(spine: Int, install: () -> Void) {
        guard scrollAxis == .vertical, collectionView.bounds.height > 0,
              displayedCount == engine.chunks.count else {
            install()
            return
        }
        let restoring = restoreAwaitingLayout?.spineIndex == spine || !hasAppliedReadingPosition
        let anchor = restoring ? nil : visibleVerticalAnchor()
        let revision = engine.viewportGeometryRevision
        isResolvingViewport = true
        install()
        commitViewportGeometry(geometryChanged: revision != engine.viewportGeometryRevision,
                               anchor: anchor, cause: "viewportLayout")
        isResolvingViewport = false
        if restoring {
            applyReadingPositionIfPossible(force: true, cause: .viewportLayout)
        } else {
            updateFragmentSurfaces()
        }
    }

    private func updateFragmentSurfaces() {
        guard scrollAxis == .vertical else { fragmentHost.reset(); return }
        let retained = collectionView.bounds.insetBy(dx: 0, dy: -collectionView.bounds.height)
        let inputs = engine.chapterRanges.keys.sorted().compactMap { spine -> ReaderViewportFragmentHost.Input? in
            guard let chapter = engine.browserChapter(at: spine), chapter.isViewportDriven,
                  !chapter.writingMode.isVertical, let origin = chapterOrigin(spine),
                  CGRect(x: 0, y: origin, width: collectionView.bounds.width,
                         height: chapter.document.contentHeight).intersects(retained) else { return nil }
            return .init(chapter: chapter, origin: CGPoint(x: horizontalInset, y: origin), width: engine.contentWidth)
        }
        let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: retained) ?? []
        let coreText = attributes.compactMap { attr -> ReaderViewportFragmentHost.CoreTextInput? in
            guard engine.chunks.indices.contains(attr.indexPath.item),
                  let chunk = engine.chunks[attr.indexPath.item].legacyChunk,
                  !chunk.writingMode.isVertical else { return nil }
            return .init(chunk: chunk, origin: CGPoint(x: horizontalInset,
                y: attr.frame.minY + chapterGap(for: attr.indexPath.item)))
        }
        fragmentHost.frame = CGRect(origin: .zero, size: collectionView.contentSize)
        collectionView.sendSubviewToBack(fragmentHost)
        fragmentHost.update(inputs, coreText: coreText, viewport: collectionView.bounds, scale: collectionView.window?.screen.scale ?? collectionView.traitCollection.displayScale)
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
        if indexPath.item < engine.chunks.count, case .browser(let tile) = engine.chunks[indexPath.item] {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BrowserScrollTileCell.reuseIdentifier,
                                                         for: indexPath) as! BrowserScrollTileCell
            cell.onAccessibilityMenu = { [weak self] in self?.onTap?() }
            cell.onLinkActivate = { [weak self, weak cell] region in
                guard let self, let cell else { return }
                if let note = FootnoteStore.text(spineIndex: region.spineIndex, href: region.href) {
                    FootnotePopoverHost.present(text: note, from: self, sourceView: cell.interactiveView,
                                                sourceRect: region.pageLocalRect)
                } else { onInternalLinkTap?(region.href) }
            }
            cell.onImageTap = { [weak self] item in
                guard let self else { return }
                if let media = tile.chapter.mediaAttachments[item.nodeID] {
                    handleMediaTap(media)
                    return
                }
                guard let image = item.image else { return }
                let attachment = CoreTextPaginator.RenderedAttachment(rect: item.rect.rawValue, image: image,
                    opacity: 1, sourceHref: item.source, alt: item.alt, linkHref: item.linkTarget,
                    originalSize: image.size)
                let preview = CoreTextImagePreviewController(attachment: attachment)
                preview.modalPresentationStyle = .fullScreen
                present(preview, animated: true)
            }
            cell.configure(tile: tile, horizontalInset: horizontalInset, leadingSpacing: chapterGap(for: indexPath.item), verticalInset: verticalInset,
                           rendersContentExternally: scrollAxis == .vertical && tile.chapter.isViewportDriven)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CoreTextChunkCollectionCell.reuseIdentifier,
            for: indexPath
        )
        if let chunkCell = cell as? CoreTextChunkCollectionCell,
           indexPath.item < engine.chunks.count,
           let chunk = engine.chunks[indexPath.item].legacyChunk {
            // Same sink as the centre tap, so VoiceOver reaches the reader toolbar.
            chunkCell.onAccessibilityMenu = { [weak self] in self?.onTap?() }
            chunkCell.rendersContentExternally = scrollAxis == .vertical && !chunk.writingMode.isVertical
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
            chunkCell.applyPlaybackHighlight(playbackHighlight)
            chunkCell.applyAnnotations(textAnnotations)
            reconcileInlineVideos()
        } else if let tileCell = cell as? BrowserScrollTileCell {
            // UIKit can prefetch this cell before a viewport commit changes
            // measured heights or restores drawing resources. Offscreen cells
            // are deliberately absent from commitViewportGeometry's refresh.
            // Rebind at the visibility boundary so old source coordinates never
            // become visible and then snap to the next snapshot.
            if case .browser(let tile) = engine.chunks[indexPath.item] {
                let stale = tileCell.currentTile?.chapter !== tile.chapter
                    || tileCell.boundRevision != tile.chapter.layoutRevision
                    || tileCell.currentTile?.documentRect != tile.documentRect
                tileCell.configure(tile: tile, horizontalInset: horizontalInset,
                                   leadingSpacing: chapterGap(for: indexPath.item), verticalInset: verticalInset,
                           rendersContentExternally: scrollAxis == .vertical && tile.chapter.isViewportDriven)
                if stale, Self.viewportSignposter.isEnabled {
                    Self.viewportSignposter.emitEvent("viewport.visibleRebind",
                        "spine=\(tile.chapter.spineIndex) row=\(indexPath.item) revision=\(tile.chapter.layoutRevision)")
                }
            }
            tileCell.applyPlaybackHighlight(playbackHighlight)
            tileCell.applyAnnotations(textAnnotations)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isResolvingViewport else { return }
        let interval = Self.viewportSignposter.beginInterval("viewport.didScroll")
        defer { Self.viewportSignposter.endInterval("viewport.didScroll", interval) }
        #if DEBUG
        if scrollView.isDecelerating { onDeceleratingScroll?() }
        #endif
        if let offset = awaitingMomentumOffset, scrollView.isDecelerating,
           abs(scrollView.contentOffset.y - offset) > 0.01 {
            viewportCommitDiagnostics.continuedDecelerations += 1
            awaitingMomentumOffset = nil
            #if DEBUG
            onViewportDiagnostics?(viewportCommitDiagnostics)
            #endif
        }
        resolveVisibleViewport()
        noteScrollAttribution(scrollView)

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

    /// Records movement nobody admits to causing.
    ///
    /// Three things may legitimately move the offset: the reader's finger (dragging or the
    /// momentum after it), and our own restore. Anything else is UIKit adjusting the offset
    /// because the content around the reader changed — which is exactly the mechanism
    /// behind a jump, and the one thing the old logs never showed. Narration, not a report:
    /// UIKit does this for benign reasons too, and its value is being the line immediately
    /// before an S1 anomaly that says *when* the content slid.
    private func noteScrollAttribution(_ scrollView: UIScrollView) {
        let offset = scrollAxis == .vertical
            ? scrollView.contentOffset.y
            : scrollView.contentOffset.x
        defer { lastObservedAxisOffset = offset }
        guard let previous = lastObservedAxisOffset else { return }

        let delta = offset - previous
        // Sub-point adjustments are device-pixel quantisation, not movement.
        guard abs(delta) > 1 else { return }
        guard !isApplyingReadingPosition,
              !scrollView.isDragging,
              !scrollView.isDecelerating
        else { return }

        ReaderPositionSentry.shared.noteUnattributedScroll(delta: delta, offset: offset)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The reader now decides the position; a layout arriving later must
        // keep what is on screen instead of returning to the restore target.
        restoreAwaitingLayout = nil
        onUserScrollBegan?()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Momentum from the reader's own flick.
        commitProgress(readerDriven: true, reason: "decelerationEnded")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { commitProgress(readerDriven: true, reason: "dragEnded") }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // An animation the app started, not a finger. If this lands somewhere nobody
        // asked for, that is exactly what the sentry should say.
        commitProgress(readerDriven: false, reason: "programmatic")
    }

    /// The only place the screen is allowed to redefine `readingPosition`.
    ///
    /// Guarded against our own writes. Without the guard the cycle closes on itself:
    /// `applyReadingPositionIfPossible` → `setContentOffset` → a scroll callback →
    /// `commitProgress` → `readingPosition` overwritten with wherever the restore happened to
    /// land. That is how a precise saved offset degraded to the chapter start between reader
    /// instances (`off253 → off0` in the device log).
    /// Lifecycle saves sample the same live anchor as a settled gesture. Leaving
    /// during a drag/auto-scroll must not flush an older gesture's checkpoint.
    func positionForPersistence() -> CoreTextReadingPosition? {
        guard hasAppliedReadingPosition, !isApplyingReadingPosition, !isResolvingViewport else { return nil }
        return visibleCanonicalPosition()
    }

    private func commitProgress(readerDriven: Bool, reason: String) {
        if isResolvingViewport { viewportCommitDiagnostics.progressDuringGeometry += 1 }
        if Self.viewportSignposter.isEnabled {
            Self.viewportSignposter.emitEvent("viewport.progressCommit",
                "reason=\(reason) geometryCommit=\(self.isResolvingViewport) dragging=\(self.collectionView.isDragging) decelerating=\(self.collectionView.isDecelerating)")
        }
        guard let pos = positionForPersistence() else { return }
        setReadingPosition(pos, .settle(readerDriven: readerDriven))
        // The displacement, not just the destination: reading a jump out of a column of
        // absolute offsets means subtracting them by hand, and the interesting ones are
        // exactly those a reader could not have scrolled through.
        let moved = lastCommittedPosition.map { previous -> String in
            previous.spineIndex == pos.spineIndex
                ? "\(pos.charOffset - previous.charOffset)"
                : "ch\(previous.spineIndex)→ch\(pos.spineIndex)"
        } ?? "first"
        lastCommittedPosition = pos
        AppLogger.render(
            "[ProgressTrace][ScrollVC] commit spine=\(pos.spineIndex)"
                + " charOffset=\(pos.charOffset) moved=\(moved)"
        )
        let apply = Self.viewportSignposter.beginInterval("viewport.progressApply",
            "spine=\(pos.spineIndex) offset=\(pos.charOffset)")
        onProgressCommit?(pos)
        Self.viewportSignposter.endInterval("viewport.progressApply", apply)
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
        if let index = collectionView.indexPathForItem(at: visibleAnchorPoint),
           let cell = collectionView.cellForItem(at: index) as? BrowserScrollTileCell,
           index.item < engine.chunks.count {
            let item = engine.chunks[index.item]
            let local = collectionView.convert(visibleAnchorPoint, to: cell.interactiveView)
            if let char = item.stringIndex(atLocalPoint: cell.tileLocalPoint(fromRenderingPoint: local)) {
                return CoreTextReadingPosition(spineIndex: item.chapterIndex, charOffset: char)
            }
        }
        if let (_, chunk, localPoint) = hitTestChunk(at: visibleAnchorPoint) {
            let offset = scrollAxis == .vertical
                ? chunk.readingOffset(atVerticalOffset: localPoint.y)
                : (chunk.stringIndex(atLocalPoint: localPoint) ?? chunk.charRange.location)
            guard let char = offset else { return nil }
            return engine.readingPosition(chapter: chunk.chapterIndex, displayOffset: char)
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
