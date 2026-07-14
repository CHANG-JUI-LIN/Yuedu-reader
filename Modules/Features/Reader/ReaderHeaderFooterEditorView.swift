import SwiftUI
import UIKit

private let readerOverlayEditorCoordinateSpaceName = "ReaderOverlayEditorCanvas"

struct ReaderHeaderFooterEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ReaderHeaderFooterEditorModel

    let content: ReaderOverlayContentSnapshot
    let readerStyle: ReaderOverlayReaderStyle
    let safeAreaInsets: EdgeInsets
    let horizontalPageMargin: CGFloat
    let svgAssetStore: ReaderOverlaySVGAssetStore
    let importedFonts: [UserFontInfo]
    let onDismiss: () -> Void

    @State private var dragOrigin: CGPoint?
    @State private var draggingComponentID: UUID?
    @State private var activeGuides: [ReaderOverlayGuide] = []
    @State private var snapSession = ReaderOverlaySnapSession()
    @State private var measuredFrames: [UUID: CGRect] = [:]
    @State private var presentedSheet: ReaderOverlayEditorSheet?
    @State private var showingExitConfirmation = false

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size)
            let safeArea = safeAreaRect(in: canvas)

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectedComponentID = nil
                    }

                ReaderOverlayCanvas(
                    layout: model.draft,
                    scope: model.activeScope,
                    content: content,
                    readerStyle: readerStyle,
                    mode: .editor(selectedID: model.selectedComponentID),
                    svgAssetStore: svgAssetStore,
                    editorActions: editorActions(canvas: canvas)
                )
                .onPreferenceChange(ReaderOverlayComponentFramePreferenceKey.self) {
                    measuredFrames = $0
                }

                ReaderOverlayAlignmentGuidesView(guides: activeGuides)

                editorChrome

                if draggingComponentID == nil,
                   let selectedID = model.selectedComponentID,
                   let selectedFrame = measuredFrames[selectedID] {
                    ReaderOverlayAnchoredActionMenu(
                        onEdit: { edit(selectedID) },
                        onDelete: { delete(selectedID) }
                    )
                    .frame(
                        width: DSLayout.readerOverlayActionMenuWidth,
                        height: DSLayout.readerOverlayActionMenuHeight
                    )
                    .position(ReaderOverlayEditorGeometry.actionMenuCenter(
                        componentFrame: selectedFrame,
                        menuSize: CGSize(
                            width: DSLayout.readerOverlayActionMenuWidth,
                            height: DSLayout.readerOverlayActionMenuHeight
                        ),
                        canvas: canvas,
                        safeArea: safeArea,
                        gap: DSLayout.readerOverlayActionMenuGap
                    ))
                    .transition(selectionTransition)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: readerOverlayEditorCoordinateSpaceName)
            .onChange(of: model.activeScope) { _, _ in
                dragEnded()
                measuredFrames = [:]
            }
        }
        .ignoresSafeArea()
        .animation(editorAnimation, value: model.selectedComponentID)
        .animation(editorAnimation, value: model.lastDeleted?.component.id)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .componentPicker:
                ReaderOverlayComponentPickerView(onSelect: addComponent)
            case .componentEditor(let id):
                if let component = model.activeComponents.first(where: { $0.id == id }) {
                    ReaderOverlayComponentEditView(
                        component: component,
                        readerStyle: readerStyle,
                        importedFonts: importedFonts,
                        svgAssetStore: svgAssetStore,
                        referencedAssetIDs: referencedSVGAssetIDs,
                        onSave: model.update
                    )
                }
            }
        }
        .confirmationDialog(
            localized("儲存頁首頁尾變更？"),
            isPresented: $showingExitConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized("儲存並退出")) { saveAndExit() }
            Button(localized("不儲存退出"), role: .destructive) { discardAndExit() }
            Button(localized("繼續編輯"), role: .cancel) {}
        }
    }

    private var editorChrome: some View {
        VStack(spacing: DSSpacing.sm) {
            if model.lastDeleted != nil {
                HStack(spacing: DSSpacing.md) {
                    Text(localized("已刪除組件"))
                        .font(DSFont.subheadline)
                    Button(localized("復原")) {
                        model.undoDelete()
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: localized("已復原組件")
                        )
                    }
                    .font(DSFont.subheadline.weight(.semibold))
                }
                .padding(.horizontal, DSSpacing.lg)
                .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        DSColor.border,
                        lineWidth: DSLayout.readerOverlayGuideLineWidth
                    )
                }
                .transition(undoTransition)
            }

            Picker(localized("頁面範圍"), selection: $model.activeScope) {
                Text(localized("章節首頁")).tag(ReaderOverlayPageScope.chapterOpening)
                Text(localized("章節正文")).tag(ReaderOverlayPageScope.chapterBody)
            }
            .pickerStyle(.segmented)
            .font(DSFont.callout)
            .tint(DSColor.accent)
            .padding(DSSpacing.xs)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    DSColor.border,
                    lineWidth: DSLayout.readerOverlayGuideLineWidth
                )
            }

            editorChromeButton(localized("新增組件"), systemImage: "plus") {
                presentedSheet = .componentPicker
            }

            editorChromeButton(localized("退出編輯"), systemImage: "chevron.down") {
                requestExit()
            }

            if let saveErrorMessage {
                Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.destructive)
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(
                            DSColor.border,
                            lineWidth: DSLayout.readerOverlayGuideLineWidth
                        )
                    }
                    .accessibilityElement(children: .combine)
            }
        }
        .frame(width: DSLayout.readerOverlayEditorControlStackWidth)
        .padding(.horizontal, DSSpacing.lg)
    }

    private func editorChromeButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                DSColor.border,
                lineWidth: DSLayout.readerOverlayGuideLineWidth
            )
        }
    }

    private func editorActions(
        canvas: CGRect
    ) -> ReaderOverlayCanvasEditorActions {
        ReaderOverlayCanvasEditorActions(
            select: { id in
                model.selectedComponentID = id
            },
            dragChanged: { id, translation in
                dragChanged(id: id, translation: translation, canvas: canvas)
            },
            dragEnded: { _ in
                dragEnded()
            },
            nudge: { id, direction in
                nudge(id: id, direction: direction)
            },
            place: { id, position in
                moveAndAnnounce(id: id, to: position.normalizedPoint)
            },
            edit: { id in
                edit(id)
            },
            delete: { id in
                delete(id)
            }
        )
    }

    private func dragChanged(
        id: UUID,
        translation: CGSize,
        canvas: CGRect
    ) {
        guard let frame = measuredFrames[id], canvas.width > 0, canvas.height > 0 else { return }
        if draggingComponentID != id || dragOrigin == nil {
            snapSession.reset()
            draggingComponentID = id
            dragOrigin = CGPoint(x: frame.midX, y: frame.midY)
            model.selectedComponentID = id
        }
        guard let dragOrigin else { return }

        let peers = measuredFrames.compactMap { peerID, peerFrame in
            peerID == id ? nil : ReaderOverlayPeerFrame(id: peerID, frame: peerFrame)
        }
        let proposedCenter = CGPoint(
            x: dragOrigin.x + translation.width,
            y: dragOrigin.y + translation.height
        )
        let reservations = model.draft.contentReservations.normalized
        let bodyFrame = ReaderOverlayBodyFramePolicy.frame(
            in: canvas,
            horizontalPageMargin: horizontalPageMargin,
            topReservation: CGFloat(reservations.top),
            bottomReservation: CGFloat(reservations.bottom)
        )
        let result = ReaderOverlaySnapEngine.resolve(
            proposedCenter: proposedCenter,
            componentSize: frame.size,
            canvas: canvas,
            bodyFrame: bodyFrame,
            peers: peers,
            session: &snapSession,
            acquireDistance: ReaderOverlayEditorGeometry.snapAcquireDistance,
            releaseDistance: ReaderOverlayEditorGeometry.snapReleaseDistance
        )
        model.move(id: id, to: ReaderOverlayGeometry.normalize(result.center, in: canvas))
        activeGuides = result.guides
    }

    private func dragEnded() {
        dragOrigin = nil
        draggingComponentID = nil
        activeGuides = []
        snapSession.reset()
    }

    private func nudge(id: UUID, direction: ReaderOverlayNudgeDirection) {
        guard let component = model.activeComponents.first(where: { $0.id == id }) else { return }
        let step = 0.01
        var position = component.position
        switch direction {
        case .left: position.x -= step
        case .right: position.x += step
        case .up: position.y -= step
        case .down: position.y += step
        }
        moveAndAnnounce(id: id, to: position)
    }

    private func moveAndAnnounce(
        id: UUID,
        to position: ReaderOverlayNormalizedPoint
    ) {
        guard let current = model.activeComponents.first(where: { $0.id == id })?.position else {
            return
        }
        let next = position.clamped
        guard next != current else { return }
        model.move(id: id, to: next)
        announceMove()
    }

    private func announceMove() {
        UIAccessibility.post(
            notification: .announcement,
            argument: localized("已移動組件")
        )
    }

    private func edit(_ id: UUID) {
        guard model.activeComponents.contains(where: { $0.id == id }) else { return }
        model.selectedComponentID = id
        presentedSheet = .componentEditor(id)
    }

    private func delete(_ id: UUID) {
        model.delete(id: id)
        dragEnded()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        UIAccessibility.post(
            notification: .announcement,
            argument: localized("已刪除組件，可復原")
        )
    }

    private func safeAreaRect(in canvas: CGRect) -> CGRect {
        let width = max(0, canvas.width - safeAreaInsets.leading - safeAreaInsets.trailing)
        let height = max(0, canvas.height - safeAreaInsets.top - safeAreaInsets.bottom)
        return CGRect(
            x: safeAreaInsets.leading,
            y: safeAreaInsets.top,
            width: width,
            height: height
        )
    }

    private var saveErrorMessage: String? {
        guard let error = model.saveError else { return nil }
        switch error as? ReaderHeaderFooterEditorValidationError {
        case .duplicateComponentID:
            return localized("組件資料重複，無法儲存")
        case .unsupportedLayoutVersion:
            return localized("此頁首頁尾設定來自較新版本，無法覆寫")
        case nil:
            return localized("無法儲存頁首頁尾設定")
        }
    }

    private var editorAnimation: Animation? {
        reduceMotion ? nil : DSAnimation.standard
    }

    private var selectionTransition: AnyTransition {
        reduceMotion ? .identity : .scale(scale: 0.94).combined(with: .opacity)
    }

    private var undoTransition: AnyTransition {
        reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity)
    }

    private func requestExit() {
        guard model.draft != model.original else {
            discardAndExit()
            return
        }
        showingExitConfirmation = true
    }

    private func saveAndExit() {
        if model.done() { onDismiss() }
    }

    private func discardAndExit() {
        model.cancel()
        onDismiss()
    }

    private func addComponent(_ kind: ReaderOverlayComponentKind) {
        let position = ReaderOverlayDefaultPlacement.position(
            existing: model.activeComponents.map(\.position)
        )
        var component = ReaderOverlayComponent.make(kind: kind, position: position)
        if kind == .customText {
            component.configuration.customText = localized("自訂文字")
        }
        model.add(component)
    }

    private var referencedSVGAssetIDs: Set<UUID> {
        Set(
            ReaderOverlayPageScope.allCases
                .flatMap { model.draft.components(for: $0) }
                .compactMap(\.configuration.svgAssetID)
        )
    }
}

