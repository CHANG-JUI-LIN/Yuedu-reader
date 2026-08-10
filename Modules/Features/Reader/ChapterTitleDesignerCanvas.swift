import SwiftUI
import UIKit

struct ChapterTitleDesignerCanvas: View {
    @ObservedObject var model: ChapterTitleDesignerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderPlan: ChapterTitleRenderPlan?
    @State private var renderError: Error?
    @State private var guides: [ReaderOverlayGuide] = []

    private struct RenderKey: Equatable {
        let design: ChapterTitleDesign
        let appearance: ReaderStyleAppearance
        let writingMode: ReaderWritingMode
    }

    var body: some View {
        GeometryReader { proxy in
            let canvasRect = fittedCanvas(in: proxy.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .fill(model.activeAppearance == .light ? DSColor.surface : DSColor.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                            .stroke(DSColor.border)
                    }
                if let renderPlan {
                    ChapterTitlePlanPreview(plan: renderPlan, writingMode: model.previewWritingMode)
                        .accessibilityHidden(true)
                } else if let renderError {
                    ContentUnavailableView {
                        Label(localized("預覽失敗"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(renderError.localizedDescription)
                    }
                } else {
                    ProgressView(localized("正在產生預覽"))
                }

                guideOverlay(canvasSize: canvasRect.size)

                ForEach(displayedLayers) { layer in
                    ChapterTitleLayerSelectionOverlay(
                        layer: layer,
                        model: model,
                        canvasSize: canvasRect.size,
                        guides: $guides
                    )
                }
            }
            .coordinateSpace(name: "chapterTitleCanvas")
            .frame(width: canvasRect.width, height: canvasRect.height)
            .position(x: canvasRect.midX, y: canvasRect.midY)
            .animation(reduceMotion ? nil : DSAnimation.fast, value: model.selectedLayerID)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.bottom, DSSpacing.sm)
        .background(DSColor.groupedBackground)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker(localized("書寫方向"), selection: $model.previewWritingMode) {
                Text(localized("橫排")).tag(ReaderWritingMode.horizontal)
                Text(localized("直排")).tag(ReaderWritingMode.verticalRTL)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
            .background(DSColor.background)
        }
        .task(id: RenderKey(
            design: model.draft,
            appearance: model.activeAppearance,
            writingMode: model.previewWritingMode
        )) {
            await compilePreview()
        }
    }

    private var displayedLayers: [ChapterTitleLayer] {
        model.draft.resolved(for: model.previewWritingMode).layers.filter(\.isVisible)
    }

    private func fittedCanvas(in size: CGSize) -> CGRect {
        let resolved = model.draft.resolved(for: model.previewWritingMode)
        let aspect = max(CGFloat(resolved.canvasAspectRatio), 0.1)
        let available = CGSize(
            width: max(1, size.width),
            height: max(1, size.height)
        )
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGRect(
            x: (available.width - width) / 2,
            y: (available.height - height) / 2,
            width: width,
            height: height
        )
    }

    @ViewBuilder
    private func guideOverlay(canvasSize: CGSize) -> some View {
        ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
            switch guide {
            case .vertical(let x):
                Rectangle()
                    .fill(DSColor.accent)
                    .frame(width: 1 / UIScreen.main.scale, height: canvasSize.height)
                    .position(x: CGFloat(x), y: canvasSize.height / 2)
                    .accessibilityHidden(true)
            case .horizontal(let y):
                Rectangle()
                    .fill(DSColor.accent)
                    .frame(width: canvasSize.width, height: 1 / UIScreen.main.scale)
                    .position(x: canvasSize.width / 2, y: CGFloat(y))
                    .accessibilityHidden(true)
            }
        }
    }

    private func compilePreview() async {
        do {
            let horizontalWidth = CGFloat(model.draft.canvasAspectRatio * model.draft.canvasHeight)
            let plan = try await ChapterTitleDesignRenderer.compile(
                title: "第一章 初入江湖",
                design: model.draft,
                appearance: model.activeAppearance,
                writingMode: model.previewWritingMode,
                renderWidth: horizontalWidth,
                assetStore: .shared
            )
            renderPlan = plan
            renderError = nil
        } catch {
            renderPlan = nil
            renderError = error
        }
    }
}

private enum ChapterTitleResizeHandle: CaseIterable {
    case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottom, bottomTrailing
}

private struct ChapterTitleLayerSelectionOverlay: View {
    let layer: ChapterTitleLayer
    @ObservedObject var model: ChapterTitleDesignerModel
    let canvasSize: CGSize
    @Binding var guides: [ReaderOverlayGuide]

    @State private var mutationStart: ReaderStyleNormalizedRect?
    @State private var snapSession = ReaderOverlaySnapSession()

