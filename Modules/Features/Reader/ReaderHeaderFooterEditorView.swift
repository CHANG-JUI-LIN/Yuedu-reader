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
    @State private var chromeFrames: [ReaderOverlayEditorChromeRegion: CGRect] = [:]
    @State private var presentedSheet: ReaderOverlayEditorSheet?
    @State private var chromeIsHidden = false

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size)
            let safeArea = safeAreaRect(in: canvas)
            let topChromeFrame: CGRect? = chromeIsHidden ? .zero : chromeFrames[.top]
            let bottomChromeFrame: CGRect? = chromeIsHidden ? .zero : chromeFrames[.bottom]

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if chromeIsHidden {
                            setChromeHidden(false)
                        } else {
                            model.selectedComponentID = nil
                        }
                    }

                ReaderOverlayCanvas(
                    layout: model.draft,
                    scope: .chapterBody,
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

                if !chromeIsHidden {
                    editorChrome
                        .transition(editorChromeTransition)
                }

                if draggingComponentID == nil,
                   let selectedID = model.selectedComponentID,
                   let selectedFrame = measuredFrames[selectedID],
                   let topChromeFrame,
                   let bottomChromeFrame {
                    let actionMenuSafeArea = ReaderOverlayEditorGeometry.chromeAvoidingSafeArea(
                        safeArea: safeArea,
                        canvas: canvas,
                        topChromeFrame: topChromeFrame,
                        bottomChromeFrame: bottomChromeFrame,
                        gap: DSLayout.readerOverlayActionMenuGap
                    )
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
                        safeArea: actionMenuSafeArea,
                        gap: DSLayout.readerOverlayActionMenuGap
                    ))
                    .transition(selectionTransition)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: readerOverlayEditorCoordinateSpaceName)
            .onPreferenceChange(ReaderOverlayEditorChromeFramePreferenceKey.self) {
                chromeFrames = $0
            }
            .accessibilityAction(
                named: Text(
                    localized(chromeIsHidden ? "顯示編輯控制" : "隱藏編輯控制")
                )
            ) {
                setChromeHidden(!chromeIsHidden)
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
                if let component = componentBinding(id: id) {
                    ReaderOverlayComponentEditView(
                        component: component,
                        readerStyle: readerStyle,
                        importedFonts: importedFonts,
                        svgAssetStore: svgAssetStore,
                        referencedAssetIDs: referencedSVGAssetIDs
                    )
                }
            }
        }
    }

    private var editorChrome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                editorToolbar
                    .padding(.top, safeAreaInsets.top + DSSpacing.sm)
                    .padding(.horizontal, DSSpacing.lg)

                if let saveErrorMessage {
                    Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.destructive)
                        .padding(.horizontal, DSSpacing.md)
                        .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, DSSpacing.sm)
                        .accessibilityElement(children: .combine)
                }
            }
            .readerOverlayEditorChromeFrame(.top)

            Spacer(minLength: DSSpacing.lg)

            VStack(spacing: 0) {
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
                    .transition(undoTransition)
                    .padding(.bottom, DSSpacing.sm)
                }

                Button {
                    presentedSheet = .componentPicker
                } label: {
                    Label(localized("新增組件"), systemImage: "plus")
                        .font(DSFont.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(DSColor.accent)
                .frame(maxWidth: DSLayout.readerOverlayEditorBottomActionMaxWidth)
                .padding(.horizontal, DSSpacing.xl)
                .padding(.bottom, safeAreaInsets.bottom + DSSpacing.sm)
            }
            .readerOverlayEditorChromeFrame(.bottom)
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(localized("取消")) {
                model.cancel()
                onDismiss()
            }
            .font(DSFont.callout)
            .frame(width: DSLayout.readerOverlayEditorToolbarActionWidth)
            .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
            .background(.regularMaterial, in: Capsule())

            Spacer(minLength: DSSpacing.xs)

            Button {
                setChromeHidden(true)
            } label: {
                Label(localized("頁首頁尾編輯"), systemImage: "chevron.up")
                    .font(DSFont.headline)
                    .lineLimit(1)
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("隱藏編輯控制"))

            Spacer(minLength: DSSpacing.xs)

            Button(localized("完成")) {
                if model.done() {
                    onDismiss()
                }
            }
            .font(DSFont.callout.weight(.semibold))
            .foregroundStyle(DSColor.textOnAccent)
            .frame(width: DSLayout.readerOverlayEditorToolbarActionWidth)
            .frame(minHeight: DSLayout.readerOverlayActionMenuHeight)
            .background(DSColor.accent, in: Capsule())
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
        guard let component = model.draft.components.first(where: { $0.id == id }) else { return }
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
        guard let current = model.draft.components.first(where: { $0.id == id })?.position else {
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
        guard model.draft.components.contains(where: { $0.id == id }) else { return }
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

    private var editorChromeTransition: AnyTransition {
        reduceMotion ? .identity : .opacity
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard chromeIsHidden != hidden else { return }
        chromeIsHidden = hidden
        if hidden {
            UIAccessibility.post(
                notification: .announcement,
                argument: localized("編輯控制已隱藏，點一下空白處可重新顯示。")
            )
        }
    }

    private func addComponent(_ kind: ReaderOverlayComponentKind) {
        let position = ReaderOverlayDefaultPlacement.position(
            existing: model.draft.components.map(\.position)
        )
        var component = ReaderOverlayComponent.make(kind: kind, position: position)
        if kind == .customText {
            component.configuration.customText = localized("自訂文字")
        }
        model.add(component)
    }

    private func componentBinding(
        id: UUID
    ) -> Binding<ReaderOverlayComponent>? {
        guard let initial = model.draft.components.first(where: { $0.id == id }) else {
            return nil
        }
        return Binding(
            get: {
                model.draft.components.first(where: { $0.id == id }) ?? initial
            },
            set: { model.update($0) }
        )
    }

    private var referencedSVGAssetIDs: Set<UUID> {
        Set(model.draft.components.compactMap(\.configuration.svgAssetID))
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

private enum ReaderOverlayEditorChromeRegion: Hashable {
    case top
    case bottom
}

private struct ReaderOverlayEditorChromeFramePreferenceKey: PreferenceKey {
    static let defaultValue: [ReaderOverlayEditorChromeRegion: CGRect] = [:]

    static func reduce(
        value: inout [ReaderOverlayEditorChromeRegion: CGRect],
        nextValue: () -> [ReaderOverlayEditorChromeRegion: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private extension View {
    func readerOverlayEditorChromeFrame(
        _ region: ReaderOverlayEditorChromeRegion
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReaderOverlayEditorChromeFramePreferenceKey.self,
                    value: [
                        region: proxy.frame(
                            in: .named(readerOverlayEditorCoordinateSpaceName)
                        )
                    ]
                )
            }
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
