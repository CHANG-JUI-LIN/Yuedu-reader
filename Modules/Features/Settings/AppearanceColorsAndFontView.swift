import SwiftUI
import UIKit

/// 外觀主題 › 顏色與字體: the theme's interface colours and the global font, grouped as
/// the reference the user handed over (2026-09-29) — 強調色, 文字顏色, 背景, 全局字體.
///
/// Each setting reaches one role, the one Apple's HIG gives it (redesigned 2026-09-29):
/// 強調色 what can be tapped or is selected, the three text levels iOS's label /
/// secondaryLabel / tertiaryLabel, 背景 the page and the surfaces stacked on it, the
/// font every interface text style. What the reader paints — its text, toolbars and
/// dialogue highlight — is set in 閱讀設定 and 閱讀界面; the theme's own values for
/// those stay its defaults there and are no longer edited here.
///
/// Light rows edit the theme picked for light, dark rows the theme picked for dark:
/// the same theme unless 單獨設定深色主題 is on. A built-in theme's edits are kept
/// apart (`appearanceBuiltInThemeColors`) and 重置為默認 puts them back.
struct AppearanceColorsAndFontView: View {
    @Bindable private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @State private var paywallFeature: PremiumFeature?

    var body: some View {
        Form {
            if subscriptionStore.hasAccess(.readerThemePacks) {
                accentSection
                textColorSection
                backgroundSection
            } else {
                Section {
                    SettingsLockedRow(title: localized("配色"), systemImage: "paintpalette") {
                        paywallFeature = .readerThemePacks
                    }
                }
                .interfaceSectionSurface()
            }
            fontSection
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("顏色與字體"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .sheet(item: $paywallFeature) { feature in
            PaywallView(highlightedFeature: feature)
                .environmentObject(subscriptionStore)
        }
    }

    // MARK: - Sections

    private var accentSection: some View {
        let light = colorsBinding(for: lightTheme)
        let dark = colorsBinding(for: darkTheme)
        return Section {
            ColorPicker(selection: hexColor(light, \.accentHex), supportsOpacity: false) {
                rowTitle("亮色模式")
            }
            .accessibilityLabel(modeLabel(section: "強調色", mode: "亮色模式"))
            // The dark accent is part of the dark palette: it has its own value only
            // once 自動深色配色 is off, under 背景.
            if dark.wrappedValue.dark != nil {
                ColorPicker(selection: darkHexColor(dark, \.accentHex), supportsOpacity: false) {
                    rowTitle("深色模式")
                }
                .accessibilityLabel(modeLabel(section: "強調色", mode: "深色模式"))
            }
        } header: {
            Text(localized("強調色"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("只用在能點或已選中的東西：按鈕、連結、開關、滑桿、選中狀態、Tab 選中圖示和設定列的圖示。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var textColorSection: some View {
        let light = colorsBinding(for: lightTheme)
        let dark = colorsBinding(for: darkTheme)
        return Section {
            ForEach(TextLevel.allCases) { level in
                ColorPicker(selection: textColor(light, level, dark: false), supportsOpacity: false) {
                    rowTitle(level.titleKey(dark: false))
                }
            }
            ForEach(TextLevel.allCases) { level in
                ColorPicker(selection: textColor(dark, level, dark: true), supportsOpacity: false) {
                    rowTitle(level.titleKey(dark: true))
                }
            }
        } header: {
            Text(localized("文字顏色"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("主文字用在標題和列名稱，次級文字用在數值、副標和說明，弱文字用在停用和提示文字。閱讀正文的顏色在閱讀設定裡設。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// What was 配色 until 2026-09-29. Its 文字, 工具列 and 對話高亮 only ever reached
    /// the reader (while 閱讀主題 follows the theme) and went to 閱讀設定 / 閱讀界面 at
    /// the user's call, leaving the background. 自動深色配色 stays here and still
    /// governs the whole dark palette, the dark 強調色 row included.
    private var backgroundSection: some View {
        let light = colorsBinding(for: lightTheme)
        let dark = colorsBinding(for: darkTheme)
        return Section {
            ColorPicker(selection: hexColor(light, \.backgroundHex), supportsOpacity: false) {
                rowTitle("亮色模式")
            }
            .accessibilityLabel(modeLabel(section: "背景", mode: "亮色模式"))
            Toggle(isOn: automaticDarkBinding(dark)) {
                rowTitle("自動深色配色")
            }
            if dark.wrappedValue.dark != nil {
                ColorPicker(selection: darkHexColor(dark, \.backgroundHex), supportsOpacity: false) {
                    rowTitle("深色模式")
                }
                .accessibilityLabel(modeLabel(section: "背景", mode: "深色模式"))
            }
        } header: {
            Text(localized("背景"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(dark.wrappedValue.dark == nil
                ? localized("頁面、卡片和面板的底色；閱讀主題選「跟隨外觀主題」時，閱讀頁也用它。關閉「自動深色配色」後，強調色和背景都能另外指定深色。")
                : localized("頁面、卡片和面板的底色；閱讀主題選「跟隨外觀主題」時，閱讀頁也用它。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var fontSection: some View {
        Section {
            NavigationLink {
                GlobalFontSettingsView()
            } label: {
                LabeledContent {
                    Text(settings.globalFontDisplayName)
                        .foregroundStyle(DSColor.textSecondary)
                } label: {
                    rowTitle("字體")
                }
            }
        } header: {
            Text(localized("全局字體"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("介面所有文字都用這個字體，並跟著系統字級縮放；閱讀正文的字體在閱讀設定裡設。打開「粗體文字」時，沒有粗體的字體會暫時改用系統字體。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// 強調色 and 背景 each have a 亮色模式 and a 深色模式 row, named as the reference the
    /// user handed over does (2026-09-29). Spoken alone, the two 亮色模式 would be the
    /// same row to VoiceOver, so each says whose it is — the way 頁首頁尾's colour rows do.
    private func modeLabel(section: String, mode: String) -> String {
        localized(section) + localized("，") + localized(mode)
    }

    /// A row's title in 主文字, like every settings row with a symbol
    /// (`SettingsRowLabel`) — a bare `Text` would stay in the system label colour,
    /// so this page would be the one place 主文字 does not reach.
    private func rowTitle(_ key: String) -> some View {
        Text(localized(key))
            .foregroundStyle(DSColor.textPrimary)
    }

    // MARK: - The themes edited

    private var lightTheme: AppearanceThemePreset {
        settings.appearanceBaseTheme(for: .light, isProActive: subscriptionStore.hasAccess(.readerThemePacks))
    }

    private var darkTheme: AppearanceThemePreset {
        settings.appearanceBaseTheme(for: .dark, isProActive: subscriptionStore.hasAccess(.readerThemePacks))
    }

    /// A theme's colours, read and written by id: one of the user's own in its own
    /// record, a built-in one in `appearanceBuiltInThemeColors` — seeded with the
    /// colours it ships with on the first edit.
    private func colorsBinding(for preset: AppearanceThemePreset) -> Binding<AppearanceCustomTheme> {
        let id = preset.id
        if let custom = settings.customAppearanceThemes.first(where: { $0.id == id }) {
            return Binding(
                get: { settings.customAppearanceThemes.first { $0.id == id } ?? custom },
                set: { edited in
                    guard let index = settings.customAppearanceThemes.firstIndex(where: { $0.id == id }) else { return }
                    settings.customAppearanceThemes[index] = edited
                }
            )
        }
        let shipped = preset.customCopy(name: preset.localizedName)
        return Binding(
            get: { settings.appearanceBuiltInThemeColors[id] ?? shipped },
            set: { settings.appearanceBuiltInThemeColors[id] = $0 }
        )
    }

    // MARK: - Bindings

    private func hexColor(
        _ theme: Binding<AppearanceCustomTheme>,
        _ keyPath: WritableKeyPath<AppearanceCustomTheme, UInt32>
    ) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: AppearanceThemePreset.hex(theme.wrappedValue[keyPath: keyPath])) },
            set: { value in
                var copy = theme.wrappedValue
                copy[keyPath: keyPath] = UIColor(value).rgbHex ?? copy[keyPath: keyPath]
                // 默認 keeps the system's backgrounds until 背景 itself is changed.
                if keyPath == \AppearanceCustomTheme.backgroundHex {
                    copy.hasEditedBackground = true
                }
                theme.wrappedValue = copy
            }
        )
    }

    /// On the optional dark palette. Only reachable while it exists (the rows are hidden
    /// under 自動深色配色), so a missing palette reads as the derived value and writes
    /// seed one.
    private func darkHexColor(
        _ theme: Binding<AppearanceCustomTheme>,
        _ keyPath: WritableKeyPath<AppearanceCustomThemeDarkColors, UInt32>
    ) -> Binding<Color> {
        Binding(
            get: {
                let colors = theme.wrappedValue.dark ?? Self.derivedDarkColors(of: theme.wrappedValue)
                return Color(uiColor: AppearanceThemePreset.hex(colors[keyPath: keyPath]))
            },
            set: { value in
                var copy = theme.wrappedValue
                var colors = copy.dark ?? Self.derivedDarkColors(of: copy)
                colors[keyPath: keyPath] = UIColor(value).rgbHex ?? colors[keyPath: keyPath]
                copy.dark = colors
                if keyPath == \AppearanceCustomThemeDarkColors.backgroundHex {
                    copy.hasEditedDarkBackground = true
                }
                theme.wrappedValue = copy
            }
        )
    }

    /// Automatic by default (colours derived from the light palette). Switching it off
    /// seeds the dark colours with what the derivation produced, so the first thing
    /// shown is what was already on screen.
    private func automaticDarkBinding(_ theme: Binding<AppearanceCustomTheme>) -> Binding<Bool> {
        Binding(
            get: { theme.wrappedValue.dark == nil },
            set: { isAutomatic in
                var copy = theme.wrappedValue
                copy.dark = isAutomatic ? nil : Self.derivedDarkColors(of: copy)
                // A dark palette just seeded, or none: its 背景 has not been changed.
                copy.hasEditedDarkBackground = nil
                theme.wrappedValue = copy
            }
        )
    }

    /// What the automatic derivation currently produces for this theme, in storage form.
    private static func derivedDarkColors(of theme: AppearanceCustomTheme) -> AppearanceCustomThemeDarkColors {
        var withoutOverride = theme
        withoutOverride.dark = nil
        let derived = AppearanceThemePreset.preset(from: withoutOverride).palette(for: .dark)
        return AppearanceThemeDarkColors(
            background: derived.background,
            text: derived.text,
            bar: derived.bar,
            accent: derived.accent,
            dialogue: derived.dialogue
        ).stored
    }

    /// One text level. A theme's text colours count only as a full set of three, so
    /// the first edit fills the other two with what they show now.
    private func textColor(
        _ theme: Binding<AppearanceCustomTheme>,
        _ level: TextLevel,
        dark: Bool
    ) -> Binding<Color> {
        Binding(
            get: {
                let stored = theme.wrappedValue[keyPath: level.keyPath(dark: dark)]
                return Color(uiColor: AppearanceThemePreset.hex(stored ?? level.systemHex(dark: dark)))
            },
            set: { value in
                guard let hex = UIColor(value).rgbHex else { return }
                var copy = theme.wrappedValue
                for other in TextLevel.allCases where copy[keyPath: other.keyPath(dark: dark)] == nil {
                    copy[keyPath: other.keyPath(dark: dark)] = other.systemHex(dark: dark)
                }
                copy[keyPath: level.keyPath(dark: dark)] = hex
                theme.wrappedValue = copy
            }
        )
    }
}

/// The interface's three text levels.
private enum TextLevel: CaseIterable, Identifiable {
    case primary
    case secondary
    case tertiary

    var id: Self { self }

    func titleKey(dark: Bool) -> String {
        switch self {
        case .primary: return dark ? "深色主文字" : "亮色主文字"
        case .secondary: return dark ? "深色次級文字" : "亮色次級文字"
        case .tertiary: return dark ? "深色弱文字" : "亮色弱文字"
        }
    }

    func keyPath(dark: Bool) -> WritableKeyPath<AppearanceCustomTheme, UInt32?> {
        switch self {
        case .primary: return dark ? \.darkTextPrimaryHex : \.textPrimaryHex
        case .secondary: return dark ? \.darkTextSecondaryHex : \.textSecondaryHex
        case .tertiary: return dark ? \.darkTextTertiaryHex : \.textTertiaryHex
        }
    }

    /// What the interface draws this level in when the theme names none: the system
    /// label colour, flattened onto the page it sits on — white in light, black in dark.
    func systemHex(dark: Bool) -> UInt32 {
        let label: UIColor
        switch self {
        case .primary: label = .label
        case .secondary: label = .secondaryLabel
        case .tertiary: label = .tertiaryLabel
        }
        let resolved = label.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let page: CGFloat = dark ? 0 : 1
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32(min(max((page + (value - page) * alpha) * 255, 0), 255).rounded())
        }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }
}

extension GlobalSettings {
    /// The global font by the name 顏色與字體 shows it under: an imported font's own
    /// name, else 系統字體.
    var globalFontDisplayName: String {
        guard let selected = resolvedGlobalFontPostScript else {
            return localized("系統字體")
        }
        return userFonts.first { $0.postScriptName == selected }?.displayName
            ?? localized("系統字體")
    }
}

#Preview {
    NavigationStack {
        AppearanceColorsAndFontView()
    }
}
