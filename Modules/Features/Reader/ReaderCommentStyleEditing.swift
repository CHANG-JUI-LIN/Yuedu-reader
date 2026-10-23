import SwiftUI
import UIKit

/// The reading text 氣泡設定's previews are drawn in: the reader's font and size, on the
/// reading theme it is set to by day, or the night theme.
@MainActor
struct CommentStylePreviewContext {
    let theme: ReaderTheme
    let reader: ReviewCardRaster.Reader

    static func current(isNight: Bool) -> CommentStylePreviewContext {
        let persisted = ReaderTheme.loadPersisted()
        let theme: ReaderTheme = isNight ? .night : (persisted == .night ? .white : persisted)
        return CommentStylePreviewContext(
            theme: theme,
            reader: ReviewCardRaster.Reader(
                font: UserReaderFontResolver.bodyFont(size: ReaderConfig.shared.fontSize),
                textColor: theme.uiTextColor
            )
        )
    }
}

/// A card template drawn over sample content on the reading background — what the reader
/// will see, in the reading font and size.
struct CommentCardTemplatePreview: View {
    let source: String
    let kind: ReaderCommentCardKind
    /// What `${color}` stands for here; nil follows the reading text colour.
    let colorHex: String?
    let isNight: Bool

    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        let context = CommentStylePreviewContext.current(isNight: isNight)
        ZStack {
            if let image {
                ReviewCardGlassPreview(image: image)
            } else if let failure {
                Text(failure)
                    .font(DSFont.caption)
                    .foregroundStyle(Color(uiColor: context.theme.uiTextColor))
                    .padding(DSSpacing.sm)
            } else {
                ProgressView()
                    .padding(DSSpacing.lg)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.sm)
        .background(Color(uiColor: context.theme.uiBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized(isNight ? "夜間預覽" : "白天預覽"))
        .accessibilityValue(failure ?? "")
        .task(id: renderKey(context)) {
            await render(context)
        }
    }

    private func renderKey(_ context: CommentStylePreviewContext) -> String {
        [source, colorHex ?? "-", context.theme.rawValue, context.reader.font.fontName,
         "\(context.reader.font.pointSize)", CommentBubbleSVGRecognizer.hexString(context.reader.textColor)]
            .joined(separator: "|")
    }

    private func render(_ context: CommentStylePreviewContext) async {
        do {
            let drawn = try await ReviewCardRaster.preview(
                templateSource: source,
                kind: kind,
                colorHex: colorHex,
                reader: context.reader,
                theme: context.theme,
                width: DSLayout.readerCommentCardPreviewWidth
            )
            guard !Task.isCancelled else { return }
            image = drawn
            failure = drawn == nil ? localized("預覽無法繪製。") : nil
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            failure = error.localizedDescription
        }
    }
}

/// A drawn card with the system's glass behind its `data-yd-glass` panels, as the reader
/// shows it: in the dark or light look of the theme the card was filled for.
struct ReviewCardGlassPreview: View {
    let image: UIImage

    var body: some View {
        let card = image as? ReviewCardImage
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .background {
                GeometryReader { proxy in
                    let panels = card?.glassPanels ?? []
                    ForEach(panels.indices, id: \.self) { index in
                        let placed = panels[index].placed(
                            in: CGRect(origin: .zero, size: proxy.size),
                            imageSize: image.size
                        )
                        ReviewCardGlassShape(cornerRadius: placed.cornerRadius)
                            .frame(width: placed.rect.width, height: placed.rect.height)
                            .offset(x: placed.rect.minX, y: placed.rect.minY)
                    }
                }
                .environment(\.colorScheme, card?.isNight == true ? .dark : .light)
            }
    }
}

/// One glass panel: iOS 26's Liquid Glass; before it, the thin system material — the nearest
/// glass those systems have (`ReviewCardGlassView` does the same in the reader).
private struct ReviewCardGlassShape: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.thinMaterial)
        }
    }
}

/// A colour a style may leave unset: a switch that says whether it is set, and the picker
/// once it is.
struct OptionalHexColorRows: View {
    let toggleTitle: String
    let pickerTitle: String
    @Binding var hex: String?
    /// Where the picker starts when the switch is turned on.
    let initialColor: UIColor

    var body: some View {
        Toggle(toggleTitle, isOn: Binding(
            get: { hex != nil },
            set: { isOn in
                hex = isOn ? (hex ?? CommentStyleHex.string(from: initialColor)) : nil
            }
        ))
        .foregroundStyle(DSColor.textPrimary)
        if let current = hex {
            ColorPicker(
                pickerTitle,
                selection: Binding(
                    get: { Color(uiColor: CommentStyleHex.color(from: current) ?? initialColor) },
                    set: { hex = CommentStyleHex.string(from: UIColor($0)) }
                ),
                supportsOpacity: false
            )
            .foregroundStyle(DSColor.textPrimary)
        }
    }
}

/// `#RRGGBB` for the colours 氣泡設定 stores.
enum CommentStyleHex {
    static func string(from color: UIColor) -> String {
        String(format: "#%06X", color.rgbHex ?? 0)
    }

    /// Reads `#RGB`, `#RRGGBB` and `#RRGGBBAA`.
    static func color(from hex: String) -> UIColor? {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

#Preview("Card preview") {
    Form {
        CommentCardTemplatePreview(
            source: ReviewCardTemplate.builtinSource(for: .chapterSay),
            kind: .chapterSay,
            colorHex: nil,
            isNight: false
        )
        CommentCardTemplatePreview(
            source: ReviewCardTemplate.builtinSource(for: .hotComment),
            kind: .hotComment,
            colorHex: nil,
            isNight: true
        )
    }
}
