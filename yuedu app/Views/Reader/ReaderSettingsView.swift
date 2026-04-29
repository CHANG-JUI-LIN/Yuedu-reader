import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ReaderSettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var theme: ReaderTheme
    var capabilities: ReaderCapabilities = .reflowableText
    var allowsUserSelectedReaderFont = false

    @StateObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingFontImporter = false
    @State private var fontImportError: FontImportError?

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
        Color(red: 82 / 255, green: 99 / 255, blue: 84 / 255)
    }

    private enum MarginPreset: String, CaseIterable, Hashable {
        case narrow
        case medium
        case wide

        var titleKey: String {
            switch self {
            case .narrow: return "窄"
            case .medium: return "適中"
            case .wide: return "寬"
            }
        }

        var horizontal: CGFloat {
            switch self {
            case .narrow: return 16
            case .medium: return 24
            case .wide: return 34
            }
        }

        var vertical: CGFloat {
            switch self {
            case .narrow: return 12
            case .medium: return 16
            case .wide: return 24
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    previewCard

                    if supportsBackground || supportsLineHeight {
                        SettingSectionCard(title: localized("頁面與主題"), systemImage: "rectangle.on.rectangle") {
                            if supportsBackground {
                                themeSelector
                            }

                            if supportsBackground && supportsLineHeight {
                                Divider().opacity(0.5)
                            }

                            if supportsLineHeight {
                                marginSelector
                            }
                        }
                    }

                    if supportsFontSize || supportsSpacing || supportsUserFont {
                        SettingSectionCard(title: localized("字體與排版"), systemImage: "textformat.size") {
                            if supportsUserFont {
                                fontSelector
                            }

                            if supportsUserFont && (supportsFontSize || supportsSpacing) {
                                Divider().opacity(0.5)
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

                            if supportsSpacing {
                                VStack(spacing: 14) {
                                    ValueSliderRow(
                                        title: localized("行距"),
                                        valueText: lineHeightLabel,
                                        value: $readerConfig.lineHeightMultiple,
                                        range: 1.0...2.4,
                                        step: 0.05
                                    )

                                    ValueSliderRow(
                                        title: localized("字距"),
                                        valueText: "\(String(format: "%.1f", readerConfig.letterSpacing)) pt",
                                        value: $readerConfig.letterSpacing,
                                        range: 0...12,
                                        step: 0.5
                                    )

                                    ValueSliderRow(
                                        title: localized("段距"),
                                        valueText: paragraphSpacingLabel,
                                        value: $readerConfig.paragraphSpacingMultiplier,
                                        range: 0.3...1.2,
                                        step: 0.05
                                    )
                                }
                            }
                        }
                    }

                    SettingSectionCard(title: localized("閱讀方式"), systemImage: "book.pages") {
                        SegmentedPickerRow(
                            title: localized("文字轉換"),
                            selection: textConversionBinding,
                            items: TextConversion.allCases,
                            titleProvider: { localized($0.rawValue) }
                        )

                        if supportsLineHeight {
                            SegmentedPickerRow(
                                title: localized("閱讀模式"),
                                selection: scrollModeBinding,
                                items: [false, true],
                                titleProvider: { localized($0 ? "上下滾動" : "左右翻頁") }
                            )
                        }

                        if !settings.scrollMode && supportsLineHeight {
                            MenuPickerRow(
                                title: localized("翻頁動畫"),
                                selection: $settings.pageTurnStyle,
                                items: PageTurnStyle.allCases,
                                titleProvider: { localized($0.rawValue) }
                            )
                        }
                    }

                    SettingSectionCard(title: localized("亮度與顯示"), systemImage: "sun.max") {
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
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
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

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localized("預覽"))
                    .font(.subheadline)
                    .foregroundStyle(theme.textColor.opacity(0.85))
                Spacer()
                Text(localized(theme.rawValue))
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.textColor.opacity(0.10), in: Capsule())
                    .foregroundStyle(theme.textColor.opacity(0.85))
            }

            Text(localized("夜雨剪春韭，新炊間黃粱。書頁展開時，字與紙都應該安靜下來，讓閱讀本身成為畫面中心。"))
                .font(.system(size: fontSize))
                .lineSpacing(readerConfig.lineSpacing)
                .tracking(readerConfig.letterSpacing)
                .foregroundStyle(theme.textColor)
                .lineLimit(3)
                .padding(.horizontal, max(14, readerConfig.pageMarginH * 0.35))
                .padding(.vertical, max(10, readerConfig.pageMarginV * 0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.black.opacity(0.04), lineWidth: 0.5)
        }
    }

    private var themeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("主題"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker(localized("主題"), selection: $theme) {
                ForEach(ReaderTheme.allCases, id: \.self) { item in
                    Text(localized(item.rawValue)).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var fontSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("字體"))
                        .font(.subheadline)
                    Text(currentFontName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Picker(localized("字體"), selection: selectedFontBinding) {
                    Text(localized("系統字體")).tag("")
                    ForEach(settings.userFonts, id: \.id) { font in
                        Text(font.displayName).tag(font.postScriptName)
                    }
                }
                .pickerStyle(.menu)
            }

            Button {
                showingFontImporter = true
            } label: {
                Label(localized("匯入字體..."), systemImage: "plus")
                    .font(.subheadline)
            }

            if !settings.userFonts.isEmpty {
                ForEach(settings.userFonts) { font in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(font.displayName)
                                .font(.subheadline)
                            Text(font.postScriptName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.deleteReaderFont(font)
                            readerConfig.refresh.send(.layout)
                        } label: {
                            Label(localized("刪除"), systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var marginSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("頁面留白"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker(localized("頁面留白"), selection: marginPresetBinding) {
                ForEach(MarginPreset.allCases, id: \.self) { preset in
                    Text(localized(preset.titleKey)).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            ValueSliderRow(
                title: localized("左右"),
                valueText: "\(Int(readerConfig.pageMarginH))",
                value: $readerConfig.pageMarginH,
                range: 8...48,
                step: 2
            )

            ValueSliderRow(
                title: localized("上下"),
                valueText: "\(Int(readerConfig.pageMarginV))",
                value: $readerConfig.pageMarginV,
                range: 8...48,
                step: 2
            )
        }
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { fontSize },
            set: { fontSize = min(32, max(12, $0)) }
        )
    }

    private var selectedFontBinding: Binding<String> {
        Binding(
            get: { settings.selectedReaderFontPostScript ?? "" },
            set: { value in
                settings.selectedReaderFontPostScript = value.isEmpty ? nil : value
                readerConfig.refresh.send(.layout)
            }
        )
    }

    private var marginPresetBinding: Binding<MarginPreset> {
        Binding(
            get: { closestMarginPreset() },
            set: { preset in
                setMargin(horizontal: preset.horizontal, vertical: preset.vertical)
            }
        )
    }

    private var textConversionBinding: Binding<TextConversion> {
        Binding(
            get: { settings.textConversion },
            set: { mode in
                settings.textConversion = mode
                readerConfig.refresh.send(.layout)
            }
        )
    }

    private var scrollModeBinding: Binding<Bool> {
        Binding(
            get: { settings.scrollMode },
            set: { scrollMode in
                settings.scrollMode = scrollMode
                readerConfig.refresh.send(.layout)
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

    private var lineHeightLabel: String {
        switch readerConfig.lineHeightMultiple {
        case ..<1.45: return localized("緊湊")
        case ..<1.85: return localized("標準")
        default: return localized("寬鬆")
        }
    }

    private var paragraphSpacingLabel: String {
        switch readerConfig.paragraphSpacingMultiplier {
        case ..<0.45: return localized("小")
        case ..<1.05: return localized("中")
        default: return localized("大")
        }
    }

    private var currentFontName: String {
        guard let selected = settings.selectedReaderFontPostScript else { return localized("系統字體") }
        return settings.userFonts.first { $0.postScriptName == selected }?.displayName ?? selected
    }

    private func syncBrightnessFromSystem() {
        settings.readerBrightness = Double(UIScreen.main.brightness)
    }

    private func setMargin(horizontal: CGFloat, vertical: CGFloat) {
        readerConfig.pageMarginH = horizontal
        readerConfig.pageMarginV = vertical
    }

    private func closestMarginPreset() -> MarginPreset {
        MarginPreset.allCases.min { lhs, rhs in
            let lhsDistance = abs(readerConfig.pageMarginH - lhs.horizontal) + abs(readerConfig.pageMarginV - lhs.vertical)
            let rhsDistance = abs(readerConfig.pageMarginH - rhs.horizontal) + abs(readerConfig.pageMarginV - rhs.vertical)
            return lhsDistance < rhsDistance
        } ?? .medium
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

private struct SettingSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            content
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.black.opacity(0.04), lineWidth: 0.5)
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
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.regular)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.caption)
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
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

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

private struct MenuPickerRow<Item: Hashable>: View {
    let title: String
    @Binding var selection: Item
    let items: [Item]
    let titleProvider: (Item) -> String

    private var selectedTitle: String {
        guard let selected = items.first(where: { $0 == selection }) else {
            return ""
        }
        return titleProvider(selected)
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(titleProvider(item)).tag(item)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(selectedTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.regular)
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
                    .font(.subheadline)
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