private enum ReaderOverlayEditorSheet: Identifiable {
    case componentPicker
    case componentEditor(UUID)

    var id: String {
        switch self {
        case .componentPicker: "component-picker"
        case .componentEditor(let id): "component-editor-\(id.uuidString)"
        }
    }
}

private struct ReaderOverlayAnchoredActionMenu: View {
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onEdit) {
                Label(localized("編輯"), systemImage: "pencil")
                    .font(DSFont.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(DSColor.separator)
                .frame(width: DSLayout.readerOverlayGuideLineWidth)
                .padding(.vertical, DSSpacing.sm)
                .accessibilityHidden(true)

            Button(role: .destructive, action: onDelete) {
                Label(localized("刪除"), systemImage: "trash")
                    .font(DSFont.callout)
                    .foregroundStyle(DSColor.destructive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(DSColor.border, lineWidth: DSLayout.readerOverlayGuideLineWidth)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
private struct ReaderHeaderFooterEditorPreviewHarness: View {
    @StateObject private var model: ReaderHeaderFooterEditorModel
    private let store: ReaderOverlaySVGAssetStore

    init() {
        var layout = ReaderOverlayLayout.default
        layout.components.append(contentsOf: [
            ReaderOverlayComponent.make(
                kind: .bookTitle,
                position: ReaderOverlayNormalizedPoint(x: 0.18, y: 0.18)
            ),
            ReaderOverlayComponent.make(
                kind: .progressBar,
                position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.86)
            )
        ])
        let model = ReaderHeaderFooterEditorModel(initial: layout) { _ in }
        model.selectedComponentID = layout.components[1].id
        _model = StateObject(wrappedValue: model)
        store = ReaderOverlaySVGAssetStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ReaderHeaderFooterEditorPreview", isDirectory: true)
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: ReaderTheme.sepia.uiBackgroundColor)
                .ignoresSafeArea()
            Text(String(repeating: "這是一段閱讀頁正文，用來預覽元件自由排列與對齊。\n", count: 18))
                .font(DSFont.body)
                .foregroundStyle(Color(uiColor: ReaderTheme.sepia.uiTextColor))
                .padding(.horizontal, DSSpacing.xl)

            ReaderHeaderFooterEditorView(
                model: model,
                content: ReaderOverlayContentSnapshot(
                    bookTitle: "示例書名",
                    chapterTitle: "第一章 風雪山神廟",
                    chapterPage: 3,
                    chapterPageCount: 12,
                    totalProgress: 0.425,
                    now: Date(),
                    batteryLevel: 0.64,
                    isCharging: false,
                    readingDuration: 600,
                    estimatedRemainingTime: 1_200
                ),
                readerStyle: ReaderOverlayReaderStyle(
                    font: UIFont.preferredFont(forTextStyle: .body),
                    textColor: ReaderTheme.sepia.uiTextColor,
                    availablePostScriptNames: []
                ),
                safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                horizontalPageMargin: DSSpacing.xl,
                svgAssetStore: store,
                importedFonts: [],
                onDismiss: {}
            )

            ReaderOverlayAlignmentGuidesView(
                guides: [.vertical(x: 195), .horizontal(y: 422)]
            )
            .allowsHitTesting(false)
        }
    }
}

#Preview("Live Reader Header Footer Editor") {
    ReaderHeaderFooterEditorPreviewHarness()
}
#endif
