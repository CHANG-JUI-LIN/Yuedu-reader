import SwiftUI

enum ReaderOverlayCanvasMode: Equatable, Sendable {
    case runtime
    case editor(selectedID: UUID?)

    var isEditing: Bool {
        if case .editor = self { return true }
        return false
    }

    var selectedID: UUID? {
        guard case .editor(let selectedID) = self else { return nil }
        return selectedID
    }
}

struct ReaderOverlayComponentFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ReaderOverlayComponentAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [UUID: Anchor<CGRect>],
        nextValue: () -> [UUID: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct ReaderOverlayCanvas: View {
    let layout: ReaderOverlayLayout
    let content: ReaderOverlayContentSnapshot
    let readerStyle: ReaderOverlayReaderStyle
    let mode: ReaderOverlayCanvasMode
    let svgAssetStore: ReaderOverlaySVGAssetStore
    var editorActions: ReaderOverlayCanvasEditorActions?

    var body: some View {
        GeometryReader { proxy in
            ReaderOverlayPositionLayout {
                ForEach(layout.components) { component in
                    interactiveComponent(component)
                    .readerOverlayPosition(component.position)
                    .anchorPreference(
                        key: ReaderOverlayComponentAnchorPreferenceKey.self,
                        value: .bounds
                    ) { anchor in
                        mode.isEditing ? [component.id: anchor] : [:]
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlayPreferenceValue(ReaderOverlayComponentAnchorPreferenceKey.self) { anchors in
                Color.clear
                    .preference(
                        key: ReaderOverlayComponentFramePreferenceKey.self,
                        value: anchors.mapValues { proxy[$0] }
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(mode.isEditing)
    }

    @ViewBuilder
    private func interactiveComponent(_ component: ReaderOverlayComponent) -> some View {
        let componentView = ReaderOverlayComponentView(
            component: component,
            content: content,
            readerStyle: readerStyle,
            isEditing: mode.isEditing,
            isSelected: mode.selectedID == component.id,
            svgAssetStore: svgAssetStore
        )

        if mode.isEditing, let editorActions {
            componentView
                .modifier(ReaderOverlayEditorInteractionModifier(
                    componentID: component.id,
                    isSelected: mode.selectedID == component.id,
                    actions: editorActions
                ))
        } else {
            componentView
        }
    }
}

enum ReaderOverlayNudgeDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

enum ReaderOverlayGridPosition: CaseIterable, Equatable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var normalizedPoint: ReaderOverlayNormalizedPoint {
        switch self {
        case .topLeading: ReaderOverlayNormalizedPoint(x: 0, y: 0)
        case .top: ReaderOverlayNormalizedPoint(x: 0.5, y: 0)
        case .topTrailing: ReaderOverlayNormalizedPoint(x: 1, y: 0)
        case .leading: ReaderOverlayNormalizedPoint(x: 0, y: 0.5)
        case .center: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        case .trailing: ReaderOverlayNormalizedPoint(x: 1, y: 0.5)
        case .bottomLeading: ReaderOverlayNormalizedPoint(x: 0, y: 1)
        case .bottom: ReaderOverlayNormalizedPoint(x: 0.5, y: 1)
        case .bottomTrailing: ReaderOverlayNormalizedPoint(x: 1, y: 1)
        }
    }

    var localizedActionName: String {
        switch self {
        case .topLeading: localized("移到左上")
        case .top: localized("移到上方")
        case .topTrailing: localized("移到右上")
        case .leading: localized("移到左側")
        case .center: localized("移到中央")
        case .trailing: localized("移到右側")
        case .bottomLeading: localized("移到左下")
        case .bottom: localized("移到下方")
        case .bottomTrailing: localized("移到右下")
        }
    }
}

struct ReaderOverlayCanvasEditorActions {
    let select: (UUID) -> Void
    let dragChanged: (UUID, CGSize) -> Void
    let dragEnded: (UUID) -> Void
    let nudge: (UUID, ReaderOverlayNudgeDirection) -> Void
    let place: (UUID, ReaderOverlayGridPosition) -> Void
    let edit: (UUID) -> Void
    let delete: (UUID) -> Void
}

private struct ReaderOverlayEditorInteractionModifier: ViewModifier {
    let componentID: UUID
    let isSelected: Bool
    let actions: ReaderOverlayCanvasEditorActions

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                actions.select(componentID)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        actions.dragChanged(componentID, value.translation)
                    }
                    .onEnded { _ in
                        actions.dragEnded(componentID)
                    }
            )
            .accessibilityAction {
                actions.select(componentID)
            }
            .modifier(ReaderOverlaySelectedAccessibilityActionsModifier(
                componentID: componentID,
                isSelected: isSelected,
                actions: actions
            ))
    }
}

private struct ReaderOverlaySelectedAccessibilityActionsModifier: ViewModifier {
    let componentID: UUID
    let isSelected: Bool
    let actions: ReaderOverlayCanvasEditorActions

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .accessibilityAction(named: Text(localized("向左微調"))) {
                    actions.nudge(componentID, .left)
                }
                .accessibilityAction(named: Text(localized("向右微調"))) {
                    actions.nudge(componentID, .right)
                }
                .accessibilityAction(named: Text(localized("向上微調"))) {
                    actions.nudge(componentID, .up)
                }
                .accessibilityAction(named: Text(localized("向下微調"))) {
                    actions.nudge(componentID, .down)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.topLeading.localizedActionName)) {
                    actions.place(componentID, .topLeading)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.top.localizedActionName)) {
                    actions.place(componentID, .top)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.topTrailing.localizedActionName)) {
                    actions.place(componentID, .topTrailing)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.leading.localizedActionName)) {
                    actions.place(componentID, .leading)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.center.localizedActionName)) {
                    actions.place(componentID, .center)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.trailing.localizedActionName)) {
                    actions.place(componentID, .trailing)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.bottomLeading.localizedActionName)) {
                    actions.place(componentID, .bottomLeading)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.bottom.localizedActionName)) {
                    actions.place(componentID, .bottom)
                }
                .accessibilityAction(named: Text(ReaderOverlayGridPosition.bottomTrailing.localizedActionName)) {
                    actions.place(componentID, .bottomTrailing)
                }
                .accessibilityAction(named: Text(localized("編輯"))) {
                    actions.edit(componentID)
                }
                .accessibilityAction(named: Text(localized("刪除"))) {
                    actions.delete(componentID)
                }
        } else {
            content
        }
    }
}

