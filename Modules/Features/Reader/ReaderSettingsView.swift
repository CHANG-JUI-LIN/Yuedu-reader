import YueduCoreText
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderSettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var theme: ReaderTheme
    var readerSafeTop: CGFloat = 0
    var readerSafeBottom: CGFloat = 0
    var capabilities: ReaderCapabilities = .reflowableText
    var allowsUserSelectedReaderFont = false
    var usesPublicationFontDefault = false
    var isVerticalWritingMode = false
    /// TXT and online books, which carry no writing mode of their own: 排版方向 shows.
    var allowsVerticalWritingMode = false
    var hasParagraphReviews = false
    var onOpenFontImporter: () -> Void
    var onOpenTouchZoneEditor: (() -> Void)?
    /// Hands a style/layout import to the reader's first-level presenter. Nil in
    /// contexts that already are one; see `ReaderSettingsPresentationPolicy`.
    var onOpenStyleImporter: ((ReaderStyleImportRoute) -> Void)?
    /// iOS 17: hands the paywall to the reader's first-level presenter, as the importers
    /// above do — a sheet asked for from inside this sheet can be dropped there. Nil where
    /// this view presents it itself.
    var onOpenPaywall: ((PremiumFeature) -> Void)?

    @StateObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingFontImporter = false
    @State private var paywallFeature: PremiumFeature?
    @State private var fontImportError: FontImportError?
    @State private var layoutImportAlert: LayoutImportAlert?
    @State private var showingOverlayResetConfirmation = false
    @State private var showingLayoutResetConfirmation = false
    /// Set only on iOS 18+, where this sheet can own the picker itself.
    @State private var styleImportRoute: ReaderStyleImportRoute?
    /// 匯出閱讀設定's name prompt, and the name typed into it.
    @State private var showingReaderSettingsExport = false
    @State private var readerSettingsExportName = ""

    private var supportsFontSize: Bool { capabilities.contains(.fontSize) }
    private var supportsUserFont: Bool { supportsFontSize && allowsUserSelectedReaderFont }
    private var supportsLineHeight: Bool { capabilities.contains(.lineHeight) }
    private var supportsSpacing: Bool { capabilities.contains(.spacing) }
    private var supportsPageDisplay: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && supportsLineHeight && !settings.scrollMode
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

                // What the text looks like, how it sits on the page, what surrounds it,
                // what decorates it, then how the reader behaves — the order a reader
                // reaches for them. 排版生效範圍 comes first because it decides where every
                // change below is kept.
                Form {
                    scopeSection

                    if supportsUserFont || supportsFontSize {
                        textSection
                    }

                    if supportsSpacing || supportsLineHeight {
                        layoutSection
                    }

                    headerFooterSection

                    // Pro sections stay in view without Pro, locked: a reader has to see a
                    // feature where it would be used to want it (2026-09-27).
                    readerDecorationSection

                    if showsPagingSection {
                        pagingSection
                    }

                    brightnessSection

                    readerSettingsBackupSection
                }
                .softScrollEdges()
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
                    Button { dismiss() } label: {
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
        .sheet(item: $paywallFeature) { feature in
            PaywallView(highlightedFeature: feature)
                .environmentObject(subscriptionStore)
        }
        .readerStyleImportPresentation(route: $styleImportRoute) { _ in }
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
            Text(localized("這會恢復預設的欄位配置與樣式。"))
        }
        .alert(
            localized("重設排版？"),
            isPresented: $showingLayoutResetConfirmation
        ) {
            Button(localized("重設"), role: .destructive) {
                resetLayout()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("行距、字距、段距與頁面邊距會回到預設值。"))
        }
        .onAppear {
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

    /// Paged-only gestures: scroll mode has no page turns and no tap zones.
    private var showsPagingSection: Bool {
        !settings.scrollMode
    }

    // MARK: - 排版生效範圍

    /// Where every change below is kept. Named here rather than only on its own page,
    /// because it is what makes a change made under one theme vanish under another.
    private var scopeSection: some View {
        let themeItems = settings.readingSettingsScope.themeItems
        return Section {
            NavigationLink {
                ReadingSettingsScopeView()
            } label: {
                SettingsValueLabel(
                    title: localized("排版生效範圍"),
                    systemImage: "paintpalette",
                    value: scopeSummary(themeItems)
                )
            }
        } footer: {
            if !themeItems.isEmpty {
                Text(String(
                    format: localized("跟隨主題的設定，改動會存進目前的主題「%@」。"),
                    settings.readingSettingsThemeName
                ))
                .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private func scopeSummary(_ themeItems: Set<ReadingSettingsScopeItem>) -> String {
        if themeItems.isEmpty { return localized("全部跟隨全域") }
        if themeItems.count == ReadingSettingsScopeItem.allCases.count { return localized("全部跟隨主題") }
        return String(format: localized("%d 項跟隨主題"), themeItems.count)
    }

    // MARK: - 文字

    private var textSection: some View {
        Section {
            if supportsUserFont {
                fontSelector
            }

            if supportsFontSize {
                Stepper(value: fontSizeBinding, in: GlobalSettings.readerFontSizeRange, step: 1) {
                    LabeledContent {
                        Text(String(format: localized("ReaderOverlay.Format.Points"), Int(fontSize)))
                            .monospacedDigit()
                            .foregroundStyle(DSColor.textSecondary)
                    } label: {
                        SettingsRowLabel(
                            localized(ReadingSettingsScopeItem.fontSize.titleKey),
                            systemImage: ReadingSettingsScopeItem.fontSize.systemImage
                        )
                    }
                }
            }

            Toggle(isOn: $readerConfig.readerFontBold) {
                SettingsRowLabel(
                    localized(ReadingSettingsScopeItem.bold.titleKey),
                    systemImage: ReadingSettingsScopeItem.bold.systemImage
                )
            }

            ColorPicker(selection: readerTextColorBinding, supportsOpacity: false) {
                SettingsRowLabel(
                    localized(ReadingSettingsScopeItem.textColor.titleKey),
                    systemImage: ReadingSettingsScopeItem.textColor.systemImage
                )
            }

            if hasReaderTextColorOverride {
                Button {
                    setReaderTextColor(nil)
                } label: {
                    SettingsRowLabel(localized("跟隨主題文字顏色"), systemImage: "arrow.counterclockwise", role: .action)
                }
            }

            if supportsFontSize {
                Picker(selection: $settings.textConversion) {
                    ForEach(TextConversion.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                } label: {
                    SettingsRowLabel(localized("繁簡轉換"), systemImage: "character.book.closed")
                }
            }
        } header: {
            Text(localized("文字"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(String(
                format: localized("文字顏色只套用到目前的閱讀背景（%@）。"),
                wornSavedBackground?.name ?? theme.localizedTitle
            ))
            .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// The saved background on the page, if one is: its text colour is its own, not the
    /// one set for the built-in background under it.
    private var wornSavedBackground: ReaderCustomBackground? {
        theme.activeReaderBackgroundID.flatMap(settings.readerCustomBackground(id:))
    }

    private var hasReaderTextColorOverride: Bool {
        if let background = wornSavedBackground { return background.textColorHex != nil }
        return settings.readerTextColorOverride(for: theme) != nil
    }

    /// Nil goes back to the colour the background picks for itself.
    private func setReaderTextColor(_ rgbHex: UInt32?) {
        if let background = wornSavedBackground {
            settings.setReaderCustomBackgroundTextColor(rgbHex, id: background.id)
        } else {
            settings.setReaderTextColorOverride(rgbHex, for: theme)
        }
    }

    /// Reads the color the reader is actually painting with, so opening the picker
    /// starts from what is on screen rather than from a blank swatch. Writing one
    /// stores it for the *current* reading background only.
    private var readerTextColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: theme.uiTextColor) },
            set: { newColor in
                guard let rgbHex = UIColor(newColor).rgbHex else { return }
                setReaderTextColor(rgbHex)
            }
        )
    }

    private var fontSelector: some View {
        HStack(spacing: DSSpacing.sm) {
            Menu {
                Button {
                    settings.selectedReaderFontPostScript = nil
                } label: {
                    Label(defaultFontName, systemImage: settings.selectedReaderFontPostScript == nil ? "checkmark" : "f.cursive")
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
                                    systemImage: settings.selectedReaderFontPostScript == font.postScriptName ? "checkmark" : "f.cursive"
                                )
                            }
                        }
                    } header: {
                        Text(localized("已匯入字體"))
                            .foregroundStyle(DSColor.textSecondary)
                    }

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

                if !ReaderSettingsPresentationPolicy.requiresFirstLevelImporter {
                    Divider()
                    if premiumVisibility.allowsFontImport {
                        Button {
                            showingFontImporter = true
                        } label: {
                            Label(localized("匯入字體..."), systemImage: "plus")
                        }
                    } else {
                        // Locked: the second `Text` is the menu row's subtitle.
                        Button {
                            requestPaywall(.customFonts)
                        } label: {
                            Text(localized("匯入字體..."))
                            Text(localized("需要 Pro"))
                            Image(systemName: "lock.fill")
                        }
                    }
                }
            } label: {
                LabeledContent {
                    HStack(spacing: DSSpacing.xs) {
                        Text(currentFontName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(DSFont.footnote)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(DSColor.textSecondary)
                } label: {
                    SettingsRowLabel(
                        localized(ReadingSettingsScopeItem.font.titleKey),
                        systemImage: ReadingSettingsScopeItem.font.systemImage
                    )
                }
            }
            .buttonStyle(.plain)

            if ReaderSettingsPresentationPolicy.requiresFirstLevelImporter {
                let locked = !premiumVisibility.allowsFontImport
                Button {
                    if locked {
                        requestPaywall(.customFonts)
                    } else {
                        onOpenFontImporter()
                    }
                } label: {
                    Image(systemName: locked ? "lock.fill" : "plus")
                }
                .accessibilityLabel(localized("匯入字體..."))
                .accessibilityValue(locked ? localized("需要 Pro") : "")
            }
        }
    }

    // MARK: - 排版

    /// Spacing and the three body margins, together: they are all "how the text sits on
    /// the page", and they used to be two sections with two different ways to reset.
    ///
    /// 上下邊距 means the same thing in both modes. It used to not: paged mode took its
    /// vertical margin from the header/footer layout's hand-tuned "content reservation"
    /// while scroll mode used `pageMarginV`. The bars' heights are known now, so the
    /// margin no longer has to absorb them.
    private var layoutSection: some View {
        Section {
            if allowsVerticalWritingMode {
                Picker(selection: $settings.readerWritingMode) {
                    Text(localized("橫排")).tag(ReaderWritingMode.horizontal)
                    Text(localized("直排")).tag(ReaderWritingMode.verticalRTL)
                } label: {
                    SettingsRowLabel(localized(ReadingSettingsScopeItem.writingMode.titleKey),
                                     systemImage: ReadingSettingsScopeItem.writingMode.systemImage)
                }
            }

            if supportsSpacing {
                SettingsSliderRow(
                    title: localized(ReadingSettingsScopeItem.lineSpacing.titleKey),
                    systemImage: ReadingSettingsScopeItem.lineSpacing.systemImage,
                    valueText: String(format: "%.2f", readerConfig.lineHeightMultiple),
                    value: $readerConfig.lineHeightMultiple,
                    range: 1.0...2.4,
                    step: 0.05
                )
                SettingsSliderRow(
                    title: localized(ReadingSettingsScopeItem.letterSpacing.titleKey),
                    systemImage: ReadingSettingsScopeItem.letterSpacing.systemImage,
                    valueText: "\(String(format: "%.1f", readerConfig.letterSpacing)) pt",
                    value: $readerConfig.letterSpacing,
                    range: 0...12,
                    step: 0.5
                )
                SettingsSliderRow(
                    title: localized(ReadingSettingsScopeItem.paragraphSpacing.titleKey),
                    systemImage: ReadingSettingsScopeItem.paragraphSpacing.systemImage,
                    valueText: String(format: "%.2f", readerConfig.paragraphSpacingMultiplier),
                    value: $readerConfig.paragraphSpacingMultiplier,
                    range: 0.3...1.2,
                    step: 0.05
                )
            }

            if supportsLineHeight {
                SettingsSliderRow(
                    title: localized("左右邊距"),
                    systemImage: ReadingSettingsScopeItem.pageMargins.systemImage,
                    valueText: String(format: localized("ReaderOverlay.Format.Points"), Int(readerConfig.pageMarginH)),
                    value: $readerConfig.pageMarginH,
                    range: 0...50,
                    step: 1
                )
                SettingsSliderRow(
                    title: localized("上邊距"),
                    systemImage: "arrow.up.to.line",
                    valueText: String(format: localized("ReaderOverlay.Format.Points"), Int(readerConfig.pageMarginTop)),
                    value: $readerConfig.pageMarginTop,
                    range: 0...50,
                    step: 1
                )
                SettingsSliderRow(
                    title: localized("下邊距"),
                    systemImage: "arrow.down.to.line",
                    valueText: String(format: localized("ReaderOverlay.Format.Points"), Int(readerConfig.pageMarginBottom)),
                    value: $readerConfig.pageMarginBottom,
                    range: 0...50,
                    step: 1
                )
            }

            Button(role: .destructive) {
                showingLayoutResetConfirmation = true
            } label: {
                SettingsRowLabel(localized("重設排版"), systemImage: "arrow.counterclockwise", role: .destructive)
            }
            .disabled(!hasCustomLayout)
        } header: {
            Text(localized("排版"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            if supportsLineHeight, !settings.scrollMode {
                Text(localized("上下邊距同時是頁首頁尾的容身空間，改動不會移動頁首頁尾本身。"))
                    .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private var hasCustomLayout: Bool {
        let spacing = supportsSpacing && (
            abs(readerConfig.lineHeightMultiple - defaultLineHeightMultiple) > 0.001
                || abs(readerConfig.letterSpacing - defaultLetterSpacing) > 0.001
                || abs(readerConfig.paragraphSpacingMultiplier - defaultParagraphSpacingMultiplier) > 0.001
        )
        let margins = supportsLineHeight && (
            abs(readerConfig.pageMarginH - defaultPageMarginH) > 0.001
                || abs(readerConfig.pageMarginTop - defaultPageMarginV) > 0.001
                || abs(readerConfig.pageMarginBottom - defaultPageMarginV) > 0.001
        )
        return spacing || margins
    }

    /// The bars' own space is computed from their height, so there is no separate
    /// reservation left to reset here — only what this section shows.
    private func resetLayout() {
        if supportsSpacing {
            readerConfig.lineHeightMultiple = defaultLineHeightMultiple
            readerConfig.letterSpacing = defaultLetterSpacing
            readerConfig.paragraphSpacingMultiplier = defaultParagraphSpacingMultiplier
        }
        if supportsLineHeight {
            readerConfig.pageMarginH = defaultPageMarginH
            readerConfig.pageMarginV = defaultPageMarginV
            readerConfig.pageMarginTop = defaultPageMarginV
            readerConfig.pageMarginBottom = defaultPageMarginV
        }
    }

    // MARK: - 頁首頁尾與標題

    /// Pushed pages, not sheets handed back to the reader to present. This sheet is
    /// already inside a `NavigationStack`, so pushing keeps the whole flow at one
    /// presentation level — the iOS 17 sheet-from-sheet trap never arises.
    private var headerFooterSection: some View {
        Section {
            NavigationLink {
                ReaderBarLayoutEditorView(
                    theme: theme,
                    readerSafeTop: readerSafeTop,
                    readerSafeBottom: readerSafeBottom
                )
            } label: {
                SettingsRowLabel(
                    localized("頁首頁尾編輯"),
                    systemImage: ReadingSettingsScopeItem.headerFooter.systemImage
                )
            }

            if supportsLineHeight {
                NavigationLink {
                    ChapterTitleStyleSettingsView(
                        onOpenImporter: { requestStyleImporter(.chapterTitleStyle) }
                    )
                } label: {
                    SettingsRowLabel(
                        localized(ReadingSettingsScopeItem.chapterTitle.titleKey),
                        systemImage: ReadingSettingsScopeItem.chapterTitle.systemImage
                    )
                }
            }

            Button(role: .destructive) {
                showingOverlayResetConfirmation = true
            } label: {
                SettingsRowLabel(localized("重設頁首頁尾"), systemImage: "arrow.counterclockwise", role: .destructive)
            }
        } header: {
            Text(localized("頁首頁尾與標題"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("正文與頁首頁尾的距離在「排版」的上下邊距調整。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// Writes the archive under `name` — 閱讀設定 when left blank — and hands it to the
    /// share sheet. The values are read now, on the main actor; the zip is made off it.
    private func exportReaderSettings(named name: String) {
        let inputs = ReaderSettingsExportSnapshot.make()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                let url = try await ReaderSettingsExportFile.write(
                    inputs,
                    named: trimmed.isEmpty ? localized("閱讀設定") : trimmed
                )
                SystemShareSheet.present(fileURL: url)
            } catch {
                AppLogger.error("⟐ reading settings export failed", error: error)
                layoutImportAlert = LayoutImportAlert(
                    titleKey: "匯出失敗",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func resetReaderOverlayLayout() {
        guard settings.saveReaderBarLayout(.default) else {
            layoutImportAlert = LayoutImportAlert(
                titleKey: "無法儲存頁首頁尾設定",
                message: localized("請稍後再試。")
            )
            return
        }
    }

    // MARK: - 閱讀裝飾

    private var readerDecorationSection: some View {
        Section {
            if premiumVisibility.showsReaderDecoration {
                if showsCommentBubbleSettings {
                    NavigationLink {
                        ReaderCommentBubbleSettingsView()
                    } label: {
                        SettingsRowLabel(
                            localized("氣泡設定"),
                            systemImage: ReadingSettingsScopeItem.commentBubble.systemImage
                        )
                    }
                }

                NavigationLink {
                    ReaderDialogueBubbleSettingsView(
                        style: settings.dialogueBubbleStyle,
                        onOpenImporter: { requestStyleImporter(.dialogueBubble) },
                        onChange: { settings.dialogueBubbleStyle = $0 }
                    )
                } label: {
                    SettingsValueLabel(
                        title: localized(ReadingSettingsScopeItem.dialogueBubble.titleKey),
                        systemImage: ReadingSettingsScopeItem.dialogueBubble.systemImage,
                        value: onOffText(settings.dialogueBubbleStyle.isEnabled)
                    )
                }

                NavigationLink {
                    RegexHighlightSettingsView(
                        configuration: settings.regexHighlightConfiguration,
                        onOpenImporter: { requestStyleImporter(.regexHighlights) },
                        onChange: { settings.regexHighlightConfiguration = $0 }
                    )
                } label: {
                    SettingsValueLabel(
                        title: localized(ReadingSettingsScopeItem.regexHighlight.titleKey),
                        systemImage: ReadingSettingsScopeItem.regexHighlight.systemImage,
                        value: onOffText(settings.regexHighlightConfiguration.isEnabled)
                    )
                }

                NavigationLink {
                    ReaderTextUnderlineSettingsView()
                } label: {
                    SettingsValueLabel(
                        title: localized(ReadingSettingsScopeItem.textUnderline.titleKey),
                        systemImage: ReadingSettingsScopeItem.textUnderline.systemImage,
                        value: onOffText(settings.readerTextUnderlineDecorationEnabled)
                    )
                }
            } else {
                ForEach(lockedDecorationItems) { item in
                    SettingsLockedRow(
                        title: localized(item == .commentBubble ? "氣泡設定" : item.titleKey),
                        systemImage: item.systemImage
                    ) {
                        requestPaywall(.dialogueHighlight)
                    }
                }
            }
        } header: {
            Text(localized("閱讀裝飾"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    /// The same rows, in the same order, as with Pro.
    private var lockedDecorationItems: [ReadingSettingsScopeItem] {
        (hasParagraphReviews ? [.commentBubble] : []) + [.dialogueBubble, .regexHighlight, .textUnderline]
    }

    private func onOffText(_ isOn: Bool) -> String {
        localized(isOn ? "已開啟" : "已關閉")
    }

    // MARK: - 翻頁與手勢

    private var pagingSection: some View {
        Section {
            if supportsPageDisplay {
                Picker(selection: $settings.readerSpreadMode) {
                    ForEach(ReaderSpreadMode.settingsCases, id: \.self) { mode in
                        Text(localized(spreadTitleKey(for: mode))).tag(mode)
                    }
                } label: {
                    SettingsRowLabel(localized("頁面顯示"), systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
            }

            Toggle(isOn: $settings.readerTapBothSidesNextPage) {
                SettingsRowLabel(localized("全局翻頁"), systemImage: "hand.tap")
            }

            Toggle(isOn: $settings.readerSwipeUpToExit) {
                SettingsRowLabel(localized("上滑退出閱讀"), systemImage: "rectangle.portrait.and.arrow.right")
            }

            Toggle(isOn: $settings.readerPullDownToBookmark) {
                SettingsRowLabel(localized("下拉加入書籤"), systemImage: "bookmark")
            }

            if let onOpenTouchZoneEditor {
                if premiumVisibility.showsTouchZoneEditor {
                    Button {
                        dismiss()
                        DispatchQueue.main.async { onOpenTouchZoneEditor() }
                    } label: {
                        SettingsRowLabel(localized("翻頁區塊編輯"), systemImage: "square.grid.3x3", role: .action)
                    }
                } else {
                    SettingsLockedRow(title: localized("翻頁區塊編輯"), systemImage: "square.grid.3x3") {
                        requestPaywall(.touchZoneEditor)
                    }
                }
            }
        } header: {
            Text(localized("翻頁與手勢"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("全局翻頁：點畫面左右兩側都翻到下一頁，中間仍呼出選單。上滑退出與下拉書籤都要滑過一半再鬆手。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func spreadTitleKey(for mode: ReaderSpreadMode) -> String {
        switch mode {
        case .singlePage: return "單頁"
        case .doublePage: return "雙頁"
        case .auto: return "單頁"
        }
    }

    // MARK: - 亮度

    private var brightnessSection: some View {
        Section {
            Toggle(isOn: followSystemBrightnessBinding) {
                SettingsRowLabel(localized("跟隨系統亮度"), systemImage: "sun.max")
            }

            SettingsSliderRow(
                title: localized("閱讀亮度"),
                systemImage: "sun.min",
                valueText: "\(Int(settings.readerBrightness * 100))%",
                value: readerBrightnessBinding,
                range: 0.05...1.0,
                step: 0.05,
                isEnabled: !settings.followSystemBrightness
            )
        } header: {
            Text(localized("亮度"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
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

    private func syncBrightnessFromSystem() {
        settings.readerBrightness = Double(UIScreen.main.brightness)
    }

    // MARK: - 閱讀設定備份

    /// 匯出/匯入 the whole of 閱讀設定 in one file: layout parameters, the chapter
    /// title style, and the regex highlight rules. Each of those two styles keeps
    /// its own single-purpose export on its own page; this is the "move my whole
    /// reading setup to the new phone" file.
    private var readerSettingsBackupSection: some View {
        Section {
            if premiumVisibility.showsLayoutPresetImport {
                Button {
                    readerSettingsExportName = localized("閱讀設定")
                    showingReaderSettingsExport = true
                } label: {
                    SettingsRowLabel(localized("匯出閱讀設定"), systemImage: "square.and.arrow.up", role: .action)
                }
                // The file is named first, then shared: the file name is all that
                // tells one exported setup from another.
                .alert(localized("匯出閱讀設定"), isPresented: $showingReaderSettingsExport) {
                    TextField(localized("名稱"), text: $readerSettingsExportName)
                    Button(localized("匯出")) {
                        exportReaderSettings(named: readerSettingsExportName)
                    }
                    Button(localized("取消"), role: .cancel) {}
                }

                Button {
                    requestStyleImporter(.readerSettings)
                } label: {
                    SettingsRowLabel(localized("匯入閱讀設定"), systemImage: "square.and.arrow.down", role: .action)
                }
            } else {
                SettingsLockedRow(title: localized("匯出閱讀設定"), systemImage: "square.and.arrow.up") {
                    requestPaywall(.layoutPresetImport)
                }
                SettingsLockedRow(title: localized("匯入閱讀設定"), systemImage: "square.and.arrow.down") {
                    requestPaywall(.layoutPresetImport)
                }
            }
        } header: {
            Text(localized("閱讀設定備份"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("包含排版、章節標題樣式與正則高亮。匯入也接受 legado 的 readConfig.json。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    // MARK: - Presenting

    /// A locked control's paywall: from this sheet on iOS 18, from the reader on iOS 17
    /// (`onOpenPaywall`), where a sheet asked for from inside this one can be dropped.
    private func requestPaywall(_ feature: PremiumFeature) {
        if let onOpenPaywall {
            onOpenPaywall(feature)
        } else {
            paywallFeature = feature
        }
    }

    /// iOS 17 cannot present a document picker from this sheet — hand it to the
    /// reader's first-level presenter instead. See
    /// `Technotes/iOS17MenuModalPresentation.md`.
    private func requestStyleImporter(_ route: ReaderStyleImportRoute) {
        guard ReaderSettingsPresentationPolicy.requiresFirstLevelImporter,
              let onOpenStyleImporter else {
            styleImportRoute = route
            return
        }
        // The caller dismisses this sheet and presents from its real `onDismiss`
        // — an event boundary, never a timed delay.
        onOpenStyleImporter(route)
    }

    // MARK: - Preview

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

    // MARK: - Fonts

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { fontSize },
            set: { fontSize = GlobalSettings.clampedReaderFontSize($0) }
        )
    }

    private var defaultFontName: String {
        localized(usesPublicationFontDefault ? "書籍預設字體" : "系統字體")
    }

    private var currentFontName: String {
        guard let selected = settings.selectedReaderFontPostScript else { return defaultFontName }
        return settings.userFonts.first { $0.postScriptName == selected }?.displayName ?? selected
    }

    static let fontContentTypes: [UTType] = [
        .font,
        UTType(filenameExtension: "ttf") ?? .data,
        UTType(filenameExtension: "otf") ?? .data,
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
        allowsVerticalWritingMode: true,
        onOpenFontImporter: {}
    )
}
