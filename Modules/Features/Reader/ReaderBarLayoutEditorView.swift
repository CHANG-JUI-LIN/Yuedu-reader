import SwiftUI
import UIKit

/// 頁首頁尾 editor: which info field sits in which of the six bar slots, how the
/// two bars are drawn, and shared style with individual field colors.
///
/// A pushed settings page rather than the in-place drag canvas it replaces. Two
/// things fall out of that: it works in scroll mode (the canvas was paged-only,
/// which is why scroll mode had no bars at all), and it never presents a sheet
/// from inside a sheet — the iOS 17 trap `Technotes/iOS17MenuModalPresentation.md`
/// documents.
struct ReaderBarLayoutEditorView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var readerConfig = ReaderConfig.shared
    @StateObject private var clock = ClockBatteryModel()
    /// The preview is drawn by the same renderer the reading page bakes in, so
    /// what you set here is literally what the page draws.
    @State private var barBuilder = ReaderBarRenderModelBuilder()

    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .callout) private var previewHeight = 132.0

    let theme: ReaderTheme
    var readerSafeTop: CGFloat = 0
    var readerSafeBottom: CGFloat = 0
    var svgAssetStore: ReaderOverlaySVGAssetStore?

    @State private var saveFailed = false

    // MARK: - Body

    var body: some View {
        List {
            previewSection
            fieldsSection
            styleSection
            barSection(.header)
            barSection(.footer)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        .navigationTitle(localized("頁首頁尾"))
        .toolbarTitleDisplayMode(.inline)
        .alert(localized("無法儲存頁首頁尾設定"), isPresented: $saveFailed) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(localized("請稍後再試。"))
        }
    }

    // MARK: - Preview

    /// Shows both bars over the reader's own background, with the real clock and
    /// battery. Sample values stand in for the book and chapter, which the editor
    /// has no access to when it is reached from Settings rather than the reader.
    private var previewSection: some View {
        Section {
            ZStack {
                Color(uiColor: theme.uiBackgroundColor)
                VStack(spacing: 0) {
                    if visibility.showsHeader {
                        bar(.header)
                    }
                    Spacer(minLength: DSSpacing.sm)
                    Text(localized("正文預覽"))
                        .font(DSFont.callout)
                        .foregroundStyle(Color(uiColor: theme.uiTextColor))
                    Spacer(minLength: DSSpacing.sm)
                    if visibility.showsFooter {
                        bar(.footer)
                    }
                }
                .padding(.vertical, DSSpacing.sm)
            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            .listRowInsets(EdgeInsets())
            .accessibilityElement(children: .contain)
        } footer: {
            Text(localized("預覽使用示例書名與章節名，時間與電量為實際數值。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func bar(_ which: ReaderBar) -> some View {
        ReaderBarView(
            model: barBuilder.model(
                for: which,
                layout: layout,
                content: previewContent,
                readerTextColor: theme.uiTextColor,
                horizontalPadding: which == .header
                    ? readerConfig.readerHeaderHorizontalPadding
                    : readerConfig.readerFooterHorizontalPadding,
                svgAssetStore: svgAssetStore,
                userInterfaceStyle: theme == .night ? .dark : .light,
                displayScale: displayScale
            )
        )
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        Section {
            ForEach(ReaderOverlayComponentKind.allCases, id: \.self) { kind in
                fieldRow(kind)
            }
        } header: {
            Text(localized("欄位"))
        } footer: {
            Text(localized("同一格可以放多個欄位，會以「·」分隔並排。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder
    private func fieldRow(_ kind: ReaderOverlayComponentKind) -> some View {
        let slot = layout.slot(for: kind)
        Picker(
            selection: Binding(
                get: { slot },
                set: { newSlot in update { $0.setSlot(newSlot, for: kind) } }
            )
        ) {
            ForEach(ReaderBarSlot.allCases) { candidate in
                Text(localized(candidate.titleKey)).tag(candidate)
            }
        } label: {
            Text(localized(ReaderBarFieldNaming.titleKey(for: kind)))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
        }
        .pickerStyle(.menu)

        if slot != .hidden {
            fieldOptions(kind)
        }
        fieldColorOptions(kind)
    }

    private func fieldColorOptions(_ kind: ReaderOverlayComponentKind) -> some View {
        let title = String(format: localized("%@顏色"), localized(ReaderBarFieldNaming.titleKey(for: kind)))
        return DisclosureGroup {
            Picker(localized("顏色"), selection: Binding<ReaderOverlayColorSource?>(
                get: { layout.fields.first { $0.kind == kind }?.color?.source },
                set: { source in
                    update { layout in
                        var color = layout.fields.first { $0.kind == kind }?.color
                            ?? ReaderOverlayColorReference(source: .custom)
                        if let source { color.source = source }
                        layout.setColor(source == nil ? nil : color, for: kind)
                    }
                }
            )) {
                Text(localized("沿用共用顏色")).tag(Optional<ReaderOverlayColorSource>.none)
                Text(localized("跟隨正文顏色")).tag(Optional(ReaderOverlayColorSource.readerText))
                Text(localized("自訂顏色")).tag(Optional(ReaderOverlayColorSource.custom))
            }
            .pickerStyle(.menu)
            .accessibilityLabel(title)

            if layout.fields.first(where: { $0.kind == kind })?.color?.source == .custom {
                ColorPicker(localized("亮色模式"), selection: colorBinding(dark: false, field: kind))
                    .accessibilityLabel("\(title)，\(localized("亮色模式"))")
                ColorPicker(localized("深色模式"), selection: colorBinding(dark: true, field: kind))
                    .accessibilityLabel("\(title)，\(localized("深色模式"))")
            }
        } label: {
            Text(title)
        }
        .font(DSFont.body)
    }

    @ViewBuilder
    private func fieldOptions(_ kind: ReaderOverlayComponentKind) -> some View {
        let configuration = layout.fields.first { $0.kind == kind }?.configuration
            ?? ReaderOverlayComponentConfiguration()

        switch kind {
        case .battery:
            Toggle(
                localized("顯示電量百分比"),
                isOn: Binding(
                    get: { configuration.showsBatteryPercentage },
                    set: { newValue in
                        var next = configuration
                        next.showsBatteryPercentage = newValue
                        update { $0.setConfiguration(next, for: kind) }
                    }
                )
            )
            .font(DSFont.body)

        case .customText:
            TextField(
                localized("自訂文字"),
                text: Binding(
                    get: { configuration.customText },
                    set: { newValue in
                        var next = configuration
                        next.customText = newValue
                        update { $0.setConfiguration(next, for: kind) }
                    }
                )
            )
            .font(DSFont.body)

        case .currentTime, .currentDate, .chapterPage, .readingDuration, .remainingTime:
            Picker(
                selection: Binding(
                    get: { configuration.displayFormat },
                    set: { newValue in
                        var next = configuration
                        next.displayFormat = newValue
                        update { $0.setConfiguration(next, for: kind) }
                    }
                )
            ) {
                ForEach(ReaderBarFieldNaming.formats(for: kind), id: \.self) { format in
                    Text(localized(ReaderBarFieldNaming.titleKey(for: format))).tag(format)
                }
            } label: {
                Text(localized("顯示格式"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .pickerStyle(.menu)

        default:
            EmptyView()
        }
    }

    // MARK: - Per-bar

    private func barSection(_ which: ReaderBar) -> some View {
        Section {
            Toggle(
                localized(which == .header ? "顯示頁眉" : "顯示頁腳"),
                isOn: which == .header
                    ? $readerConfig.readerHeaderVisible
                    : $readerConfig.readerFooterVisible
            )
            .font(DSFont.body)

            Toggle(
                localized("分隔線"),
                isOn: Binding(
                    get: {
                        which == .header ? layout.showsHeaderDivider : layout.showsFooterDivider
                    },
                    set: { newValue in
                        update {
                            if which == .header {
                                $0.showsHeaderDivider = newValue
                            } else {
                                $0.showsFooterDivider = newValue
                            }
                        }
                    }
                )
            )
            .font(DSFont.body)

            if which == .header {
                Toggle(
                    localized("章節首頁隱藏頁眉"),
                    isOn: Binding(
                        get: { layout.hidesHeaderOnChapterOpening },
                        set: { newValue in
                            update { $0.hidesHeaderOnChapterOpening = newValue }
                        }
                    )
                )
                .font(DSFont.body)
            }

            BarSliderRow(
                title: localized(which == .header ? "距離頂端" : "距離底部"),
                value: edgeDistanceBinding(for: which),
                range: 0...max(CGFloat(ReaderBarEdgeDistances.adjustmentRange.upperBound), edgeDistance(for: which))
            )

            BarSliderRow(
                title: localized("左右邊距"),
                value: which == .header
                    ? $readerConfig.readerHeaderHorizontalPadding
                    : $readerConfig.readerFooterHorizontalPadding,
                range: 0...48
            )
        } header: {
            Text(localized(which.titleKey))
        } footer: {
            Text(localized("距離從畫面邊緣計算，可設為 0，不受安全區限制。未調整前保留目前位置。"))
                .dsSectionFooter()
            if which == .header {
                Text(localized("章節首頁的頁眉只是不畫出來，保留的空間不變——否則該頁會比其他頁多容納一行。"))
                    .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    // MARK: - Shared style

    private var styleSection: some View {
        Section {
            Picker(localized("顏色"), selection: Binding(
                get: { layout.style.color.source },
                set: { source in update { $0.style.color.source = source } }
            )) {
                Text(localized("跟隨正文顏色")).tag(ReaderOverlayColorSource.readerText)
                Text(localized("自訂顏色")).tag(ReaderOverlayColorSource.custom)
            }
            .font(DSFont.body)
            .pickerStyle(.menu)

            if layout.style.color.source == .custom {
                ColorPicker(localized("亮色模式"), selection: colorBinding(dark: false))
                    .font(DSFont.body)
                ColorPicker(localized("深色模式"), selection: colorBinding(dark: true))
                    .font(DSFont.body)
            }

            BarSliderRow(
                title: localized("字級"),
                value: Binding(
                    get: { CGFloat(layout.style.fontSize) },
                    set: { newValue in
                        update { $0.style.fontSize = Double(newValue) }
                    }
                ),
                range: Self.fontSizeRange
            )

            Picker(
                selection: Binding(
                    get: { layout.style.weight },
                    set: { newValue in update { $0.style.weight = newValue } }
                )
            ) {
                ForEach(ReaderBarFieldNaming.weights, id: \.self) { weight in
                    Text(localized(ReaderBarFieldNaming.titleKey(for: weight))).tag(weight)
                }
            } label: {
                Text(localized("字重"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
            }
            .pickerStyle(.menu)

            BarSliderRow(
                title: localized("不透明度"),
                value: Binding(
                    get: { CGFloat(layout.style.opacity) },
                    set: { newValue in update { $0.style.opacity = Double(newValue) } }
                ),
                range: Self.opacityRange,
                step: 0.05,
                valueText: "\(Int((layout.style.opacity * 100).rounded()))%"
            )
        } header: {
            Text(localized("樣式"))
        } footer: {
            Text(localized("此處設定共用樣式。各組件可在「欄位」中分別調整顏色，並設定淺色與深色模式。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    // MARK: - State

    private func edgeDistance(for bar: ReaderBar) -> CGFloat {
        if bar == .header {
            return ReaderLayoutMetrics.headerBarTopOffset(
                safeTop: readerSafeTop,
                headerTopPadding: readerConfig.readerHeaderTopPadding,
                edgeDistance: layout.edgeDistances.header
            )
        }
        return ReaderLayoutMetrics.footerBarBottomOffset(
            safeBottom: readerSafeBottom,
            footerBottomPadding: readerConfig.footerBottomPadding,
            edgeDistance: layout.edgeDistances.footer
        )
    }

    private func edgeDistanceBinding(for bar: ReaderBar) -> Binding<CGFloat> {
        Binding(
            get: { edgeDistance(for: bar) },
            set: { distance in update { $0.edgeDistances[bar] = Double(distance) } }
        )
    }

    private func colorBinding(dark: Bool, field: ReaderOverlayComponentKind? = nil) -> Binding<Color> {
        let appearance: UIUserInterfaceStyle = dark ? .dark : .light
        let previewTheme: ReaderTheme = dark ? .night : (theme == .night ? .white : theme)
        return Binding(
            get: {
                var style = layout.style
                if let field {
                    style.color = layout.fields.first { $0.kind == field }?.color ?? style.color
                }
                return Color(uiColor: ReaderBarStyleResolver.resolve(
                    style,
                    readerTextColor: previewTheme.uiTextColor,
                    userInterfaceStyle: appearance
                ).color)
            },
            set: { color in
                guard let hex = ReaderOverlayPresentationResolver.rgbaHex(
                    UIColor(color), userInterfaceStyle: appearance
                ), let value = UInt32(hex.dropFirst(), radix: 16) else { return }
                update { layout in
                    var reference = field.flatMap { kind in
                        layout.fields.first { $0.kind == kind }?.color
                    } ?? layout.style.color
                    reference.source = .custom
                    if dark {
                        reference.darkHexRGBA = value
                    } else {
                        reference.hexRGBA = value
                    }
                    if let field {
                        layout.setColor(reference, for: field)
                    } else {
                        layout.style.color = reference
                    }
                }
            }
        )
    }

    /// `ClosedRange` needs both bounds on one line — a `...` at the head of a
    /// continuation line parses as a prefix operator, not a range.
    private static let fontSizeRange: ClosedRange<CGFloat> =
        CGFloat(ReaderBarStyle.fontSizeRange.lowerBound)...CGFloat(ReaderBarStyle.fontSizeRange.upperBound)

    private static let opacityRange: ClosedRange<CGFloat> =
        CGFloat(ReaderBarStyle.opacityRange.lowerBound)...CGFloat(ReaderBarStyle.opacityRange.upperBound)

    private var layout: ReaderBarLayout { settings.readerBarLayout }

    private var visibility: ReaderBarVisibility {
        ReaderOverlayPresentationPolicy.visibility(
            layout: layout,
            headerEnabled: readerConfig.readerHeaderVisible,
            footerEnabled: readerConfig.readerFooterVisible,
            isChapterOpeningPage: false
        )
    }

    private var previewContent: ReaderOverlayContentSnapshot {
        ReaderOverlayContentSnapshot(
            bookTitle: localized("示例書名"),
            chapterTitle: localized("第一章 示例章節"),
            chapterPage: 3,
            chapterPageCount: 12,
            totalProgress: 0.4523,
            now: clock.now,
            batteryLevel: clock.batteryLevel,
            isCharging: clock.isCharging,
            readingDuration: 1_500,
            estimatedRemainingTime: 4_200
        )
    }

    /// Every edit goes through here so a failed write surfaces once, in one place,
    /// instead of each control silently keeping a value that was never persisted.
    private func update(_ mutate: (inout ReaderBarLayout) -> Void) {
        var next = layout
        mutate(&next)
        guard settings.saveReaderBarLayout(next) else {
            saveFailed = true
            return
        }
    }
}

// MARK: - Slider row

/// A `Slider` has no name of its own and announces a fraction of its range, so it
/// carries the row's title and the value shown beside it — `docs/design.md` §7.1.
private struct BarSliderRow: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 1
    var valueText: String?

    private var displayValue: String {
        valueText ?? String(
            format: localized("ReaderOverlay.Format.Points"),
            Int(value.rounded())
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer()
                Text(displayValue)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityHidden(true)

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(displayValue)
        }
    }
}

// MARK: - Naming

/// Display names for the field kinds, formats and weights the editor offers.
///
/// Separate from `ReaderOverlayPresentationResolver.accessibilityLabel`, which
/// names the same kinds for VoiceOver: that one is spoken mid-sentence with the
/// value after it, this one is a row title. They happen to agree today; keeping
/// them apart means changing one phrasing cannot silently change the other.
enum ReaderBarFieldNaming {
    static func titleKey(for kind: ReaderOverlayComponentKind) -> String {
        switch kind {
        case .bookTitle: "書名"
        case .chapterTitle: "章節名"
        case .chapterPage: "本章頁碼"
        case .totalProgressText: "總進度"
        case .progressBar: "進度條"
        case .currentTime: "目前時間"
        case .currentDate: "目前日期"
        case .weekday: "星期"
        case .battery: "電量"
        case .readingDuration: "本次閱讀時長"
        case .remainingTime: "預估剩餘時間"
        case .customText: "自訂文字"
        }
    }

    static func titleKey(for format: ReaderOverlayDisplayFormat) -> String {
        switch format {
        case .automatic: "自動"
        case .compact: "精簡"
        case .detailed: "詳細"
        case .fraction: "分數"
        case .percentage: "百分比"
        case .hourMinute24: "24 小時制"
        case .hourMinute12: "12 小時制"
        }
    }

    static func titleKey(for weight: ReaderOverlayFontWeight) -> String {
        switch weight {
        case .light: "細"
        case .regular: "標準"
        case .medium: "中等"
        case .semibold: "半粗"
        case .bold: "粗"
        }
    }

    static let weights: [ReaderOverlayFontWeight] = [.light, .regular, .medium, .semibold, .bold]

    /// Only the formats a kind actually understands. Offering every case would let
    /// someone set 「24 小時制」 on the page number and see nothing change.
    static func formats(for kind: ReaderOverlayComponentKind) -> [ReaderOverlayDisplayFormat] {
        switch kind {
        case .currentTime: [.automatic, .hourMinute24, .hourMinute12]
        case .chapterPage: [.automatic, .compact, .fraction]
        case .readingDuration, .remainingTime: [.automatic, .compact, .detailed]
        case .currentDate: [.automatic, .compact, .detailed]
        default: [.automatic]
        }
    }
}

#Preview("頁首頁尾編輯") {
    NavigationStack {
        ReaderBarLayoutEditorView(theme: .sepia)
    }
}

#Preview("頁首頁尾編輯 · 夜間") {
    NavigationStack {
        ReaderBarLayoutEditorView(theme: .night)
    }
    .preferredColorScheme(.dark)
}
