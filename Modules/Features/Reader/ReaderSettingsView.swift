import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderSettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var theme: ReaderTheme
    var capabilities: ReaderCapabilities = .reflowableText
    var allowsUserSelectedReaderFont = false
    var isVerticalWritingMode = false
    var hasParagraphReviews = false
    var onOpenFontImporter: () -> Void
    var onOpenHeaderFooterEditor: (() -> Void)?
    var onOpenTouchZoneEditor: (() -> Void)?

    @StateObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingFontImporter = false
    @State private var showingLayoutImporter = false
    @State private var fontImportError: FontImportError?
    @State private var layoutImportAlert: LayoutImportAlert?
    @State private var customLayoutEnabled = true
    @State private var showingOverlayResetConfirmation = false
    @State private var showingOverlayImportConfirmation = false
    @State private var pendingLayoutPreset: ReaderLayoutPreset?

    private var supportsFontSize: Bool { capabilities.contains(.fontSize) }
    private var supportsUserFont: Bool { supportsFontSize && allowsUserSelectedReaderFont }
    private var supportsLineHeight: Bool { capabilities.contains(.lineHeight) }
    private var supportsSpacing: Bool { capabilities.contains(.spacing) }
    private var supportsPageDisplay: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && supportsLineHeight && !settings.scrollMode
    }
    private var pageBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var readerTint: Color {
        theme.accentColor
    }

    private let previewTextHeight: CGFloat = 220
    private let defaultLineHeightMultiple: CGFloat = 1.65
    private let defaultLetterSpacing: CGFloat = 0
    private let defaultParagraphSpacingMultiplier: CGFloat = 0.8
    private let defaultPageMarginH: CGFloat = 24
    private let defaultPageMarginV: CGFloat = 16

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewPanel
                Divider()

                // Section order follows what a reader reaches for most: what the
                // text looks like, how it is spaced, where it sits on the page,
                // then the surrounding chrome and one-off utilities.
                Form {
                    if supportsUserFont || supportsFontSize {
                        textSection
                    }

                    if supportsSpacing {
                        spacingSection
                    }

                    if supportsLineHeight {
                        pageMarginSection
                    }

                    if showsPagingSection {
                        pagingSection
                    }

                    if showsHeaderFooterSection {
                        headerFooterSection
                    }

                    if premiumVisibility.showsReaderDecoration {
                        readerDecorationSection
                    }

                    brightnessSection

                    if premiumVisibility.showsLayoutPresetImport {
                        layoutPresetSection
                    }
                }
            }
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("閱讀設定"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss() // 點擊叉叉直接離開
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {dismiss() } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
        .tint(readerTint)
        .fileImporter(
            isPresented: $showingFontImporter,
            allowedContentTypes: Self.fontContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFontImport(result)
        }
        .fileImporter(
            isPresented: $showingLayoutImporter,
            allowedContentTypes: Self.layoutPresetContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleLayoutImport(result)
        }
        .alert(item: $fontImportError) { error in
            Alert(
                title: Text(localized("字體匯入失敗")),
                message: Text(error.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
        .alert(item: $layoutImportAlert) { alert in
            Alert(
                title: Text(localized(alert.titleKey)),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
        .alert(
            localized("重設頁首頁尾？"),
            isPresented: $showingOverlayResetConfirmation
        ) {
            Button(localized("重設"), role: .destructive) {
                resetReaderOverlayLayout()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("這會恢復預設組件、位置與正文保留空間。"))
        }
        .alert(
            localized("套用匯入的頁首頁尾？"),
            isPresented: $showingOverlayImportConfirmation
        ) {
            Button(localized("套用")) {
                guard let preset = pendingLayoutPreset else { return }
                pendingLayoutPreset = nil
                finishLayoutPresetImport(preset)
            }
            Button(localized("取消"), role: .cancel) {
                pendingLayoutPreset = nil
            }
        } message: {
            Text(localized("這會取代目前的頁首頁尾組件、位置與正文保留空間。"))
        }
        .onChanged(of: showingOverlayImportConfirmation) { isPresented in
            if !isPresented {
                pendingLayoutPreset = nil
            }
        }
        .onAppear {
            customLayoutEnabled = hasCustomLayoutOverrides
            if settings.followSystemBrightness {
                syncBrightnessFromSystem()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in
            if settings.followSystemBrightness {
                syncBrightnessFromSystem()
            }
        }
    }

    private var premiumVisibility: ReaderPremiumVisibilityPolicy {
        ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive)
    }

    private var showsCommentBubbleSettings: Bool {
        premiumVisibility.showsCommentBubbleSettings(hasParagraphReviews: hasParagraphReviews)
    }

    /// Paged-only chrome and gestures. Scroll mode has no page turns, no fixed
    /// header/footer and no tap zones, so the whole section stands down there.
    private var showsPagingSection: Bool {
        !settings.scrollMode
    }

    private var showsHeaderFooterSection: Bool {
        !settings.scrollMode && onOpenHeaderFooterEditor != nil
    }

    private var pagingSection: some View {
        Section {
            if supportsPageDisplay {
                SegmentedPickerRow(
                    title: localized("頁面顯示"),
                    selection: $settings.readerSpreadMode,
                    items: ReaderSpreadMode.settingsCases,
                    titleProvider: { mode in
                        localized(spreadTitleKey(for: mode))
                    }
                )
            }

            ToggleRow(
                title: localized("全局翻頁"),
                subtitle: localized("開啟後，點畫面左右兩側都翻到下一頁；中間仍呼出選單"),
                isOn: $settings.readerTapBothSidesNextPage
            )

            ToggleRow(
                title: localized("上滑退出閱讀"),
                subtitle: localized("向上滑動時浮現「✕」，滑過一半後鬆手即退出閱讀器"),
                isOn: $settings.readerSwipeUpToExit
            )

            if premiumVisibility.showsTouchZoneEditor,
               let onOpenTouchZoneEditor {
                Button {
                    dismiss()
                    DispatchQueue.main.async { onOpenTouchZoneEditor() }
                } label: {
                    Label(localized("翻頁區塊編輯"), systemImage: "hand.tap")
                }
            }
        } header: {
            Text(localized("翻頁與手勢"))
        }
        .interfaceSectionSurface()
    }

    private var headerFooterSection: some View {
        Section {
            if let onOpenHeaderFooterEditor {
                Button {
                    dismiss()
                    DispatchQueue.main.async { onOpenHeaderFooterEditor() }
                } label: {
                    Label(localized("頁首頁尾編輯"), systemImage: "rectangle.split.3x1")
                }

                Button(role: .destructive) {
                    showingOverlayResetConfirmation = true
                } label: {
                    Label(localized("重設頁首頁尾"), systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text(localized("頁首頁尾"))
        } footer: {
            Text(localized("組件的正文保留空間改在「頁面邊距」調整。"))
        }
        .interfaceSectionSurface()
    }

    private var layoutPresetSection: some View {
        Section {
            Button {
                showingLayoutImporter = true
            } label: {
                Label(localized("匯入排版參數"), systemImage: "square.and.arrow.down")
            }
        } header: {
            Text(localized("排版參數"))
        } footer: {
            Text(localized("匯入的檔案會覆蓋目前的字體大小、間距、頁面邊距與頁首頁尾配置。"))
        }
        .interfaceSectionSurface()
    }

    private func overlayReservationBinding(
        _ keyPath: WritableKeyPath<ReaderOverlayContentReservations, Double>
    ) -> Binding<CGFloat> {
        Binding(
            get: {
                CGFloat(settings.readerOverlayLayout.contentReservations[keyPath: keyPath])
            },
            set: { value in
                var layout = settings.readerOverlayLayout
                layout.contentReservations[keyPath: keyPath] = Double(value)
                guard settings.saveReaderOverlayLayout(layout) else {
                    layoutImportAlert = LayoutImportAlert(
                        titleKey: "無法儲存頁首頁尾設定",
                        message: localized("請稍後再試。")
                    )
                    return
                }
            }
        )
    }

    private func resetReaderOverlayLayout() {
        guard settings.saveReaderOverlayLayout(.default) else {
            layoutImportAlert = LayoutImportAlert(
                titleKey: "無法儲存頁首頁尾設定",
                message: localized("請稍後再試。")
            )
            return
        }
    }

    /// All three body margins in one place. They used to live apart — the
    /// horizontal one as 「頁面留白」 among the spacing sliders, the vertical pair as
    /// 「正文頂部/底部保留空間」 under 閱讀工具 — which read as if 頁面留白 covered every
    /// side. Same underlying values, one group, names that say which edge.
    ///
    /// Paged and scroll mode genuinely inset the body through different values:
    /// paged reserves top/bottom via the overlay layout (that reservation *is* the
    /// vertical margin there), scroll uses `pageMarginV` for both edges at once.
    private var pageMarginSection: some View {
        Section {
            LayoutSliderRow(
                title: localized("左右邊距"),
                icon: .pageMarginHorizontal,
                valueText: String(format: localized("ReaderOverlay.Format.Points"), Int(readerConfig.pageMarginH)),
                value: $readerConfig.pageMarginH,
                range: 0...50,
                step: 1
            )

            if settings.scrollMode {
                LayoutSliderRow(
                    title: localized("上下邊距"),
                    icon: .pageMarginVertical,
                    valueText: String(format: localized("ReaderOverlay.Format.Points"), Int(readerConfig.pageMarginV)),
                    value: $readerConfig.pageMarginV,
                    range: 0...50,
                    step: 1
                )
            } else {
                LayoutSliderRow(
                    title: localized("上邊距"),
                    icon: .pageMarginTop,
                    valueText: String(
                        format: localized("ReaderOverlay.Format.Points"),
                        Int(settings.readerOverlayLayout.contentReservations.top)
                    ),
                    value: overlayReservationBinding(\.top),
                    range: 0...120,
                    step: 1
                )

                LayoutSliderRow(
                    title: localized("下邊距"),
                    icon: .pageMarginBottom,
                    valueText: String(
                        format: localized("ReaderOverlay.Format.Points"),
                        Int(settings.readerOverlayLayout.contentReservations.bottom)
                    ),
                    value: overlayReservationBinding(\.bottom),
                    range: 0...120,
                    step: 1
                )
            }

            Button {
                resetPageMargins()
            } label: {
                Label(localized("還原預設邊距"), systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text(localized("頁面邊距"))
        } footer: {
            Text(
                settings.scrollMode
                    ? localized("正文與畫面邊緣的距離。")
                    : localized("正文與畫面邊緣的距離；上下邊距同時是頁首頁尾組件的容身空間，改動只影響正文排版，不會移動組件本身。")
            )
        }
        .interfaceSectionSurface()
    }

    private func resetPageMargins() {
        readerConfig.pageMarginH = defaultPageMarginH
        readerConfig.pageMarginV = defaultPageMarginV
        var layout = settings.readerOverlayLayout
        layout.contentReservations = ReaderOverlayLayout.default.contentReservations
        guard settings.saveReaderOverlayLayout(layout) else {
            layoutImportAlert = LayoutImportAlert(
                titleKey: "無法儲存頁首頁尾設定",
                message: localized("請稍後再試。")
            )
            return
        }
    }

    private func spreadTitleKey(for mode: ReaderSpreadMode) -> String {
        switch mode {
        case .singlePage: return "單頁"
        case .doublePage: return "雙頁"
        case .auto: return "單頁"
        }
    }

    private var textSection: some View {
        Section {
            if supportsUserFont {
                fontSelector
            }

            if supportsFontSize {
                StepperValueRow(
                    title: localized("字體大小"),
                    valueText: "\(Int(fontSize)) pt",
                    value: fontSizeBinding,
                    range: GlobalSettings.readerFontSizeRange,
                    step: 1
                )
            }

            Toggle(isOn: $readerConfig.readerFontBold) {
                HStack(spacing: 16) {
                    SettingSymbolIcon(systemName: "bold")
                    Text(localized("粗體"))
                        .font(DSFont.body)
                }
            }

            ColorPicker(selection: readerTextColorBinding, supportsOpacity: false) {
                HStack(spacing: 16) {
                    SettingSymbolIcon(systemName: "paintpalette")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localized("文字顏色"))
                            .font(DSFont.body)
                        Text(hasReaderTextColorOverride ? localized("自訂") : localized("跟隨主題"))
                            .font(DSFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hasReaderTextColorOverride {
                Button {
                    settings.setReaderTextColorOverride(nil, for: theme)
                } label: {
                    Label(localized("跟隨主題文字顏色"), systemImage: "arrow.counterclockwise")
                }
            }

            if supportsLineHeight {
                NavigationLink {
                    ChapterTitleStyleSettingsView()
                } label: {
                    Label(localized("章節標題樣式"), systemImage: "textformat.size")
                }
            }
        } header: {
            Text(localized("文字"))
        } footer: {
            Text(String(format: localized("文字顏色只套用到目前的閱讀背景（%@）。"), theme.localizedTitle))
        }
        .interfaceSectionSurface()
    }

    private var hasReaderTextColorOverride: Bool {
        settings.readerTextColorOverride(for: theme) != nil
    }

    /// Reads the color the reader is actually painting with, so opening the picker
    /// starts from what is on screen rather than from a blank swatch. Writing one
    /// stores an override for the *current* reading background only.
    private var readerTextColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: theme.uiTextColor) },
            set: { newColor in
                guard let rgbHex = UIColor(newColor).rgbHex else { return }
                settings.setReaderTextColorOverride(rgbHex, for: theme)
            }
        )
    }

    /// Preview font that reflects the user-selected reader font in real time;
    /// falls back to the system font when none is selected (or it can't be loaded).
    private func previewFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let isBold = readerConfig.readerFontBold
        let resolvedWeight: Font.Weight = isBold ? .bold : weight
        if let postScript = settings.selectedReaderFontPostScript,
           !postScript.isEmpty,
           let uiFont = UIFont(name: postScript, size: size) {
            if isBold,
               let descriptor = uiFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                return Font(UIFont(descriptor: descriptor, size: size) as CTFont)
            }
            return Font(uiFont as CTFont)
        }
        return .system(size: size, weight: resolvedWeight)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(localized("大"))
                    .font(previewFont(size: 34))

                Text(localized("小"))
                    .font(previewFont(size: 18))
                    .baselineOffset(-6)
            }
            Text(localized("  這是一段測試文字，用來測試字體大小和行距、字距、段落間距，以及不同主題下的閱讀舒適度。調整設定時，可以觀察文字密度、換行節奏與背景對比是否符合你的閱讀習慣。"))
                .font(previewFont(size: min(max(fontSize, 17), 24)))
                .lineSpacing(readerConfig.lineSpacing)
                .tracking(readerConfig.letterSpacing)
                .foregroundStyle(theme.textColor)
        }
        .padding(.horizontal, readerConfig.pageMarginH)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, minHeight: previewTextHeight, maxHeight: previewTextHeight, alignment: .topLeading)
        .clipped()
        .foregroundStyle(theme.textColor)
        .background(theme.backgroundColor)
    }

    private var fontSelector: some View {
        HStack(spacing: DSSpacing.sm) {
            Menu {
                Button {
                    settings.selectedReaderFontPostScript = nil
                } label: {
                    Label(localized("系統字體"), systemImage: settings.selectedReaderFontPostScript == nil ? "checkmark" : "textformat")
                }

                if !settings.userFonts.isEmpty {
                    Divider()
                    Section {
                        ForEach(settings.userFonts, id: \.id) { font in
                            Button {
                                settings.selectedReaderFontPostScript = font.postScriptName
                            } label: {
                                Label(
                                    font.displayName,
                                    systemImage: settings.selectedReaderFontPostScript == font.postScriptName ? "checkmark" : "textformat"
                                )
                            }
                        }
                    } header: {
                        Text(localized("已匯入字體"))
                    }
                    .interfaceSectionSurface()

                    Menu(localized("刪除字體")) {
                        ForEach(settings.userFonts, id: \.id) { font in
                            Button(role: .destructive) {
                                settings.deleteUserFont(font)
                            } label: {
                                Label(font.displayName, systemImage: "trash")
                            }
                        }
                    }
                }

                if !ReaderSettingsPresentationPolicy.requiresFirstLevelFontImporter {
                    Divider()
                    Button {
                        showingFontImporter = true
                    } label: {
                        Label(localized("匯入字體..."), systemImage: "plus")
                    }
                }
            } label: {
                HStack {
                    Text(localized("字體"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(currentFontName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.down")
                        .font(DSFont.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if ReaderSettingsPresentationPolicy.requiresFirstLevelFontImporter {
                Button {
                    onOpenFontImporter()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(localized("匯入字體..."))
            }
        }
    }

    private var spacingSection: some View {
        Section {
            Toggle(localized("自訂間距"), isOn: customLayoutBinding)
                .font(DSFont.body)

            if customLayoutEnabled {
                LayoutSliderRow(
                    title: localized("行距"),
                    icon: .lineSpacing,
                    valueText: String(format: "%.2f", readerConfig.lineHeightMultiple),
                    value: $readerConfig.lineHeightMultiple,
                    range: 1.0...2.4,
                    step: 0.05
                )

                LayoutSliderRow(
                    title: localized("字距"),
                    icon: .characterSpacing,
                    valueText: "\(String(format: "%.1f", readerConfig.letterSpacing)) pt",
                    value: $readerConfig.letterSpacing,
                    range: 0...12,
                    step: 0.5
                )

                LayoutSliderRow(
                    title: localized("段距"),
                    icon: .paragraphSpacing,
                    valueText: String(format: "%.2f", readerConfig.paragraphSpacingMultiplier),
                    value: $readerConfig.paragraphSpacingMultiplier,
                    range: 0.3...1.2,
                    step: 0.05
                )
            }
        } header: {
            Text(localized("間距"))
        } footer: {
            Text(localized("關閉會還原行距、字距與段距的預設值。"))
        }
        .interfaceSectionSurface()
    }

    private var readerDecorationSection: some View {
        Section(header: Text(localized("閱讀裝飾"))) {
            if showsCommentBubbleSettings {
                NavigationLink {
                    ReaderCommentBubbleSettingsView()
                } label: {
                    Label(localized("氣泡設定"), systemImage: "text.bubble")
                }
            }

            ToggleRow(
                title: localized("文字底線"),
                subtitle: localized("在每行水平正文下方顯示淡底線。"),
                isOn: readerTextUnderlineDecorationBinding
            )

            if settings.readerTextUnderlineDecorationEnabled {
                ColorPicker(
                    localized("底線顏色"),
                    selection: readerTextUnderlineDecorationColorBinding,
                    supportsOpacity: false
                )
                Picker(
                    localized("底線樣式"),
                    selection: readerTextUnderlineStyleBinding
                ) {
                    ForEach(ReaderTextUnderlineStyle.allCases, id: \.self) { style in
                        Label(style.localizedTitle, systemImage: style.systemImageName)
                            .tag(style)
                    }
                }
                ValueSliderRow(
                    title: localized("粗細"),
                    valueText: String(format: "%.1f pt", settings.readerTextUnderlineThickness),
                    value: readerTextUnderlineThicknessBinding,
                    range: GlobalSettings.readerUnderlineThicknessRange,
                    step: 0.1
                )

                ValueSliderRow(
                    title: localized("偏移"),
                    valueText: String(format: "%.1f pt", settings.readerTextUnderlineOffset),
                    value: readerTextUnderlineOffsetBinding,
                    range: GlobalSettings.readerUnderlineOffsetRange,
                    step: 0.5
                )
            }

            NavigationLink {
                RegexHighlightSettingsView(
                    configuration: settings.regexHighlightConfiguration,
                    onChange: { settings.regexHighlightConfiguration = $0 }
                )
            } label: {
                Label(localized("正則高亮"), systemImage: "text.magnifyingglass")
            }
        }
        .interfaceSectionSurface()
    }

    private var brightnessSection: some View {
        Section(header: Text(localized("亮度"))) {
            ToggleRow(
                title: localized("跟隨系統亮度"),
                subtitle: localized("建議保持開啟，閱讀時更自然"),
                isOn: followSystemBrightnessBinding
            )

            ValueSliderRow(
                title: localized("閱讀亮度"),
                valueText: "\(Int(settings.readerBrightness * 100))%",
                value: readerBrightnessBinding,
                range: 0.05...1.0,
                step: 0.05,
                isDisabled: settings.followSystemBrightness
            )
        }
        .interfaceSectionSurface()
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { fontSize },
            set: { fontSize = GlobalSettings.clampedReaderFontSize($0) }
        )
    }

    private var customLayoutBinding: Binding<Bool> {
        Binding(
            get: { customLayoutEnabled },
            set: { isEnabled in
                customLayoutEnabled = isEnabled
                guard !isEnabled else { return }
                resetLayoutDefaults()
            }
        )
    }

    /// Scoped to the three spacing metrics the 自訂間距 toggle actually governs.
    /// Margins moved out to 頁面邊距 with their own reset, so a customised margin no
    /// longer makes this toggle claim the spacing sliders are customised too.
    private var hasCustomLayoutOverrides: Bool {
        abs(readerConfig.lineHeightMultiple - defaultLineHeightMultiple) > 0.001 ||
            abs(readerConfig.letterSpacing - defaultLetterSpacing) > 0.001 ||
            abs(readerConfig.paragraphSpacingMultiplier - defaultParagraphSpacingMultiplier) > 0.001
    }

    private func resetLayoutDefaults() {
        readerConfig.lineHeightMultiple = defaultLineHeightMultiple
        readerConfig.letterSpacing = defaultLetterSpacing
        readerConfig.paragraphSpacingMultiplier = defaultParagraphSpacingMultiplier
    }

    private var followSystemBrightnessBinding: Binding<Bool> {
        Binding(
            get: { settings.followSystemBrightness },
            set: { follow in
                settings.followSystemBrightness = follow
                if follow {
                    syncBrightnessFromSystem()
                } else {
                    UIScreen.main.brightness = CGFloat(settings.readerBrightness)
                }
            }
        )
    }

    private var readerBrightnessBinding: Binding<Double> {
        Binding(
            get: { settings.readerBrightness },
            set: { value in
                settings.readerBrightness = value
                if !settings.followSystemBrightness {
                    UIScreen.main.brightness = CGFloat(value)
                }
            }
        )
    }

    private var readerTextUnderlineDecorationBinding: Binding<Bool> {
        Binding(
            get: { settings.readerTextUnderlineDecorationEnabled },
            set: { enabled in
                settings.readerTextUnderlineDecorationEnabled = enabled
            }
        )
    }

    private var readerTextUnderlineDecorationColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(uiColor: GlobalSettings.uiColor(rgbHex: settings.readerTextUnderlineDecorationColorHex))
            },
            set: {
                settings.readerTextUnderlineDecorationColorHex =
                    UIColor($0).rgbHex ?? GlobalSettings.defaultReaderUnderlineColorHex
            }
        )
    }

    private var readerTextUnderlineStyleBinding: Binding<ReaderTextUnderlineStyle> {
        Binding(
            get: { settings.readerTextUnderlineStyle },
            set: { style in
                settings.readerTextUnderlineStyle = style
            }
        )
    }

    private var readerTextUnderlineThicknessBinding: Binding<Double> {
        Binding(
            get: { settings.readerTextUnderlineThickness },
            set: { value in
                settings.readerTextUnderlineThickness = value
            }
        )
    }

    private var readerTextUnderlineOffsetBinding: Binding<Double> {
        Binding(
            get: { settings.readerTextUnderlineOffset },
            set: { value in
                settings.readerTextUnderlineOffset = value
            }
        )
    }

    private var currentFontName: String {
        guard let selected = settings.selectedReaderFontPostScript else { return localized("系統字體") }
        return settings.userFonts.first { $0.postScriptName == selected }?.displayName ?? selected
    }


    private func syncBrightnessFromSystem() {
        settings.readerBrightness = Double(UIScreen.main.brightness)
    }

    static let fontContentTypes: [UTType] = [
        .font,
        UTType(filenameExtension: "ttf") ?? .data,
        UTType(filenameExtension: "otf") ?? .data,
    ]

    private static let layoutPresetContentTypes: [UTType] = [
        .json,
        UTType(filenameExtension: "zip") ?? .data,
    ]

    private func handleFontImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try settings.importReaderFont(from: url)
        } catch {
            fontImportError = FontImportError(message: error.localizedDescription)
        }
    }

    private func handleLayoutImport(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            do {
                guard let url = try result.get().first else { return }
                let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStopAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let preset = try await ReaderLayoutPresetImporter.importPreset(from: url)
                if preset.readerOverlayLayout != nil {
                    pendingLayoutPreset = preset
                    showingOverlayImportConfirmation = true
                    return
                }
                finishLayoutPresetImport(preset)
            } catch {
                layoutImportAlert = LayoutImportAlert(
                    titleKey: "排版匯入失敗",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func finishLayoutPresetImport(_ preset: ReaderLayoutPreset) {
        guard applyLayoutPreset(preset) else {
            layoutImportAlert = LayoutImportAlert(
                titleKey: "排版匯入失敗",
                message: localized("無法儲存頁首頁尾設定")
            )
            return
        }
        let importedName = preset.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = importedName?.isEmpty == false
            ? String(format: localized("已匯入「%@」的排版參數"), importedName!)
            : localized("已匯入排版參數")
        layoutImportAlert = LayoutImportAlert(titleKey: "排版匯入成功", message: message)
    }

    private func applyLayoutPreset(_ preset: ReaderLayoutPreset) -> Bool {
        if let overlayLayout = preset.readerOverlayLayout,
           !settings.saveReaderOverlayLayout(overlayLayout) {
            return false
        }
        customLayoutEnabled = true
        if let fontSize = preset.fontSize {
            self.fontSize = fontSize
        }
        if let isBold = preset.isBold {
            readerConfig.readerFontBold = isBold
        }
        if let lineHeightMultiple = preset.lineHeightMultiple {
            readerConfig.lineHeightMultiple = lineHeightMultiple
        }
        if let letterSpacing = preset.letterSpacing {
            readerConfig.letterSpacing = letterSpacing
        }
        if let paragraphSpacingMultiplier = preset.paragraphSpacingMultiplier {
            readerConfig.paragraphSpacingMultiplier = paragraphSpacingMultiplier
        }
        if let pageMarginH = preset.pageMarginH {
            readerConfig.pageMarginH = pageMarginH
        }
        if let pageMarginV = preset.pageMarginV {
            readerConfig.pageMarginV = pageMarginV
        }
        if let titleVisible = preset.titleVisible {
            settings.readerTitleVisible = titleVisible
        }
        if let titleSize = preset.titleSize {
            settings.readerTitleSize = Double(titleSize)
        }
        if let titleTopSpacing = preset.titleTopSpacing {
            settings.readerTitleTopSpacing = Double(titleTopSpacing)
        }
        if let titleBottomSpacing = preset.titleBottomSpacing {
            settings.readerTitleBottomSpacing = Double(titleBottomSpacing)
        }
        if let scrollMode = preset.scrollMode {
            settings.scrollMode = scrollMode
        }
        if let pageTurnStyle = preset.pageTurnStyle, preset.scrollMode != true {
            settings.pageTurnStyle = pageTurnStyle
        }
        return true
    }
}

private enum LayoutMetricIconKind {
    case lineSpacing
    case characterSpacing
    case paragraphSpacing
    case pageMarginHorizontal
    case pageMarginVertical
    case pageMarginTop
    case pageMarginBottom
    case footerBottom
    case footerTextGap
    case footerHorizontal
    case headerTop
    case headerTextGap
    case headerHorizontal
    case titleSize
    case titleTopSpacing
    case titleBottomSpacing
}



private struct SettingRowHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: systemImage)
                .font(DSFont.toolbarIcon)
                .frame(width: 34, height: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textSecondary)
        }
    }
}

private struct LayoutSliderRow: View {
    let title: String
    let icon: LayoutMetricIconKind
    let valueText: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DSSpacing.sm) {
                LayoutMetricIcon(kind: icon)
                Text(title)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Spacer()
                Text(valueText)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityHidden(true)

            // A Slider has no name of its own and announces a fraction of its
            // range, so it carries the row's title and the value shown above it.
            Slider(value: $value, in: range, step: step)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

private struct LayoutMetricIcon: View {
    let kind: LayoutMetricIconKind

    var body: some View {
        icon
            .frame(width: 34, height: 24)
            .foregroundStyle(DSColor.textPrimary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .lineSpacing:
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down")
                    .font(DSFont.fixed(size: 15, weight: .bold))
                VStack(alignment: .leading, spacing: 4) {
                    iconLine(width: 22)
                    iconLine(width: 22)
                    iconLine(width: 22)
                }
            }
        case .characterSpacing:
            VStack(spacing: -2) {
                Text("甲乙丙")
                    .font(DSFont.fixed(size: 13, weight: .semibold))
                Image(systemName: "arrow.left.and.right")
                    .font(DSFont.fixed(size: 12, weight: .bold))
            }
        case .paragraphSpacing:
            VStack(alignment: .leading, spacing: 4) {
                iconLine(width: 22)
                iconLine(width: 22)
                iconLine(width: 14)
            }
        case .pageMarginHorizontal:
            pageEdgeIcon(edges: [.leading, .trailing])
        case .pageMarginVertical:
            pageEdgeIcon(edges: [.top, .bottom])
        case .pageMarginTop:
            pageEdgeIcon(edges: [.top])
        case .pageMarginBottom:
            pageEdgeIcon(edges: [.bottom])
        case .footerBottom:
            VStack(spacing: 3) {
                iconLine(width: 22)
                Image(systemName: "arrow.down.to.line")
                    .font(DSFont.fixed(size: 12, weight: .bold))
            }
        case .footerTextGap:
            VStack(spacing: 3) {
                iconLine(width: 22)
                Image(systemName: "arrow.up.and.down")
                    .font(DSFont.fixed(size: 12, weight: .bold))
                iconLine(width: 14)
            }
        case .headerTop:
            VStack(spacing: 3) {
                Image(systemName: "arrow.up.to.line")
                    .font(DSFont.fixed(size: 12, weight: .bold))
                iconLine(width: 22)
            }
        case .headerTextGap:
            VStack(spacing: 3) {
                iconLine(width: 14)
                Image(systemName: "arrow.up.and.down")
                    .font(DSFont.fixed(size: 12, weight: .bold))
                iconLine(width: 22)
            }
        case .footerHorizontal:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(lineWidth: 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 8)
                        .padding(2)
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 8)
                        .padding(2)
                }
                .frame(width: 24, height: 24)
        case .headerHorizontal:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(lineWidth: 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 8)
                        .padding(2)
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 8)
                        .padding(2)
                }
                .frame(width: 24, height: 24)
        case .titleSize:
            Image(systemName: "textformat.size")
                .font(DSFont.fixed(size: 18, weight: .semibold))
        case .titleTopSpacing:
            VStack(spacing: 3) {
                Image(systemName: "arrow.up.to.line")
                    .font(DSFont.fixed(size: 12, weight: .bold))
                Text("T")
                    .font(DSFont.fixed(size: 13, weight: .semibold))
            }
        case .titleBottomSpacing:
            VStack(spacing: 3) {
                Text("T")
                    .font(DSFont.fixed(size: 13, weight: .semibold))
                Image(systemName: "arrow.down.to.line")
                    .font(DSFont.fixed(size: 12, weight: .bold))
            }
        }
    }

    private func iconLine(width: CGFloat) -> some View {
        Capsule()
            .frame(width: width, height: 2.5)
    }

    /// A page outline with the margin being edited shaded in, so the 頁面邊距 rows
    /// are told apart by which edge is highlighted.
    private func pageEdgeIcon(edges: [Edge]) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(lineWidth: 2)
            .overlay {
                ZStack {
                    ForEach(edges, id: \.self) { edge in
                        edgeBar(edge)
                    }
                }
                .padding(3)
            }
            .frame(width: 24, height: 24)
    }

    private func edgeBar(_ edge: Edge) -> some View {
        let isHorizontal = edge == .leading || edge == .trailing
        let barThickness: CGFloat = 6
        return Rectangle()
            .fill(.secondary.opacity(0.35))
            .frame(
                width: isHorizontal ? barThickness : nil,
                height: isHorizontal ? nil : barThickness
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.alignment(for: edge))
    }

    private static func alignment(for edge: Edge) -> Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

