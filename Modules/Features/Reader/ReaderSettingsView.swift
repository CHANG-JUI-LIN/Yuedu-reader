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
    private let defaultFooterBottomPadding = ReaderLayoutMetrics.defaultFooterBottomPadding
    private let defaultFooterTextGap = ReaderLayoutMetrics.defaultFooterTextGap
    private let defaultHeaderTopPadding = ReaderLayoutMetrics.defaultHeaderTopPadding
    private let defaultHeaderTextGap = ReaderLayoutMetrics.defaultHeaderTextGap
    private let defaultReaderTitleSize: CGFloat = 28
    private let defaultReaderTitleTopSpacing: CGFloat = 10
    private let defaultReaderTitleBottomSpacing: CGFloat = 20

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewPanel
                Divider()

                Form {
                    if supportsUserFont || supportsFontSize {
                        textStyleSection
                    }

                    if supportsSpacing || supportsLineHeight {
                        layoutDetailsSection
                    }

                    if supportsPageDisplay {
                        pageDisplaySection
                    }

                    if premiumVisibility.showsReaderDecoration {
                        readerDecorationSection
                    }
                    displaySection
                }
            }
            .background(pageBackground.ignoresSafeArea())
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

    private var pageDisplaySection: some View {
        Section {
            SegmentedPickerRow(
                title: localized("頁面顯示"),
                selection: $settings.readerSpreadMode,
                items: ReaderSpreadMode.settingsCases,
                titleProvider: { mode in
                    localized(spreadTitleKey(for: mode))
                }
            )
        }
    }

    private func spreadTitleKey(for mode: ReaderSpreadMode) -> String {
        switch mode {
        case .singlePage: return "單頁"
        case .doublePage: return "雙頁"
        case .auto: return "單頁"
        }
    }

    private var textStyleSection: some View {
        Section(header: Text(localized("文字"))) {
            if supportsUserFont {
                fontSelector
            }

            if supportsFontSize {
                StepperValueRow(
                    title: localized("字體大小"),
                    valueText: "\(Int(fontSize)) pt",
                    value: fontSizeBinding,
                    range: 12...32,
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
        }
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
        Menu {
            Button {
                settings.selectedReaderFontPostScript = nil
                readerConfig.refresh.send(.layout)
            } label: {
                Label(localized("系統字體"), systemImage: settings.selectedReaderFontPostScript == nil ? "checkmark" : "textformat")
            }

            if !settings.userFonts.isEmpty {
                Divider()
                Section {
                    ForEach(settings.userFonts, id: \.id) { font in
                        Button {
                            settings.selectedReaderFontPostScript = font.postScriptName
                            readerConfig.refresh.send(.layout)
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

                Menu(localized("刪除字體")) {
                    ForEach(settings.userFonts, id: \.id) { font in
                        Button(role: .destructive) {
                            settings.deleteUserFont(font)
                            readerConfig.refresh.send(.layout)
                        } label: {
                            Label(font.displayName, systemImage: "trash")
                        }
                    }
                }
            }

            Divider()
            Button {
                showingFontImporter = true
            } label: {
                Label(localized("匯入字體..."), systemImage: "plus")
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
    }

    private var layoutDetailsSection: some View {
        Section(header: Text(localized("輔助使用與佈局選項"))) {
            if premiumVisibility.showsLayoutPresetImport {
                Button {
                    showingLayoutImporter = true
                } label: {
                    Label(localized("匯入排版參數"), systemImage: "square.and.arrow.down")
                }
            }

            if !settings.scrollMode {
                if premiumVisibility.showsTouchZoneEditor,
                   let onOpenTouchZoneEditor {
                    Button {
                        dismiss()
                        DispatchQueue.main.async { onOpenTouchZoneEditor() }
                    } label: {
                        Label(localized("翻頁區塊編輯"), systemImage: "hand.tap")
                    }
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
            }

            Toggle(localized("自訂"), isOn: customLayoutBinding)
                .font(DSFont.body)

            if customLayoutEnabled {
                if supportsSpacing {
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

                if supportsLineHeight {
                    LayoutSliderRow(
                        title: localized("頁面留白"),
                        icon: .pageMargin,
                        valueText: "\(Int(readerConfig.pageMarginH))",
                        value: $readerConfig.pageMarginH,
                        range: 8...48,
                        step: 2
                    )

                    LayoutSliderRow(
                        title: localized("底欄離底"),
                        icon: .footerBottom,
                        valueText: "\(Int(readerConfig.footerBottomPadding)) pt",
                        value: $readerConfig.footerBottomPadding,
                        range: 0...36,
                        step: 1
                    )

                    LayoutSliderRow(
                        title: localized("正文到底欄"),
                        icon: .footerTextGap,
                        valueText: "\(Int(readerConfig.footerTextGap)) pt",
                        value: $readerConfig.footerTextGap,
                        range: 0...48,
                        step: 1
                    )

                    if !settings.scrollMode {
                        Toggle(localized("顯示頁眉"), isOn: $readerConfig.readerHeaderVisible)
                            .font(DSFont.body)

                        if readerConfig.readerHeaderVisible {
                            ForEach(ReaderHeaderField.allCases) { field in
                                Picker(selection: headerFieldPositionBinding(for: field)) {
                                    ForEach(ReaderHeaderFieldPosition.allCases) { position in
                                        Text(position.displayName).tag(position)
                                    }
                                } label: {
                                    Text(field.displayName)
                                        .font(DSFont.body)
                                        .foregroundStyle(DSColor.textSecondary)
                                }
                            }

                            LayoutSliderRow(
                                title: localized("頂欄離頂"),
                                icon: .headerTop,
                                valueText: "\(Int(readerConfig.readerHeaderTopPadding)) pt",
                                value: $readerConfig.readerHeaderTopPadding,
                                range: 0...36,
                                step: 1
                            )

                            LayoutSliderRow(
                                title: localized("正文到頂欄"),
                                icon: .headerTextGap,
                                valueText: "\(Int(readerConfig.readerHeaderTextGap)) pt",
                                value: $readerConfig.readerHeaderTextGap,
                                range: 0...48,
                                step: 1
                            )
                        }
                    }

                    Toggle(localized("顯示標題"), isOn: $readerConfig.readerTitleVisible)
                        .font(DSFont.body)

                    LayoutSliderRow(
                        title: localized("標題大小"),
                        icon: .titleSize,
                        valueText: "\(Int(readerConfig.readerTitleSize)) pt",
                        value: $readerConfig.readerTitleSize,
                        range: 14...40,
                        step: 1,
                        isEnabled: readerConfig.readerTitleVisible
                    )

                    LayoutSliderRow(
                        title: localized("標題上距"),
                        icon: .titleTopSpacing,
                        valueText: "\(Int(readerConfig.readerTitleTopSpacing)) pt",
                        value: $readerConfig.readerTitleTopSpacing,
                        range: 0...100,
                        step: 1,
                        isEnabled: readerConfig.readerTitleVisible
                    )

                    LayoutSliderRow(
                        title: localized("標題下距"),
                        icon: .titleBottomSpacing,
                        valueText: "\(Int(readerConfig.readerTitleBottomSpacing)) pt",
                        value: $readerConfig.readerTitleBottomSpacing,
                        range: 0...100,
                        step: 1,
                        isEnabled: readerConfig.readerTitleVisible
                    )
                }
            }
        }
    }

    private var readerDecorationSection: some View {
        Section(header: Text(localized("閱讀裝飾"))) {
            NavigationLink {
                ReaderCommentBubbleSettingsView()
            } label: {
                Label(localized("氣泡設定"), systemImage: "text.bubble")
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
            }

            Toggle(isOn: dialogueHighlightBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("對話文字高亮"))
                        .font(DSFont.body)
                    Text(localized("使用自訂顏色標示引號內的對話文字。"))
                        .font(DSFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.readerDialogueHighlightEnabled {
                ColorPicker(
                    localized("高亮顏色"),
                    selection: readerDialogueHighlightColorBinding,
                    supportsOpacity: false
                )
            }
        }
    }

    private var displaySection: some View {
        Section(header: Text(localized("亮度與顯示"))) {
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
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { fontSize },
            set: { fontSize = min(32, max(12, $0)) }
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

    private var hasCustomLayoutOverrides: Bool {
        abs(readerConfig.lineHeightMultiple - defaultLineHeightMultiple) > 0.001 ||
            abs(readerConfig.letterSpacing - defaultLetterSpacing) > 0.001 ||
            abs(readerConfig.paragraphSpacingMultiplier - defaultParagraphSpacingMultiplier) > 0.001 ||
            abs(readerConfig.pageMarginH - defaultPageMarginH) > 0.001 ||
            abs(readerConfig.pageMarginV - defaultPageMarginV) > 0.001 ||
            abs(readerConfig.footerBottomPadding - defaultFooterBottomPadding) > 0.001 ||
            abs(readerConfig.footerTextGap - defaultFooterTextGap) > 0.001 ||
            readerConfig.readerHeaderVisible != true ||
            abs(readerConfig.readerHeaderTopPadding - defaultHeaderTopPadding) > 0.001 ||
            abs(readerConfig.readerHeaderTextGap - defaultHeaderTextGap) > 0.001 ||
            settings.readerHeaderFieldPositions != ReaderHeaderLayout.defaultFieldPositions ||
            readerConfig.readerTitleVisible != true ||
            abs(readerConfig.readerTitleSize - defaultReaderTitleSize) > 0.001 ||
            abs(readerConfig.readerTitleTopSpacing - defaultReaderTitleTopSpacing) > 0.001 ||
            abs(readerConfig.readerTitleBottomSpacing - defaultReaderTitleBottomSpacing) > 0.001
    }

    private func resetLayoutDefaults() {
        readerConfig.lineHeightMultiple = defaultLineHeightMultiple
        readerConfig.letterSpacing = defaultLetterSpacing
        readerConfig.paragraphSpacingMultiplier = defaultParagraphSpacingMultiplier
        readerConfig.pageMarginH = defaultPageMarginH
        readerConfig.pageMarginV = defaultPageMarginV
        readerConfig.footerBottomPadding = defaultFooterBottomPadding
        readerConfig.footerTextGap = defaultFooterTextGap
        readerConfig.readerHeaderVisible = true
        readerConfig.readerHeaderTopPadding = defaultHeaderTopPadding
        readerConfig.readerHeaderTextGap = defaultHeaderTextGap
        settings.readerHeaderFieldPositions = ReaderHeaderLayout.defaultFieldPositions
        readerConfig.readerTitleVisible = true
        readerConfig.readerTitleSize = defaultReaderTitleSize
        readerConfig.readerTitleTopSpacing = defaultReaderTitleTopSpacing
        readerConfig.readerTitleBottomSpacing = defaultReaderTitleBottomSpacing
    }

    private func headerFieldPositionBinding(for field: ReaderHeaderField) -> Binding<ReaderHeaderFieldPosition> {
        Binding(
            get: {
                let raw = settings.readerHeaderFieldPositions[field.rawValue] ?? ""
                return ReaderHeaderFieldPosition(rawValue: raw) ?? .hidden
            },
            set: { settings.readerHeaderFieldPositions[field.rawValue] = $0.rawValue }
        )
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

    private var readerBrightnessBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(settings.readerBrightness) },
            set: { value in
                settings.readerBrightness = Double(value)
                if !settings.followSystemBrightness {
                    UIScreen.main.brightness = value
                }
            }
        )
    }

    private var readerTextUnderlineDecorationBinding: Binding<Bool> {
        Binding(
            get: { settings.readerTextUnderlineDecorationEnabled },
            set: { enabled in
                settings.readerTextUnderlineDecorationEnabled = enabled
                readerConfig.refresh.send(.layout)
            }
        )
    }

    private var dialogueHighlightBinding: Binding<Bool> {
        Binding(
            get: { settings.readerDialogueHighlightEnabled },
            set: { enabled in
                settings.readerDialogueHighlightEnabled = enabled
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

    private var readerDialogueHighlightColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(uiColor: GlobalSettings.uiColor(rgbHex: settings.readerDialogueHighlightColorHex))
            },
            set: {
                settings.readerDialogueHighlightColorHex =
                    UIColor($0).rgbHex ?? GlobalSettings.defaultReaderDialogueHighlightColorHex
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

    private static let fontContentTypes: [UTType] = [
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
            readerConfig.refresh.send(.layout)
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
                applyLayoutPreset(preset)
                let importedName = preset.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = importedName?.isEmpty == false
                    ? String(format: localized("已匯入「%@」的排版參數"), importedName!)
                    : localized("已匯入排版參數")
                layoutImportAlert = LayoutImportAlert(titleKey: "排版匯入成功", message: message)
            } catch {
                layoutImportAlert = LayoutImportAlert(
                    titleKey: "排版匯入失敗",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func applyLayoutPreset(_ preset: ReaderLayoutPreset) {
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
        if let footerBottomPadding = preset.footerBottomPadding {
            readerConfig.footerBottomPadding = footerBottomPadding
        }
        if let footerTextGap = preset.footerTextGap {
            readerConfig.footerTextGap = footerTextGap
        }
        if let titleVisible = preset.titleVisible {
            readerConfig.readerTitleVisible = titleVisible
        }
        if let titleSize = preset.titleSize {
            readerConfig.readerTitleSize = titleSize
        }
        if let titleTopSpacing = preset.titleTopSpacing {
            readerConfig.readerTitleTopSpacing = titleTopSpacing
        }
        if let titleBottomSpacing = preset.titleBottomSpacing {
            readerConfig.readerTitleBottomSpacing = titleBottomSpacing
        }
        if let scrollMode = preset.scrollMode {
            settings.scrollMode = scrollMode
        }
        if let pageTurnStyle = preset.pageTurnStyle, preset.scrollMode != true {
            settings.pageTurnStyle = pageTurnStyle
        }
        readerConfig.refresh.send(.layout)
    }
}

private enum LayoutMetricIconKind {
    case lineSpacing
    case characterSpacing
    case paragraphSpacing
    case pageMargin
    case footerBottom
    case footerTextGap
    case headerTop
    case headerTextGap
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

            Slider(value: $value, in: range, step: step)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

private struct LayoutMetricIcon: View {
    let kind: LayoutMetricIconKind

    var body: some View {
        icon
            .frame(width: 34, height: 24)
            .foregroundStyle(DSColor.textPrimary)
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
        case .pageMargin:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(lineWidth: 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 10)
                        .padding(3)
                }
                .frame(width: 24, height: 24)
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
    }
}

private struct ValueSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
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

            Slider(value: $value, in: range, step: step)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.45 : 1)
                .controlSize(.regular)
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
        allowsUserSelectedReaderFont: true
    )
}
