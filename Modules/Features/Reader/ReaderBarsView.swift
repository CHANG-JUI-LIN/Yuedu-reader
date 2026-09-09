import SwiftUI
import UIKit

// MARK: - Style resolution

/// Resolves the one style both bars share into a concrete font and colour.
///
/// Deliberately simpler than the per-component resolver it replaces: a bar is a
/// single row of small type, so imported fonts and per-field weights would only
/// produce ransom-note rows. Size, weight, colour and opacity are enough, and
/// they are the four things legado's `ReadTipConfig` exposes too.
enum ReaderBarStyleResolver {
    static func resolve(
        _ style: ReaderBarStyle,
        readerTextColor: UIColor
    ) -> ReaderOverlayResolvedStyle {
        let normalized = style.normalized
        let size = CGFloat(normalized.fontSize)
        let font = UIFont.systemFont(ofSize: size, weight: uiFontWeight(normalized.weight))

        let color: UIColor
        switch normalized.color.source {
        case .readerText:
            color = readerTextColor
        case .custom:
            color = normalized.color.hexRGBA.map(Self.color(hexRGBA:)) ?? readerTextColor
        }

        return ReaderOverlayResolvedStyle(
            font: font,
            color: color,
            opacity: normalized.opacity
        )
    }

    private static func uiFontWeight(_ value: ReaderOverlayFontWeight) -> UIFont.Weight {
        switch value {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    private static func color(hexRGBA value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 24) & 0xFF) / 255,
            green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255
        )
    }
}

// MARK: - One bar

/// The 頁眉 or 頁腳 band: three slots, left / centre / right.
///
/// A thin wrapper over `ReaderBarRenderer`, deliberately: paged mode draws its
/// bars into the CoreText page and cannot use SwiftUI at all, so a second SwiftUI
/// implementation here would be a second appearance to keep in sync. This is what
/// scroll mode and the settings preview show, and it is the same drawing code the
/// page bakes in.
///
/// The bar reserves its own height and the content is inset by the same amount, so
/// the text never runs underneath it. legado's `view_book_page.xml` constrains its
/// `ContentTextView` between the two dividers for exactly this reason.
struct ReaderBarView: View {
    let model: ReaderBarRenderModel

    var body: some View {
        ReaderBarCanvas(model: model)
            .frame(
                height: ReaderBarRenderer.extent(
                    fontSize: model.font.pointSize,
                    showsDivider: model.showsDivider
                )
            )
            // One VoiceOver stop per bar, not one per field. The bars are ambient
            // status, and three separate stops between the reader and the text is
            // exactly the kind of noise that makes people switch the reader off.
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localized(model.bar.titleKey))
            .accessibilityValue(model.accessibilityValue)
            .accessibilityHidden(model.accessibilityValue.isEmpty)
    }
}

/// UIKit host so the bar goes through `ReaderBarRenderer.draw` unchanged.
private struct ReaderBarCanvas: UIViewRepresentable {
    let model: ReaderBarRenderModel

    func makeUIView(context: Context) -> ReaderBarUIView {
        let view = ReaderBarUIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.model = model
        return view
    }

    func updateUIView(_ uiView: ReaderBarUIView, context: Context) {
        uiView.model = model
    }
}

final class ReaderBarUIView: UIView {
    var model: ReaderBarRenderModel? {
        didSet {
            guard model != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let model, let ctx = UIGraphicsGetCurrentContext() else { return }
        ReaderBarRenderer.draw(
            model,
            in: bounds,
            canvasHeight: bounds.height,
            context: ctx
        )
    }
}

// MARK: - Preview

/// Extracted so `#Preview` stays a single simple expression — a preview body that
/// builds the snapshot inline defeats the type checker on this file.
private struct ReaderBarsPreviewHost: View {
    let theme: ReaderTheme

    @State private var builder = ReaderBarRenderModelBuilder()

    private var snapshot: ReaderOverlayContentSnapshot {
        ReaderOverlayContentSnapshot(
            bookTitle: "紅樓夢",
            chapterTitle: "第一回 甄士隱夢幻識通靈",
            chapterPage: 3,
            chapterPageCount: 12,
            totalProgress: 0.4523,
            now: Date(),
            batteryLevel: 0.78,
            isCharging: false,
            readingDuration: 1_500,
            estimatedRemainingTime: 4_200
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: theme.uiBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                bar(.header, padding: ReaderLayoutMetrics.defaultHeaderHorizontalPadding)
                Spacer()
                Text("正文……")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(uiColor: theme.uiTextColor))
                Spacer()
                bar(.footer, padding: ReaderLayoutMetrics.defaultFooterHorizontalPadding)
            }
            .padding(.vertical, 40)
        }
    }

    private func bar(_ which: ReaderBar, padding: CGFloat) -> some View {
        ReaderBarView(
            model: builder.model(
                for: which,
                layout: .default,
                content: snapshot,
                readerTextColor: theme.uiTextColor,
                horizontalPadding: padding,
                svgAssetStore: nil,
                userInterfaceStyle: theme == .night ? .dark : .light,
                displayScale: 3
            )
        )
    }
}

#Preview("頁眉頁腳條 · 棕色") {
    ReaderBarsPreviewHost(theme: .sepia)
}

#Preview("頁眉頁腳條 · 夜間") {
    ReaderBarsPreviewHost(theme: .night)
}