private struct StepperValueRow: View {
    let title: String
    let valueText: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(spacing: 16) {
                SettingSymbolIcon(systemName: "textformat.size")
                Text(title)
                    .font(DSFont.body)
                Spacer()
                Text(valueText)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.regular)
    }
}

private struct SettingSymbolIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(DSFont.fixed(size: 22, weight: .regular))
            .frame(width: 34, height: 28)
            .foregroundStyle(DSColor.textPrimary)
            .accessibilityHidden(true)
    }
}

private struct ValueSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                Text(title)
                    .font(DSFont.body)
                Spacer()
                Text(valueText)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityHidden(true)

            Slider(value: $value, in: range, step: step)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.45 : 1)
                .controlSize(.regular)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

private struct SegmentedPickerRow<Item: Hashable>: View {
    let title: String
    @Binding var selection: Item
    let items: [Item]
    let titleProvider: (Item) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRowHeader(title: title, systemImage: "rectangle.portrait.on.rectangle.portrait")

            Picker(title, selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(titleProvider(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DSFont.body)
                Text(subtitle)
                    .font(DSFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FontImportError: Identifiable {
    let id = UUID()
    let message: String
}

private struct LayoutImportAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

#Preview {
    ReaderSettingsView(
        fontSize: .constant(18),
        theme: .constant(.sepia),
        capabilities: .reflowableText,
        allowsUserSelectedReaderFont: true,
        onOpenFontImporter: {}
    )
}
