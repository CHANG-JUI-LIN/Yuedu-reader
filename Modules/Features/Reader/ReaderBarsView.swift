import Combine
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
        readerTextColor: UIColor,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> ReaderOverlayResolvedStyle {
        let normalized = style.normalized
        let size = CGFloat(normalized.fontSize)
        let font = UIFont.systemFont(ofSize: size, weight: uiFontWeight(normalized.weight))

        let color: UIColor
        switch normalized.color.source {
        case .readerText:
            color = readerTextColor
        case .custom:
            let hex = userInterfaceStyle == .dark
                ? normalized.color.darkHexRGBA : normalized.color.hexRGBA
            color = hex.map(Self.color(hexRGBA:)) ?? readerTextColor
        }

        return ReaderOverlayResolvedStyle(
            font: font,
            // Resolve before Core Graphics drawing and battery rasterization;
            // their ambient UIKit appearance can differ from the reader theme.
            color: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)),
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
        // SwiftUI can finalize the canvas size after its first draw, especially
        // in a resizing List preview. Repaint for the new bounds instead of
        // stretching the old text bitmap while the model remains unchanged.
        view.contentMode = .redraw
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
            pageScope: .chapterBody,
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

// MARK: - Page Bars Layer

/// Owns the reader's clock and draws the screen-fixed 頁眉／頁腳.
///
/// The clock is observed here and nowhere else. `ClockBatteryModel` used to be a
/// `@StateObject` on `ReaderView`, where its minute-aligned tick published `now`
/// and `displayTime` and so invalidated the entire reader body — a device trace
/// measured ~13 ms of `buildBody()`, the toolbars and both bar models on E cores,
/// which at 120 Hz is a dropped frame whenever the minute rolled over mid-fling.
/// Nothing outside these two bars and the page-baked ones reads the clock, so the
/// subscription belongs down here, where a tick redraws two bars and stops.
///
/// Mounted in every reading mode. Paged CoreText draws its bars into the page
/// rather than over it and passes `drawsFixedBars: false`, but its bars still have
/// to tick, and `onClockTick` is what rebuilds them.
struct ReaderPageBarsLayer: View {
    let visibility: ReaderBarVisibility
    let drawsFixedBars: Bool
    let headerTopOffset: CGFloat
    let footerBottomOffset: CGFloat
    let model: @MainActor (ReaderBar, ReaderOverlayClockSnapshot) -> ReaderBarRenderModel
    let onClockTick: @MainActor (ReaderOverlayClockSnapshot) -> Void

    @StateObject private var clock = ClockBatteryModel()

    /// The fade the whole bar container used to carry at the call site. It moved in
    /// here with the container: the layer is mounted in every mode now, so a
    /// transition on it would never run — only the bars inside it come and go.
    private static let barTransition: AnyTransition = .opacity.animation(DSAnimation.fast)

    var body: some View {
        VStack(spacing: 0) {
            if drawsFixedBars && visibility.showsHeader {
                ReaderBarView(model: model(.header, clock.snapshot))
                    .padding(.top, headerTopOffset)
                    .transition(Self.barTransition)
            }
            Spacer(minLength: 0)
            if drawsFixedBars && visibility.showsFooter {
                ReaderBarView(model: model(.footer, clock.snapshot))
                    .padding(.bottom, footerBottomOffset)
                    .transition(Self.barTransition)
            }
        }
        .ignoresSafeArea()
        // The layer stays mounted even when it paints nothing, so it must never take
        // a touch away from the page underneath.
        .allowsHitTesting(false)
        // `didUpdate`, not `$now`: `@Published` emits in `willSet`, and the page-baked
        // bars re-read the model, so the projected publisher would bake the minute
        // that just ended.
        .onReceive(clock.didUpdate) { onClockTick($0) }
        // Seeds the controller before the first tick, so the page-baked bars are
        // built from a real reading rather than the placeholder.
        .onAppear { onClockTick(clock.snapshot) }
    }
}

/// Same reason as `ReaderBarsPreviewHost` above: the model is built in a stored
/// property so the preview body stays one expression.
private struct ReaderPageBarsLayerPreviewHost: View {
    @State private var builder = ReaderBarRenderModelBuilder()

    private var snapshot: ReaderOverlayContentSnapshot {
        ReaderOverlayContentSnapshot(
            bookTitle: "紅樓夢",
            chapterTitle: "第一回 甄士隱夢幻識通靈",
            chapterPage: 3,
            chapterPageCount: 12,
            pageScope: .chapterBody,
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
            Color(uiColor: ReaderTheme.sepia.uiBackgroundColor).ignoresSafeArea()
            ReaderPageBarsLayer(
                visibility: ReaderBarVisibility(showsHeader: true, showsFooter: true),
                drawsFixedBars: true,
                headerTopOffset: 24,
                footerBottomOffset: 16,
                model: { bar, _ in model(for: bar) },
                onClockTick: { _ in }
            )
        }
    }

    private func model(for bar: ReaderBar) -> ReaderBarRenderModel {
        builder.model(
            for: bar,
            layout: .default,
            content: snapshot,
            readerTextColor: ReaderTheme.sepia.uiTextColor,
            horizontalPadding: ReaderLayoutMetrics.defaultHeaderHorizontalPadding,
            svgAssetStore: nil,
            userInterfaceStyle: .light,
            displayScale: 3
        )
    }
}

#Preview("頁眉頁腳層") {
    ReaderPageBarsLayerPreviewHost()
}
