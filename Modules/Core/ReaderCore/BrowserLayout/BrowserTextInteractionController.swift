import UIKit
import YueduCoreText

/// Reuses the reader's selection state, annotation visuals and persistence
/// requests; only the geometry comes from the browser display list.
@MainActor
final class BrowserTextInteractionController: NSObject, @preconcurrency UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    private weak var page: BrowserLayoutPageView?
    private let source: NSAttributedString
    private let paragraphRanges: [NSRange]
    let spineIndex: Int
    let selection = TextSelectionInteractor()
    private let selectionOverlay = InteractionOverlayView()
    private let noteOverlay = NoteMarkerOverlayView()
    private var annotationOverlays: [LayerKey: InteractionOverlayView] = [:]
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private lazy var handlePan = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
    private var fixedDragOffset: Int?
    private var menuVisible = false
    private var pendingMenuAction: (() -> Void)?
    var onSearch: ((String) -> Void)?
    var onTranslate: ((String) -> Void)?

    var annotations: [CoreTextTextAnnotation] {
        get { selection.textAnnotations }
        set { selection.textAnnotations = newValue; refreshAnnotations() }
    }

    init(page: BrowserLayoutPageView, sourceText: String, spineIndex: Int, paragraphRanges: [NSRange] = []) {
        self.page = page
        self.source = NSAttributedString(string: sourceText)
        self.paragraphRanges = paragraphRanges
        self.spineIndex = spineIndex
        super.init()
        selectionOverlay.fillColor = selection.selectionFillColor
        selectionOverlay.handleColor = selection.handleColor
        page.addSubview(selectionOverlay)
        page.addSubview(noteOverlay)
        page.addInteraction(editMenu)
        handlePan.delegate = self
        page.addGestureRecognizer(handlePan)
        layout()
    }

    func layout() {
        guard let page else { return }
        selectionOverlay.frame = page.bounds
        noteOverlay.frame = page.bounds
        for overlay in annotationOverlays.values { overlay.frame = page.bounds }
    }

    func sourceRange(at point: CGPoint, nearest: Bool = false) -> NSRange? {
        guard let page else { return nil }
        return BrowserTextGeometry.range(at: point, in: page.displayList, source: source.string as NSString, nearest: nearest)
    }

    func begin(at point: CGPoint) {
        guard let range = sourceRange(at: point) else { return }
        selection.beginSelection(at: range.location, in: source, spineIndex: spineIndex, maxLength: source.length,
                                 paragraphRange: paragraphRanges.first { NSLocationInRange(range.location, $0) })
        updateSelectionOverlay()
    }

    func finish() {
        selection.finalizeSelection(in: source)
        guard selection.hasSelection, let first = selectionOverlay.selectionRects.first else { return }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: first.midX, y: first.minY)))
    }

    func clear() {
        editMenu.dismissMenu()
        selection.clear()
        selectionOverlay.clearSelection()
        page?.hasActiveSelection = false
    }

    func ownsTap(at point: CGPoint) -> Bool {
        selection.hasSelection || annotation(at: point) != nil || note(at: point) != nil
    }

    @discardableResult
    func tap(at point: CGPoint) -> Bool {
        if selection.hasSelection { clear(); return true }
        if let note = note(at: point) { requestNote(note); return true }
        if let annotation = annotation(at: point) {
            selection.selectionManager.setSelection(range: annotation.range, maxLength: source.length)
            selection.tappedAnnotation = annotation
            selection.finalizeSelection(in: source)
            updateSelectionOverlay()
            finish()
            return true
        }
        return false
    }

    func refreshAnnotations() {
        guard let page else { return }
        var layers: [LayerKey: [CGRect]] = [:]
        var markers: [CoreTextAnnotationRenderer.NoteMarker] = []
        for annotation in annotations where annotation.spineIndex == spineIndex {
            let rects = BrowserTextGeometry.rects(in: page.displayList, range: annotation.range)
            guard !rects.isEmpty else { continue }
            layers[LayerKey(style: annotation.style, color: annotation.color), default: []].append(contentsOf: rects)
            if let note = annotation.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               NSLocationInRange(annotation.startOffset, page.pageSourceRange), let anchor = rects.first {
                markers.append(.init(annotationID: annotation.id, badgeRect: NoteMarkerGeometry.badgeRect(anchoredTo: anchor, isVertical: false)))
            }
        }
        for key in Array(annotationOverlays.keys) where layers[key] == nil {
            annotationOverlays.removeValue(forKey: key)?.removeFromSuperview()
        }
        for (key, rects) in layers {
            let overlay = annotationOverlays[key] ?? InteractionOverlayView(frame: page.bounds)
            if overlay.superview == nil { page.insertSubview(overlay, belowSubview: selectionOverlay) }
            overlay.showsHandles = false
            overlay.apply(layer: .init(rects: rects, style: key.style, color: key.color), isVertical: false)
            annotationOverlays[key] = overlay
        }
        noteOverlay.markers = markers
        updateSelectionOverlay()
    }

    private func annotation(at point: CGPoint) -> CoreTextTextAnnotation? {
        guard let page else { return nil }
        return annotations.first { annotation in
            annotation.spineIndex == spineIndex && BrowserTextGeometry.rects(in: page.displayList, range: annotation.range).contains { $0.contains(point) }
        }
    }

    private func note(at point: CGPoint) -> CoreTextTextAnnotation? {
        guard let marker = noteOverlay.markers.first(where: { NoteMarkerGeometry.tapRect(for: $0.badgeRect).contains(point) }) else { return nil }
        return annotations.first { $0.id == marker.annotationID }
    }

    private func updateSelectionOverlay() {
        guard let page else { return }
        let rects = selection.selectedRange.map { BrowserTextGeometry.rects(in: page.displayList, range: $0) } ?? []
        selectionOverlay.selectionRects = rects
        selectionOverlay.startHandlePoint = selection.selectedRange.flatMap {
            BrowserTextGeometry.caret(at: $0.location, isEnd: false, in: page.displayList)
        }
        selectionOverlay.endHandlePoint = selection.selectedRange.flatMap {
            BrowserTextGeometry.caret(at: NSMaxRange($0), isEnd: true, in: page.displayList)
        }
        page.hasActiveSelection = selection.hasSelection
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === handlePan, selection.hasSelection, let page else { return false }
        return handle(at: gestureRecognizer.location(in: page)) != nil
    }

    private func handle(at point: CGPoint) -> Bool? {
        for (isStart, anchor) in [(true, selectionOverlay.startHandlePoint), (false, selectionOverlay.endHandlePoint)] {
            if let anchor, CGRect(x: anchor.x - 22, y: anchor.y - 22, width: 44, height: 44).contains(point) { return isStart }
        }
        return nil
    }

    @objc private func dragHandle(_ recognizer: UIPanGestureRecognizer) {
        guard let page, let range = selection.selectedRange else { return }
        let point = recognizer.location(in: page)
        if recognizer.state == .began {
            editMenu.dismissMenu()
            fixedDragOffset = handle(at: point) == true ? NSMaxRange(range) : range.location
        }
        if recognizer.state == .began || recognizer.state == .changed,
           let fixedDragOffset, let hit = sourceRange(at: point, nearest: true) {
            let moving = hit.location < fixedDragOffset ? hit.location : NSMaxRange(hit)
            let selected = NSRange(location: min(moving, fixedDragOffset), length: abs(moving - fixedDragOffset))
            selection.selectionManager.setSelection(range: selected, maxLength: source.length)
            updateSelectionOverlay()
        }
        if recognizer.state == .ended || recognizer.state == .cancelled {
            fixedDragOffset = nil
            finish()
        }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard selection.hasSelection else { return nil }
        var actions: [UIMenuElement] = [UIAction(title: localized("複製"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = self?.selection.selectedTextForCopy
            self?.clear()
        }]
        let colors: [(AnnotationColor, String)] = [(.yellow, "黃色"), (.green, "綠色"), (.blue, "藍色"), (.pink, "粉色"), (.orange, "橙色")]
        let highlights = colors.map { color, title in
            UIAction(title: localized(title), image: UIImage(systemName: "circle.fill")?.withTintColor(color.uiColor, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.requestAnnotation(style: .highlight, color: color)
            }
        }
        actions.append(UIMenu(title: localized("重點"), children: highlights + [UIAction(title: localized("下劃線")) { [weak self] _ in self?.requestAnnotation(style: .underline, color: .yellow) }]))
        actions.append(UIAction(title: localized("筆記"), image: UIImage(systemName: ReaderPremiumVisibilityPolicy(isProActive: SubscriptionStore.shared.isProActive).allowsParagraphNoteEditing ? "note.text" : "lock.fill")) { [weak self] _ in self?.requestNote(self?.selection.tappedAnnotation) })
        actions.append(UIAction(title: localized("搜尋書籍"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            guard let self, let text = selection.selectedTextForCopy else { return }; afterMenuDismissal { [weak self] in self?.onSearch?(text) }
        })
        if #available(iOS 17.4, *), onTranslate != nil {
            actions.append(UIAction(title: localized("翻譯")) { [weak self] _ in
                guard let self, let text = selection.selectedTextForCopy else { return }; afterMenuDismissal { [weak self] in self?.onTranslate?(text) }
            })
        }
        actions.append(UIAction(title: localized("替換")) { [weak self] _ in
            guard let self, let text = selection.selectedTextForCopy else { return }
            afterMenuDismissal {
                NotificationCenter.default.post(name: .coreTextReplaceSelectionRequested, object: nil, userInfo: ["request": CoreTextReplaceSelectionRequest(selectedText: text)])
            }
        })
        if let annotation = selection.tappedAnnotation {
            actions.append(UIAction(title: localized("刪除標註"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                if let note = annotation.note, !note.isEmpty {
                    let request = CoreTextNoteDeleteRequest(position: .init(spineIndex: spineIndex, charOffset: annotation.startOffset), length: annotation.range.length, excerpt: excerpt(annotation.range), note: note, style: annotation.style, color: annotation.color)
                    afterMenuDismissal {
                        NotificationCenter.default.post(name: .coreTextNoteDeleteRequested, object: nil, userInfo: ["request": request])
                    }
                } else { requestAnnotation(style: annotation.style, color: annotation.color, removes: true) }
            })
        }
        return UIMenu(children: actions)
    }

    func requestAnnotation(style: AnnotationStyle, color: AnnotationColor, removes: Bool = false) {
        guard let range = selection.selectedRange else { return }
        let request = CoreTextUnderlineSelectionRequest(position: .init(spineIndex: spineIndex, charOffset: range.location), length: range.length, excerpt: excerpt(range), removesExistingUnderline: removes, style: style, color: color)
        clear()
        NotificationCenter.default.post(name: .coreTextUnderlineSelectionRequested, object: nil, userInfo: ["request": request])
    }

    private func requestNote(_ annotation: CoreTextTextAnnotation?) {
        guard let range = annotation?.range ?? selection.selectedRange else { return }
        let request = CoreTextNoteEditRequest(position: .init(spineIndex: spineIndex, charOffset: range.location), length: range.length, excerpt: excerpt(range), existingNote: annotation?.note ?? "", style: annotation?.style, color: annotation?.color)
        afterMenuDismissal {
            NotificationCenter.default.post(name: .coreTextNoteEditRequested, object: nil, userInfo: ["request": request])
        }
    }

    /// UIKit's dismissal completion, not a timed delay, owns modal hand-off.
    private func afterMenuDismissal(_ action: @escaping () -> Void) {
        if menuVisible { pendingMenuAction = action; clear() }
        else { clear(); action() }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
        menuVisible = true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in
            guard let self else { return }
            menuVisible = false
            let action = pendingMenuAction
            pendingMenuAction = nil
            action?()
        }
    }

    private func excerpt(_ range: NSRange) -> String {
        guard range.location >= 0, NSMaxRange(range) <= source.length else { return "" }
        return (source.string as NSString).substring(with: range)
    }
}
