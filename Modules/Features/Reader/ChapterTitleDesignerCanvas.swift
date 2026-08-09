import CoreText
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

    private func draw(_ layer: ChapterTitleRenderedLayer, context: CGContext) {
        context.saveGState()
        context.translateBy(x: layer.frame.midX, y: layer.frame.midY)
        context.rotate(by: layer.rotationRadians)
        context.translateBy(x: -layer.frame.midX, y: -layer.frame.midY)
        let decoration = layer.style.ruleStyle.decoration
        let radius = min(CGFloat(decoration.cornerRadius ?? 0), min(layer.frame.width, layer.frame.height) / 2)
        let path = UIBezierPath(roundedRect: layer.frame, cornerRadius: radius)
        drawShadows(decoration.shadows, path: path.cgPath, opacity: decoration.opacity, context: context)
        context.saveGState()
        context.setAlpha(CGFloat(decoration.opacity ?? 1))
        context.addPath(path.cgPath)
        context.clip()
        if let hex = decoration.backgroundColorHex {
            context.setFillColor(UIColor(readerStyleHex: hex).cgColor)
            context.fill(layer.frame)
        }
        if let gradient = decoration.backgroundGradient {
            drawGradient(gradient, in: layer.frame, context: context)
        }
        if let image = layer.backgroundImage, let presentation = decoration.backgroundImage {
            draw(image, presentation: presentation, in: layer.frame, context: context)
        }
        context.restoreGState()

        if let shape = layer.shape {
            switch shape {
            case .rectangle:
                context.setFillColor(UIColor(readerStyleHex: decoration.backgroundColorHex ?? 0).cgColor)
                context.fill(layer.frame)
            case .line(let style):
                context.setStrokeColor(UIColor(readerStyleHex: style.colorHex).cgColor)
                context.setLineWidth(CGFloat(style.width))
                if style.isDashed { context.setLineDash(phase: 0, lengths: [DSSpacing.sm, DSSpacing.xs]) }
                context.move(to: CGPoint(x: layer.frame.minX, y: layer.frame.midY))
                context.addLine(to: CGPoint(x: layer.frame.maxX, y: layer.frame.midY))
                context.strokePath()
            }
        }
        if let image = layer.image {
            if let presentation = layer.style.imagePresentation {
                draw(image, presentation: presentation, in: layer.frame, context: context)
            } else {
                let scale = min(layer.frame.width / image.size.width, layer.frame.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(
                    x: layer.frame.midX - size.width / 2,
                    y: layer.frame.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
        }
        drawBorders(decoration.borders, rect: layer.frame, radius: radius, opacity: decoration.opacity, context: context)
        if let attributed = layer.attributedText {
            if writingMode.isVertical {
                let canvasHeight = plan?.canvasSize.height ?? bounds.height
                let coreTextRect = CGRect(
                    x: layer.frame.minX,
                    y: canvasHeight - layer.frame.maxY,
                    width: layer.frame.width,
                    height: layer.frame.height
                )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let frame = CoreTextPaginator.makeFrame(
                    framesetter: framesetter,
                    range: CFRange(location: 0, length: attributed.length),
                    path: CGPath(rect: coreTextRect, transform: nil),
                    writingMode: writingMode
                )
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: 0, y: canvasHeight)
                context.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, context)
                context.restoreGState()
            } else {
                attributed.draw(
                    with: layer.frame,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            }
        }
        context.restoreGState()
    }

    private func drawShadows(
        _ shadows: [ReaderStyleShadow],
        path: CGPath,
        opacity: Double?,
        context: CGContext
    ) {
        for shadow in shadows {
            context.saveGState()
            context.setAlpha(CGFloat(opacity ?? 1))
            context.setShadow(
                offset: CGSize(width: CGFloat(shadow.x), height: CGFloat(shadow.y)),
                blur: CGFloat(shadow.radius),
                color: UIColor(readerStyleHex: shadow.colorHex).cgColor
            )
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    private func drawGradient(
        _ gradient: ReaderStyleGradient,
        in rect: CGRect,
        context: CGContext
    ) {
        let sorted = gradient.stops.sorted { $0.location < $1.location }
        guard !sorted.isEmpty else { return }
        let stops = sorted.count == 1 ? [sorted[0], sorted[0]] : sorted
        guard let value = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { UIColor(readerStyleHex: $0.colorHex).cgColor } as CFArray,
            locations: stops.map { CGFloat($0.location) }
        ) else { return }
        let angle = CGFloat(gradient.angleDegrees) * .pi / 180
        let direction = CGPoint(x: sin(angle), y: cos(angle))
        let length = abs(direction.x) * rect.width / 2 + abs(direction.y) * rect.height / 2
        context.drawLinearGradient(
            value,
            start: CGPoint(x: rect.midX - direction.x * length, y: rect.midY - direction.y * length),
            end: CGPoint(x: rect.midX + direction.x * length, y: rect.midY + direction.y * length),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private func draw(
        _ image: UIImage,
        presentation: ReaderStyleImagePresentation,
        in rect: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        context.setAlpha(CGFloat(presentation.opacity))
        switch presentation.contentMode {
        case .tile:
            UIColor(patternImage: image).setFill()
            context.fill(rect)
        case .fit, .fill, .stretch:
            let destination = RegexHighlightImageGeometry.destination(
                source: image.size,
                bounds: rect,
                mode: presentation.contentMode,
                focalX: CGFloat(presentation.focalX),
                focalY: CGFloat(presentation.focalY)
            )
            image.draw(in: destination)
        }
        context.restoreGState()
    }

    private func drawBorders(
        _ borders: [ReaderStyleEdge: ReaderStyleBorder]?,
        rect: CGRect,
        radius: CGFloat,
        opacity: Double?,
        context: CGContext
    ) {
        guard let borders else { return }
        context.saveGState()
        context.setAlpha(CGFloat(opacity ?? 1))
        if let first = borders.first?.value,
           borders.count == ReaderStyleEdge.allCases.count,
           borders.values.allSatisfy({ $0 == first }), first.width > 0 {
            let width = CGFloat(first.width)
            context.setStrokeColor(UIColor(readerStyleHex: first.colorHex).cgColor)
            context.setLineWidth(width)
            context.addPath(
                UIBezierPath(
                    roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                    cornerRadius: radius
                ).cgPath
            )
            context.strokePath()
        } else {
            for edge in ReaderStyleEdge.allCases {
                guard let border = borders[edge], border.width > 0 else { continue }
                let inset = CGFloat(border.width) / 2
                context.setStrokeColor(UIColor(readerStyleHex: border.colorHex).cgColor)
                context.setLineWidth(CGFloat(border.width))
                switch edge {
                case .top:
                    context.move(to: CGPoint(x: rect.minX, y: rect.minY + inset))
                    context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
                case .leading:
                    context.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
                    context.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
                case .bottom:
                    context.move(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
                    context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
                case .trailing:
                    context.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
                    context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
                }
                context.strokePath()
            }
        }
        context.restoreGState()
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
