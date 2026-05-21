import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ReaderSettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var theme: ReaderTheme
    var capabilities: ReaderCapabilities = .reflowableText
    var allowsUserSelectedReaderFont = false
    var isVerticalWritingMode = false

    @StateObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingFontImporter = false
    @State private var fontImportError: FontImportError?
    @State private var customLayoutEnabled = true

    private var supportsFontSize: Bool { capabilities.contains(.fontSize) }
    private var supportsUserFont: Bool { supportsFontSize && allowsUserSelectedReaderFont }
    private var supportsLineHeight: Bool { capabilities.contains(.lineHeight) }
    private var supportsSpacing: Bool { capabilities.contains(.spacing) }
    private var supportsBackground: Bool {
        capabilities.contains(.background) || capabilities.contains(.darkMode)
    }

    private var pageBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var readerTint: Color {
        Color(uiColor: .systemBlue)
    }

    private let previewTextHeight: CGFloat = 220
    private let defaultLineHeightMultiple: CGFloat = 1.65
    private let defaultLetterSpacing: CGFloat = 0
    private let defaultParagraphSpacingMultiplier: CGFloat = 0.8
    private let defaultPageMarginH: CGFloat = 24
    private let defaultFooterBottomPadding = ReaderLayoutMetrics.defaultFooterBottomPadding
    private let defaultFooterTextGap = ReaderLayoutMetrics.defaultFooterTextGap

    private enum PageTurnOption: String, CaseIterable, Hashable {
        case slide
        case cover
        case curl
        case scroll
        case none

        var titleKey: String {
            switch self {
            case .slide: return "滑動"
            case .cover: return "覆蓋"
            case .curl: return "仿真"
            case .scroll: return "上下"
            case .none: return "無動畫"
            }
        }
    }

    private var availablePageTurnOptions: [PageTurnOption] {
        PageTurnOption.allCases.filter { option in
            !(isVerticalWritingMode && option == .scroll)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewPanel
                Divider()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        if supportsUserFont || supportsFontSize {
                            textStyleSection
                        }

                        if supportsSpacing || supportsLineHeight {
                            layoutDetailsSection
                        }

                        if supportsBackground || supportsLineHeight {
                            quickSettingsSection
                        }

                        displaySection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 26)
                    .padding(.bottom, 30)
                }
                .background(pageBackground)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle(localized("閱讀設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("完成")) { dismiss() }
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
        .alert(item: $fontImportError) { error in
            Alert(
                title: Text(localized("字體匯入失敗")),
                message: Text(error.message),
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

    private var quickSettingsSection: some View {
        SettingsSection(title: localized("外觀與翻頁")) {
            VStack(spacing: 0) {
                if supportsBackground {
                    themeSelector
                }

                if supportsBackground && supportsLineHeight {
                    SettingsDivider()
                }

                if supportsLineHeight {
                    SegmentedPickerRow(
                        title: localized("翻頁"),
                        selection: pageTurnOptionBinding,
                        items: availablePageTurnOptions,
                        titleProvider: { localized($0.titleKey) }
                    )
                }
            }
        }
    }

    private var textStyleSection: some View {
        SettingsSection(title: localized("文字")) {
            VStack(spacing: 0) {
                if supportsUserFont {
                    fontSelector
                }

                if supportsUserFont && supportsFontSize {
                    SettingsDivider()
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
            }
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(localized("大"))
                    .font(.system(size: 34, weight: .regular))

                Text(localized("小"))
                    .font(.system(size: 18, weight: .regular))
                    .baselineOffset(-6)
            }
            Text(localized("可是越獄成功以後呢？以前我們裹足不前，可以怪父母怨社會，而阿德勒卻完全把人生責任和選擇的權力交給了我們自己。當我們從這些束縛中解脫出來後，卻會發現，我們其實一直都很自由，真正讓我們裹足不前的，原來正是我們自己。"))
                .font(.system(size: min(max(fontSize, 17), 24), weight: .regular))
                .lineSpacing(readerConfig.lineSpacing)
                .tracking(readerConfig.letterSpacing)
                .foregroundStyle(theme.textColor)
        }
        .padding(.horizontal, 34)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, minHeight: previewTextHeight, maxHeight: previewTextHeight, alignment: .topLeading)
        .clipped()
        .foregroundStyle(theme.textColor)
        .background(theme.backgroundColor)
    }

    private var themeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRowHeader(title: localized("主題"), systemImage: "circle.lefthalf.filled")

            Picker(localized("主題"), selection: $theme) {
                ForEach(ReaderTheme.allCases, id: \.self) { item in
                    Text(localized(item.rawValue)).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
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
                            settings.deleteReaderFont(font)
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
            HStack(spacing: 16) {
                SettingSymbolIcon(systemName: "textformat")
                Text(localized("字體"))
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(currentFontName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "textformat.alt")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var layoutDetailsSection: some View {
        SettingsSection(title: localized("輔助使用與佈局選項")) {
            VStack(spacing: 0) {
                Toggle(localized("自訂"), isOn: customLayoutBinding)
                    .font(.body)
                    .toggleStyle(.switch)

                if customLayoutEnabled {
                    if supportsSpacing {
                        SettingsDivider()
                        LayoutSliderRow(
                            title: localized("行距"),
                            icon: .lineSpacing,
                            valueText: String(format: "%.2f", readerConfig.lineHeightMultiple),
                            value: $readerConfig.lineHeightMultiple,
                            range: 1.0...2.4,
                            step: 0.05
                        )

                        SettingsDivider()
                        LayoutSliderRow(
                            title: localized("字距"),
                            icon: .characterSpacing,
                            valueText: "\(String(format: "%.1f", readerConfig.letterSpacing)) pt",
                            value: $readerConfig.letterSpacing,
                            range: 0...12,
                            step: 0.5
                        )

                        SettingsDivider()
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
                        SettingsDivider()
                        LayoutSliderRow(
                            title: localized("頁面留白"),
                            icon: .pageMargin,
                            valueText: "\(Int(readerConfig.pageMarginH))",
                            value: $readerConfig.pageMarginH,
                            range: 8...48,
                            step: 2
                        )

                        SettingsDivider()
                        LayoutSliderRow(
                            title: localized("底欄離底"),
                            icon: .footerBottom,
                            valueText: "\(Int(readerConfig.footerBottomPadding)) pt",
                            value: $readerConfig.footerBottomPadding,
                            range: 0...36,
                            step: 1
                        )

                        SettingsDivider()
                        LayoutSliderRow(
                            title: localized("正文到底欄"),
                            icon: .footerTextGap,
                            valueText: "\(Int(readerConfig.footerTextGap)) pt",
                            value: $readerConfig.footerTextGap,
                            range: 0...48,
                            step: 1
                        )
                    }
                }
            }
        }
    }

    private var displaySection: some View {
        SettingsSection(title: localized("亮度與顯示")) {
            VStack(spacing: 0) {
                ToggleRow(
                    title: localized("跟隨系統亮度"),
                    subtitle: localized("建議保持開啟，閱讀時更自然"),
                    isOn: followSystemBrightnessBinding
                )

                SettingsDivider()

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
            abs(readerConfig.footerBottomPadding - defaultFooterBottomPadding) > 0.001 ||
            abs(readerConfig.footerTextGap - defaultFooterTextGap) > 0.001
    }

    private func resetLayoutDefaults() {
        readerConfig.lineHeightMultiple = defaultLineHeightMultiple
        readerConfig.letterSpacing = defaultLetterSpacing
        readerConfig.paragraphSpacingMultiplier = defaultParagraphSpacingMultiplier
        readerConfig.pageMarginH = defaultPageMarginH
        readerConfig.footerBottomPadding = defaultFooterBottomPadding
        readerConfig.footerTextGap = defaultFooterTextGap
    }

    private var pageTurnOptionBinding: Binding<PageTurnOption> {
        Binding(
            get: {
                if !isVerticalWritingMode && settings.scrollMode {
                    return .scroll
                }
                switch settings.pageTurnStyle {
                case .slide: return .slide
                case .cover: return .cover
                case .curl: return .curl
                case .none: return .none
                }
            },
            set: { option in
                guard !(isVerticalWritingMode && option == .scroll) else { return }
                switch option {
                case .slide:
                    settings.scrollMode = false
                    settings.pageTurnStyle = .slide
                case .cover:
                    settings.scrollMode = false
                    settings.pageTurnStyle = .cover
                case .curl:
                    settings.scrollMode = false
                    settings.pageTurnStyle = .curl
                case .scroll:
                    settings.scrollMode = true
                case .none:
                    settings.scrollMode = false
                    settings.pageTurnStyle = .none
                }
            }
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
}

private enum LayoutMetricIconKind {
    case lineSpacing
    case characterSpacing
    case paragraphSpacing
    case pageMargin
    case footerBottom
    case footerTextGap
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.leading, 28)

            VStack(spacing: 0) {
                content
                    .padding(.horizontal, 26)
                    .padding(.vertical, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 58)
            .padding(.vertical, 16)
    }
}

private struct SettingRowHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 34, height: 26)
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                LayoutMetricIcon(kind: icon)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .lineSpacing:
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 15, weight: .bold))
                VStack(alignment: .leading, spacing: 4) {
                    iconLine(width: 22)
                    iconLine(width: 22)
                    iconLine(width: 22)
                }
            }
        case .characterSpacing:
            VStack(spacing: -2) {
                Text("甲乙丙")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 12, weight: .bold))
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
                    .font(.system(size: 12, weight: .bold))
            }
        case .footerTextGap:
            VStack(spacing: 3) {
                iconLine(width: 22)
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 12, weight: .bold))
                iconLine(width: 14)
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
                    .font(.body)
                Spacer()
                Text(valueText)
                    .font(.body.monospacedDigit())
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
            .font(.system(size: 22, weight: .regular))
            .frame(width: 34, height: 28)
            .foregroundStyle(.primary)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.body)
                Spacer()
                Text(valueText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FontImportError: Identifiable {
    let id = UUID()
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