private struct ReaderOverlayPositionLayoutValueKey: LayoutValueKey {
    static let defaultValue = ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
}

private extension View {
    func readerOverlayPosition(_ value: ReaderOverlayNormalizedPoint) -> some View {
        layoutValue(key: ReaderOverlayPositionLayoutValueKey.self, value: value.clamped)
    }
}

private struct ReaderOverlayPositionLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            let fittingProposal = ProposedViewSize(
                width: max(bounds.width, 0),
                height: max(bounds.height, 0)
            )
            let size = subview.sizeThatFits(fittingProposal)
            let candidate = ReaderOverlayGeometry.denormalize(
                subview[ReaderOverlayPositionLayoutValueKey.self],
                in: bounds
            )
            let center = ReaderOverlayGeometry.clamp(
                center: candidate,
                size: size,
                to: bounds
            )
            subview.place(
                at: center,
                anchor: .center,
                proposal: ProposedViewSize(size)
            )
        }
    }
}

#Preview("Reader Overlay Canvas") {
    ReaderOverlayCanvas(
        layout: .default,
        content: ReaderOverlayContentSnapshot(
            bookTitle: "示例書名",
            chapterTitle: "第一章",
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
            font: UIFont.preferredFont(forTextStyle: .caption1),
            textColor: .label,
            availablePostScriptNames: []
        ),
        mode: .editor(selectedID: ReaderOverlayLayout.default.components.first?.id),
        svgAssetStore: ReaderOverlaySVGAssetStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ReaderOverlayCanvasPreview", isDirectory: true)
        ),
        editorActions: nil
    )
    .background(DSColor.background)
}
