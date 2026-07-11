import SwiftUI
import UIKit

struct AppearanceThemeView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showPaywall = false
    @State private var showCustomizer = false
    @State private var editingCustomThemeID: String?
    @State private var customThemeToDelete: AppearanceThemePreset?

    private var selectedTheme: AppearanceThemePreset {
        settings.appearanceTheme(
            for: colorScheme,
            isProActive: subscriptionStore.hasAccess(.readerThemePacks)
        )
    }

    private var customThemes: [AppearanceThemePreset] {
        settings.customAppearanceThemes.map(AppearanceThemePreset.preset(from:))
    }

    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .compact ? 4 : 5
        return Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                themeSelectionCard
                togglesSection
                globalFontRow
                readerInterfaceRow
                rootTabRow
                // Pro upsell only; subscribers customize via 新建 / theme tiles.
                if !subscriptionStore.hasAccess(.readerThemePacks) {
                    customizationSection
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.top, DSSpacing.xl)
            // Extra bottom inset so the trailing caption never hides behind the
            // floating tab bar.
            .padding(.bottom, DSSpacing.xxl * 2)
            .frame(maxWidth: DSLayout.readableFormWidth)
            .frame(maxWidth: .infinity)
        }
        .background {
            pageBackground.ignoresSafeArea()
        }
        .navigationTitle(localized("外觀主題"))
        .toolbarTitleDisplayMode(.inline)
        .tint(selectedTheme.isClassic ? nil : selectedTheme.accentColor)
        .sheet(isPresented: $showPaywall) {
            PaywallView(highlightedFeature: .readerThemePacks)
                .environmentObject(subscriptionStore)
        }
        .navigationDestination(isPresented: $showCustomizer) {
            if let editingCustomThemeID {
                AppearanceThemeCustomizationView(themeID: editingCustomThemeID)
            }
        }
        .confirmationDialog(
            localized("刪除此自訂主題？"),
            isPresented: Binding(
                get: { customThemeToDelete != nil },
                set: { if !$0 { customThemeToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: customThemeToDelete
        ) { theme in
            Button(localized("刪除"), role: .destructive) {
                settings.deleteCustomAppearanceTheme(id: theme.id)
                customThemeToDelete = nil
            }
            Button(localized("取消"), role: .cancel) {
                customThemeToDelete = nil
            }
        } message: { theme in
            Text(theme.localizedName)
        }
    }

    @ViewBuilder
    private var pageBackground: some View {
        if selectedTheme.isClassic {
            DSColor.groupedBackground
        } else {
            LinearGradient(
                colors: [
                    selectedTheme.backgroundColor.opacity(0.78),
                    selectedTheme.dialogueColor.opacity(0.36),
                    DSColor.groupedBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var themeSelectionCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            LazyVGrid(columns: gridColumns, spacing: DSSpacing.lg) {
                themeOption(AppearanceThemePreset.classic)
                ForEach(AppearanceThemePreset.freeSolidPresets) { preset in
                    themeOption(preset)
                }
                newThemeButton
            }

            if !customThemes.isEmpty {
                themeGroupTitle(localized("自訂主題"))
                LazyVGrid(columns: gridColumns, spacing: DSSpacing.lg) {
                    ForEach(customThemes) { preset in
                        themeOption(preset)
                    }
                }
            }

            if !AppearanceThemePreset.bundledThemePacks.isEmpty {
                themeGroupTitle(localized("主題包"))
                LazyVGrid(columns: gridColumns, spacing: DSSpacing.lg) {
                    ForEach(AppearanceThemePreset.bundledThemePacks) { preset in
                        themeOption(preset)
                    }
                }
            }
        }
        .padding(DSSpacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
    }

    private func themeGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(DSFont.caption.weight(.semibold))
            .foregroundStyle(DSColor.textSecondary)
            .padding(.top, DSSpacing.xs)
    }

    private func themeOption(_ preset: AppearanceThemePreset) -> some View {
        let locked = preset.requiresPro && !subscriptionStore.hasAccess(.readerThemePacks)
        // Ring marks the theme actually in effect (not a stored-but-locked pick).
        let selected = selectedTheme.id == preset.id
        return Button {
            guard !locked else {
                showPaywall = true
                return
            }
            if preset.isCustom, selected {
                // Re-tapping the active custom theme opens the editor.
                editingCustomThemeID = preset.id
                showCustomizer = true
                return
            }
            settings.setAppearanceTheme(preset, for: colorScheme)
        } label: {
            VStack(spacing: DSSpacing.sm) {
                ThemePreviewTile(
                    preset: preset,
                    isSelected: selected,
                    isLocked: locked,
                    colorScheme: colorScheme
                )
                Text(preset.localizedName)
                    .font(DSFont.caption)
                    .foregroundStyle(locked ? DSColor.textDisabled : DSColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.72)
                    .frame(minHeight: 32, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if preset.isCustom, !locked {
                Button {
                    editingCustomThemeID = preset.id
                    showCustomizer = true
                } label: {
                    Label(localized("編輯"), systemImage: "slider.horizontal.3")
                }
                Button(role: .destructive) {
                    customThemeToDelete = preset
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(preset.localizedName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var newThemeButton: some View {
        Button {
            guard subscriptionStore.hasAccess(.readerThemePacks) else {
                showPaywall = true
                return
            }
            let custom = settings.createCustomAppearanceTheme(from: selectedTheme)
            editingCustomThemeID = custom.id
            showCustomizer = true
        } label: {
            VStack(spacing: DSSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                        .fill(DSColor.textSecondary.opacity(0.2))
                    Image(systemName: subscriptionStore.hasAccess(.readerThemePacks) ? "plus" : "lock.fill")
                        .font(DSFont.fixed(size: 24, weight: .semibold))
                        .foregroundStyle(selectedTheme.accentColor)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                Text(localized("新建"))
                    .font(DSFont.caption)
                    .foregroundStyle(subscriptionStore.hasAccess(.readerThemePacks) ? DSColor.textPrimary : DSColor.textDisabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .frame(minHeight: 32, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("新建"))
    }

    private var togglesSection: some View {
        VStack(spacing: DSSpacing.lg) {
            settingsToggle(
                title: localized("單獨設定深色主題"),
                isOn: $settings.appearanceUsesSeparateDarkTheme
            )

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                settingsToggle(
                    title: localized("綁定閱讀主題"),
                    isOn: $settings.appearanceBindReaderTheme
                )
                Text(localized("關閉時，切換此外觀主題不會影響閱讀主題。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .padding(.horizontal, DSSpacing.lg)
            }
        }
    }

    private func settingsToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
    }

    private var globalFontRow: some View {
        NavigationLink {
            GlobalFontSettingsView()
        } label: {
            HStack {
                Text(localized("全局字體"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(globalFontDisplayName)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Image(systemName: "chevron.right")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var globalFontDisplayName: String {
        guard let selected = settings.resolvedGlobalFontPostScript else {
            return localized("系統字體")
        }
        return settings.userFonts.first { $0.postScriptName == selected }?.displayName
            ?? localized("系統字體")
    }

    private var readerInterfaceRow: some View {
        NavigationLink {
            AppearanceReaderInterfaceView()
        } label: {
            HStack {
                Text(localized("閱讀界面"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(settings.appearanceReaderInterface.localizedTitle)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Image(systemName: "chevron.right")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var rootTabRow: some View {
        NavigationLink {
            RootTabCustomizationView()
        } label: {
            HStack {
                Text(localized("底部 Tab"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(subscriptionStore.hasAccess(.bottomBarCustomization) ? localized("自定義") : localized("需要 Pro"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Image(systemName: "chevron.right")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Free-user upsell row; hidden entirely once Pro is active.
    private var customizationSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Button {
                showPaywall = true
            } label: {
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: "crown.fill")
                        .font(DSFont.fixed(size: 20, weight: .semibold))
                        .foregroundStyle(selectedTheme.accentColor)
                        .frame(width: 28, height: 28)
                    Text(localized("主題自定義"))
                        .font(DSFont.title3.weight(.semibold))
                        .foregroundStyle(DSColor.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "lock.fill")
                        .foregroundStyle(DSColor.textSecondary)
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.lg)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
            }
            .buttonStyle(.plain)

            Text(localized("免費用戶可選擇 7 套內置主題；修改顏色、主題包、背景、封面等需開通會員。"))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DSSpacing.lg)
        }
    }
}

private struct ThemePreviewTile: View {
    let preset: AppearanceThemePreset
    let isSelected: Bool
    let isLocked: Bool
    let colorScheme: ColorScheme

    private let tileHeight: CGFloat = 58

    var body: some View {
        // Rigid cell-width × fixed-height frame + clip so an image preview
        // (scaledToFill) can never overflow into the neighbouring tile.
        previewBackground
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            .overlay(alignment: .topLeading) {
                if !preset.isImagePreset {
                    swatchContent
                }
            }
            .overlay {
                if isLocked {
                    ZStack {
                        RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                            .fill(Color.black.opacity(0.16))
                        Image(systemName: "lock.fill")
                            .font(DSFont.fixed(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .stroke(isSelected ? preset.accentColor : Color.clear, lineWidth: 3)
            )
    }

    /// Mini "reader page" sketch shown on solid-color swatches.
    private var swatchContent: some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Circle()
                .fill(preset.accentColor)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(preset.textColor)
                    .frame(width: 40, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(preset.textColor.opacity(0.78))
                    .frame(width: 30, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(preset.textColor.opacity(0.42))
                    .frame(width: 22, height: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.md)
    }

    @ViewBuilder
    private var previewBackground: some View {
        if preset.isImagePreset,
           let url = preset.backgroundImageURL(colorScheme: colorScheme),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [
                    preset.previewBackgroundColor,
                    preset.dialogueColor.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct AppearanceReaderInterfaceView: View {
    @ObservedObject private var settings = GlobalSettings.shared

    var body: some View {
        Form {
            Section(footer: Text(localized("選擇閱讀界面的工具列與控制方式。"))) {
                Picker(localized("閱讀界面"), selection: $settings.appearanceReaderInterface) {
                    ForEach(AppearanceReaderInterface.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        .navigationTitle(localized("閱讀界面"))
        .toolbarTitleDisplayMode(.inline)
    }
}

private struct AppearanceThemeCustomizationView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    let themeID: String

    private var themeBinding: Binding<AppearanceCustomTheme>? {
        guard let index = settings.customAppearanceThemes.firstIndex(where: { $0.id == themeID }) else {
            return nil
        }
        return Binding(
            get: { settings.customAppearanceThemes[index] },
            set: { settings.customAppearanceThemes[index] = $0 }
        )
    }

    var body: some View {
        Form {
            if let theme = themeBinding {
                Section(header: Text(localized("主題自定義"))) {
                    TextField(localized("名稱"), text: stringBinding(theme, \.name))
                    ColorPicker(localized("主色"), selection: colorBinding(theme, \.accentHex), supportsOpacity: false)
                    ColorPicker(localized("背景"), selection: colorBinding(theme, \.backgroundHex), supportsOpacity: false)
                    ColorPicker(localized("文字"), selection: colorBinding(theme, \.textHex), supportsOpacity: false)
                    ColorPicker(localized("工具列"), selection: colorBinding(theme, \.barHex), supportsOpacity: false)
                    ColorPicker(localized("對話高亮"), selection: colorBinding(theme, \.dialogueHex), supportsOpacity: false)
                }

                Section {
                    ThemePreviewTile(
                        preset: AppearanceThemePreset.preset(from: theme.wrappedValue),
                        isSelected: true,
                        isLocked: false,
                        colorScheme: .light
                    )
                    .frame(maxWidth: 180)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Text(localized("找不到主題"))
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .navigationTitle(localized("主題自定義"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("完成")) {
                    dismiss()
                }
            }
        }
    }

    private func stringBinding(
        _ theme: Binding<AppearanceCustomTheme>,
        _ keyPath: WritableKeyPath<AppearanceCustomTheme, String>
    ) -> Binding<String> {
        Binding(
            get: { theme.wrappedValue[keyPath: keyPath] },
            set: { value in
                var copy = theme.wrappedValue
                copy[keyPath: keyPath] = value
                theme.wrappedValue = copy
            }
        )
    }

    private func colorBinding(
        _ theme: Binding<AppearanceCustomTheme>,
        _ keyPath: WritableKeyPath<AppearanceCustomTheme, UInt32>
    ) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: AppearanceThemePreset.hex(theme.wrappedValue[keyPath: keyPath])) },
            set: { value in
                var copy = theme.wrappedValue
                copy[keyPath: keyPath] = UIColor(value).rgbHex ?? copy[keyPath: keyPath]
                theme.wrappedValue = copy
            }
        )
    }
}

#Preview {
    NavigationStack {
        AppearanceThemeView()
            .environmentObject(SubscriptionStore.shared)
    }
}