    private var isSelected: Bool { model.selectedLayerID == layer.id }
    private var rect: CGRect {
        layer.frame.denormalized(in: CGRect(origin: .zero, size: canvasSize))
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .overlay {
                    Rectangle()
                        .stroke(isSelected ? DSColor.accent : Color.clear)
                }
                .frame(width: rect.width, height: rect.height)
                .rotationEffect(.degrees(layer.rotation.degrees))
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { model.selectedLayerID = layer.id }
                .gesture(moveGesture, including: layer.isLocked ? .none : .all)

            if isSelected && !layer.isLocked {
                ForEach(ChapterTitleResizeHandle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(DSColor.background)
                        .overlay(Circle().stroke(DSColor.accent))
                        .frame(width: DSSpacing.lg, height: DSSpacing.lg)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                        .position(handlePoint(handle))
                        .gesture(resizeGesture(handle))
                        .accessibilityLabel(localized("調整大小"))
                }
                rotationHandle
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layer.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibleActions {
            perform($0)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("chapterTitleCanvas"))
            .onChanged { value in
                beginMutationIfNeeded()
                guard let start = mutationStart else { return }
                let proposed = ReaderStyleNormalizedRect(
                    x: start.x + value.translation.width / canvasSize.width,
                    y: start.y + value.translation.height / canvasSize.height,
                    width: start.width,
                    height: start.height
                )
                let peers = model.draft.resolved(for: model.previewWritingMode).layers
                    .filter { $0.id != layer.id && $0.isVisible }
                    .map { ReaderStyleNormalizedPeerFrame(id: $0.id, frame: $0.frame) }
                let canvas = CGRect(origin: .zero, size: canvasSize)
                let result = ReaderOverlaySnapEngine.resolve(
                    proposedFrame: proposed,
                    canvas: canvas,
                    bodyFrame: canvas,
                    peers: peers,
                    session: &snapSession
                )
                guides = result.guides
                model.updateContinuousFrame(
                    id: layer.id,
                    frame: persistedFrame(fromDisplayed: result.frame)
                )
            }
            .onEnded { _ in finishMutation() }
    }

    private func resizeGesture(_ handle: ChapterTitleResizeHandle) -> some Gesture {
        DragGesture(coordinateSpace: .named("chapterTitleCanvas"))
            .onChanged { value in
                beginMutationIfNeeded()
                guard let start = mutationStart else { return }
                let dx = Double(value.translation.width / canvasSize.width)
                let dy = Double(value.translation.height / canvasSize.height)
                let minimumWidth = Double(DSLayout.minimumTapTarget / max(canvasSize.width, 1))
                let minimumHeight = Double(DSLayout.minimumTapTarget / max(canvasSize.height, 1))
                let resized = resize(
                    start,
                    handle: handle,
                    dx: dx,
                    dy: dy,
                    minimumWidth: min(minimumWidth, 0.25),
                    minimumHeight: min(minimumHeight, 0.25)
                )
                model.updateContinuousFrame(id: layer.id, frame: persistedFrame(fromDisplayed: resized))
            }
            .onEnded { _ in finishMutation() }
    }

    private var rotationHandle: some View {
        Button {} label: {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(DSFont.title3)
                .foregroundStyle(DSColor.accent)
                .accessibilityHidden(true)
        }
        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
        .position(x: rect.midX, y: max(0, rect.minY - DSLayout.minimumTapTarget))
        .accessibilityLabel(localized("旋轉"))
        .gesture(
            DragGesture(coordinateSpace: .named("chapterTitleCanvas"))
                .onChanged { value in
                    if mutationStart == nil {
                        model.beginContinuousMutation()
                        mutationStart = layer.frame
                    }
                    let angle = atan2(value.location.y - rect.midY, value.location.x - rect.midX)
                    model.updateContinuousRotation(
                        id: layer.id,
                        degrees: Double(angle * 180 / .pi) + 90
                    )
                }
                .onEnded { _ in finishMutation() }
        )
    }

    private func beginMutationIfNeeded() {
        guard mutationStart == nil else { return }
        model.selectedLayerID = layer.id
        model.beginContinuousMutation()
        mutationStart = layer.frame
        snapSession.reset()
    }

    private func finishMutation() {
        model.endContinuousMutation()
        mutationStart = nil
        guides = []
        snapSession.reset()
    }

    private func handlePoint(_ handle: ChapterTitleResizeHandle) -> CGPoint {
        switch handle {
        case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
        case .leading: CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func resize(
        _ frame: ReaderStyleNormalizedRect,
        handle: ChapterTitleResizeHandle,
        dx: Double,
        dy: Double,
        minimumWidth: Double,
        minimumHeight: Double
    ) -> ReaderStyleNormalizedRect {
        var minX = frame.x
        var minY = frame.y
        var maxX = frame.x + frame.width
        var maxY = frame.y + frame.height
        if [.topLeading, .leading, .bottomLeading].contains(handle) { minX += dx }
        if [.topTrailing, .trailing, .bottomTrailing].contains(handle) { maxX += dx }
        if [.topLeading, .top, .topTrailing].contains(handle) { minY += dy }
        if [.bottomLeading, .bottom, .bottomTrailing].contains(handle) { maxY += dy }
        minX = min(max(minX, 0), maxX - minimumWidth)
        minY = min(max(minY, 0), maxY - minimumHeight)
        maxX = max(min(maxX, 1), minX + minimumWidth)
        maxY = max(min(maxY, 1), minY + minimumHeight)
        return ReaderStyleNormalizedRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func persistedFrame(fromDisplayed frame: ReaderStyleNormalizedRect) -> ReaderStyleNormalizedRect {
        guard model.previewWritingMode.isVertical else { return frame }
        return ReaderStyleNormalizedRect(
            x: frame.y,
            y: 1 - frame.x - frame.width,
            width: frame.height,
            height: frame.width
        )
    }

    private func perform(_ action: ChapterTitleLayerAccessibleAction) {
        let step = 0.01
        var frame = layer.frame
        switch action {
        case .nudgeUp: frame.y -= step
        case .nudgeDown: frame.y += step
        case .nudgeLeading: frame.x -= step
        case .nudgeTrailing: frame.x += step
        case .grow:
            frame.width += step
            frame.height += step
        case .shrink:
            frame.width -= step
            frame.height -= step
        case .rotateClockwise: model.rotate(id: layer.id, degrees: layer.rotation.degrees + 5); return
        case .rotateCounterclockwise: model.rotate(id: layer.id, degrees: layer.rotation.degrees - 5); return
        case .moveForward: moveLayer(offset: 1); return
        case .moveBackward: moveLayer(offset: -1); return
        case .edit: model.selectedLayerID = layer.id; return
        case .duplicate: model.duplicate(id: layer.id); return
        case .delete: model.delete(id: layer.id); return
        }
        model.move(id: layer.id, to: persistedFrame(fromDisplayed: frame))
    }

    private func moveLayer(offset: Int) {
        guard let index = model.draft.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let destination = min(max(index + offset, 0), model.draft.layers.count - 1)
        guard destination != index else { return }
        model.moveLayer(fromOffsets: IndexSet(integer: index), toOffset: destination > index ? destination + 1 : destination)
    }
}

private extension View {
    func accessibleActions(
        perform: @escaping (ChapterTitleLayerAccessibleAction) -> Void
    ) -> some View {
        accessibilityAction(named: localized("向上微調")) { perform(.nudgeUp) }
            .accessibilityAction(named: localized("向下微調")) { perform(.nudgeDown) }
            .accessibilityAction(named: localized("向左微調")) { perform(.nudgeLeading) }
            .accessibilityAction(named: localized("向右微調")) { perform(.nudgeTrailing) }
            .accessibilityAction(named: localized("放大")) { perform(.grow) }
            .accessibilityAction(named: localized("縮小")) { perform(.shrink) }
            .accessibilityAction(named: localized("順時針旋轉")) { perform(.rotateClockwise) }
            .accessibilityAction(named: localized("逆時針旋轉")) { perform(.rotateCounterclockwise) }
            .accessibilityAction(named: localized("向前移動")) { perform(.moveForward) }
            .accessibilityAction(named: localized("向後移動")) { perform(.moveBackward) }
            .accessibilityAction(named: localized("編輯")) { perform(.edit) }
            .accessibilityAction(named: localized("複製")) { perform(.duplicate) }
            .accessibilityAction(named: localized("刪除")) { perform(.delete) }
    }
}

private struct ChapterTitlePlanPreview: UIViewRepresentable {
    let plan: ChapterTitleRenderPlan
    let writingMode: ReaderWritingMode

    func makeUIView(context: Context) -> ChapterTitlePlanDrawView {
        ChapterTitlePlanDrawView()
    }

    func updateUIView(_ view: ChapterTitlePlanDrawView, context: Context) {
        view.plan = plan
        view.writingMode = writingMode
    }
}

private final class ChapterTitlePlanDrawView: UIView {
    var plan: ChapterTitleRenderPlan? { didSet { setNeedsDisplay() } }
    var writingMode: ReaderWritingMode = .horizontal { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let plan, let context = UIGraphicsGetCurrentContext() else { return }
        ChapterTitleCanvasPainter.draw(
            plan,
            in: bounds,
            writingMode: writingMode,
            context: context
        )
    }
}

extension UIColor {
    convenience init(readerStyleHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

#Preview {
    ChapterTitleDesignerCanvas(
        model: ChapterTitleDesignerModel(initial: .default, onSave: { _ in })
    )
}
