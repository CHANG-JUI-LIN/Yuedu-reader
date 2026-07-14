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

    var body: some View {
        GeometryReader { proxy in
            ReaderOverlayPositionLayout {
                ForEach(layout.components) { component in
                    ReaderOverlayComponentView(
                        component: component,
                        content: content,
                        readerStyle: readerStyle,
                        isEditing: mode.isEditing,
                        isSelected: mode.selectedID == component.id,
                        svgAssetStore: svgAssetStore
                    )
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
            textColor: .label
        ),
        mode: .editor(selectedID: ReaderOverlayLayout.default.components.first?.id),
        svgAssetStore: ReaderOverlaySVGAssetStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ReaderOverlayCanvasPreview", isDirectory: true)
        )
    )
    .background(DSColor.background)
}
