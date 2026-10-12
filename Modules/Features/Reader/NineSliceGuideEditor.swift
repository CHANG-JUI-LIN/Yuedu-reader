import SwiftUI
import UIKit

/// Four slice lines dragged over the frame image. Outside the lines are the corners,
/// drawn as they are; between them the edges stretch along the text and the middle fills.
/// Values stay fractions of the image, as `ReaderStyleImageSlices` stores them.
struct NineSliceGuideEditor: View {
    let image: UIImage
    @Binding var slices: ReaderStyleImageSlices
    /// Where each line sat when its drag began; the line then follows the finger's
    /// translation, so grabbing it off-centre does not make it jump.
    @State private var dragOrigins: [NineSliceGuide: CGFloat] = [:]

    var body: some View {
        GeometryReader { proxy in
            let frame = Self.fittedRect(for: image.size, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityHidden(true)
                ForEach(NineSliceGuide.allCases) { guide in
                    guideLine(guide, in: frame)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: Self.height)
        .padding(.vertical, DSSpacing.sm)
    }

    private static let height: CGFloat = 200
    private static let contrast = DSColor.textOnAccent.opacity(0.8)
    private static let space = "nine-slice-guides"
    /// One step of a VoiceOver swipe.
    private static let adjustmentStep = 0.01

    private func guideLine(_ guide: NineSliceGuide, in frame: CGRect) -> some View {
        let position = guide.position(slices, in: frame)
        let thickness = DSLayout.minimumTapTarget
        let line = Path { path in
            if guide.isHorizontal {
                path.move(to: CGPoint(x: 0, y: thickness / 2))
                path.addLine(to: CGPoint(x: frame.width, y: thickness / 2))
            } else {
                path.move(to: CGPoint(x: thickness / 2, y: 0))
                path.addLine(to: CGPoint(x: thickness / 2, y: frame.height))
            }
        }
        return ZStack {
            // A light underlay keeps the dashes visible on artwork of the accent's own colour.
            line.stroke(Self.contrast, lineWidth: 3)
            line.stroke(DSColor.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            Circle()
                .fill(DSColor.accent)
                .overlay(Circle().stroke(Self.contrast, lineWidth: 2))
                .frame(width: 12, height: 12)
        }
        .frame(
            width: guide.isHorizontal ? frame.width : thickness,
            height: guide.isHorizontal ? thickness : frame.height
        )
        .contentShape(Rectangle())
        .offset(
            x: guide.isHorizontal ? frame.minX : position - thickness / 2,
            y: guide.isHorizontal ? position - thickness / 2 : frame.minY
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { drag in
                    let origin = dragOrigins[guide] ?? position
                    dragOrigins[guide] = origin
                    let moved = guide.isHorizontal ? drag.translation.height : drag.translation.width
                    set(guide, toPosition: origin + moved, in: frame)
                }
                .onEnded { _ in dragOrigins[guide] = nil }
        )
        .accessibilityElement()
        .accessibilityLabel(localized(guide.titleKey))
        .accessibilityValue(Self.percent(slices[keyPath: guide.keyPath]))
        .accessibilityAdjustableAction { direction in
            let value = slices[keyPath: guide.keyPath]
            switch direction {
            case .increment: set(guide, to: value + Self.adjustmentStep)
            case .decrement: set(guide, to: value - Self.adjustmentStep)
            @unknown default: break
            }
        }
    }

    private func set(_ guide: NineSliceGuide, toPosition position: CGFloat, in frame: CGRect) {
        set(guide, to: guide.value(at: position, in: frame))
    }

    private func set(_ guide: NineSliceGuide, to value: Double) {
        var updated = slices
        updated[keyPath: guide.keyPath] = guide.clamped(value, partner: slices[keyPath: guide.partner])
        slices = updated
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

enum NineSliceGuide: CaseIterable, Identifiable {
    case top, bottom, left, right

    /// The middle band never closes, so the edges always have something to stretch.
    static let minimumCenter = 0.02
    /// What 九宮格 starts from when an image had no slices of its own.
    static let defaultSlices = ReaderStyleImageSlices(top: 0.3, right: 0.3, bottom: 0.3, left: 0.3)

    var id: Self { self }

    var isHorizontal: Bool { self == .top || self == .bottom }

    var keyPath: WritableKeyPath<ReaderStyleImageSlices, Double> {
        switch self {
        case .top: \.top
        case .bottom: \.bottom
        case .left: \.left
        case .right: \.right
        }
    }

    var partner: KeyPath<ReaderStyleImageSlices, Double> {
        switch self {
        case .top: \.bottom
        case .bottom: \.top
        case .left: \.right
        case .right: \.left
        }
    }

    var titleKey: String {
        switch self {
        case .top: "上切線"
        case .bottom: "下切線"
        case .left: "左切線"
        case .right: "右切線"
        }
    }

    func clamped(_ value: Double, partner: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(0, 1 - partner - Self.minimumCenter))
    }

    /// The line's offset in the editor, measured from the editor's own origin.
    func position(_ slices: ReaderStyleImageSlices, in frame: CGRect) -> CGFloat {
        switch self {
        case .top: frame.minY + slices.top * frame.height
        case .bottom: frame.maxY - slices.bottom * frame.height
        case .left: frame.minX + slices.left * frame.width
        case .right: frame.maxX - slices.right * frame.width
        }
    }

    func value(at position: CGFloat, in frame: CGRect) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        switch self {
        case .top: return (position - frame.minY) / frame.height
        case .bottom: return (frame.maxY - position) / frame.height
        case .left: return (position - frame.minX) / frame.width
        case .right: return (frame.maxX - position) / frame.width
        }
    }
}

#Preview {
    @Previewable @State var slices = NineSliceGuide.defaultSlices
    let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(x: 6, y: 6, width: 108, height: 48))
    }
    return Form {
        NineSliceGuideEditor(image: image, slices: $slices)
    }
}
