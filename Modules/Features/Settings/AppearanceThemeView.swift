import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppearanceThemeView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showPaywall = false
    @State private var showCustomizer = false
    @State private var editingCustomThemeID: String?
    @State private var customThemeToDelete: AppearanceThemePreset?
    @State private var showLaunchImageSettings = false
    @State private var showLaunchImagePaywall = false

    // 頁面背景 editor state.
    @State private var pageBackgroundScope: AppearancePageBackgroundScope = .global
    @State private var backgroundImagePickScheme: ColorScheme = .light
    @State private var showBackgroundPhotosPicker = false
    @State private var backgroundPhotoItem: PhotosPickerItem?
    @State private var isImportingBackgroundFile = false
    @State private var showSaveThemeAlert = false
    @State private var newThemeName = ""
    @State private var themeExportDocument: AppearanceThemeExportDocument?
    @State private var showThemeExporter = false
    @State private var showThemeImporter = false
    @State private var showResetPageBackgroundConfirm = false
    @State private var pageBackgroundAlertMessage: String?

    private static let backgroundImageContentTypes: [UTType] = [
        UTType(filenameExtension: "webp") ?? .data,
        UTType(filenameExtension: "jpg") ?? .jpeg,
        UTType(filenameExtension: "jpeg") ?? .jpeg,
        .png,
    ]

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
                launchImageRow
                if ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive).showsBottomTabCustomization {
                    rootTabRow
                }
                if subscriptionStore.hasAccess(.readerThemePacks) {
                    pageBackgroundSection
                    themeActionsSection
                } else {
                    pageBackgroundLockedRow
                }
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
        .font(DSFont.body)
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
        .navigationDestination(isPresented: $showLaunchImageSettings) {
            LaunchImageSettingsView()
        }
        .sheet(isPresented: $showLaunchImagePaywall) {
            PaywallView(highlightedFeature: .launchScreen)
                .environmentObject(subscriptionStore)
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
        .photosPicker(
            isPresented: $showBackgroundPhotosPicker,
            selection: $backgroundPhotoItem,
            matching: .images
        )
        .onChange(of: backgroundPhotoItem) { _, item in
            guard let item else { return }
            importBackgroundPhoto(item)
        }
        .fileImporter(
            isPresented: $isImportingBackgroundFile,
            allowedContentTypes: Self.backgroundImageContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleBackgroundFileImport
        )
        .alert(
            localized("匯入失敗"),
            isPresented: Binding(
                get: { pageBackgroundAlertMessage != nil },
                set: { if !$0 { pageBackgroundAlertMessage = nil } }
            )
        ) {
            Button(localized("確定"), role: .cancel) {
                pageBackgroundAlertMessage = nil
            }
        } message: {
            Text(pageBackgroundAlertMessage ?? "")
        }
    }

    private var pageBackground: some View {
        DSColor.groupedBackground
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
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
    }

    private func themeGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(DSFont.subheadline.weight(.semibold))
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
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
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
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
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
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Launch-image entry. Pro users push the settings page; free users tapping
    /// it get the paywall highlighting the launch-screen feature.
    private var launchImageRow: some View {
        Button {
            if subscriptionStore.hasAccess(.launchScreen) {
                showLaunchImageSettings = true
            } else {
                showLaunchImagePaywall = true
            }
        } label: {
            HStack {
                Text(localized("啟動圖"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(launchImageStatusText)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Image(systemName: subscriptionStore.hasAccess(.launchScreen) ? "chevron.right" : "lock.fill")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var launchImageStatusText: String {
        guard subscriptionStore.hasAccess(.launchScreen) else {
            return localized("需要 Pro")
        }
        return settings.launchImageEnabled ? localized("已開啟") : localized("已關閉")
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
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 頁面背景 (page background editor)

    private func pageBackgroundSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DSFont.headline)
            .foregroundStyle(DSColor.textPrimary)
            .padding(.horizontal, DSSpacing.xs)
    }

    private var pageBackgroundSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            pageBackgroundSectionHeader(localized("頁面背景"))

            VStack(spacing: 0) {
                editScopeRow
                groupedSectionDivider
                pageBackgroundColorRow(titleKey: "亮色主色調", scheme: .light, slot: .primary)
                groupedSectionDivider
                pageBackgroundColorRow(titleKey: "亮色輔色調", scheme: .light, slot: .secondary)
                groupedSectionDivider
                pageBackgroundColorRow(titleKey: "深色主色調", scheme: .dark, slot: .primary)
                groupedSectionDivider
                pageBackgroundColorRow(titleKey: "深色輔色調", scheme: .dark, slot: .secondary)
                groupedSectionDivider
                backgroundImageRow(scheme: .light)
                groupedSectionDivider
                backgroundImageRow(scheme: .dark)
            }
            .background(
                DSColor.surface,
                in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
            )

            pageBackgroundSectionHeader(localized("預覽"))
            pageBackgroundPreviewCard
        }
    }

    private var groupedSectionDivider: some View {
        Divider()
            .overlay(DSColor.separator)
            .padding(.leading, DSSpacing.lg)
    }

    private var editScopeRow: some View {
        HStack {
            Text(localized("編輯範圍"))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
            Spacer(minLength: DSSpacing.md)
            Menu {
                Picker(localized("編輯範圍"), selection: $pageBackgroundScope) {
                    ForEach(AppearancePageBackgroundScope.allCases) { scope in
                        Text(scope.localizedTitle).tag(scope)
                    }
                }
            } label: {
                HStack(spacing: DSSpacing.xs) {
                    Text(pageBackgroundScope.localizedTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(DSFont.caption.weight(.semibold))
                }
                .font(DSFont.body)
                .foregroundStyle(DSColor.accent)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.lg)
    }

    private func pageBackgroundColorRow(
        titleKey: String,
        scheme: ColorScheme,
        slot: PageBackgroundColorSlot
    ) -> some View {
        ColorPicker(selection: pageBackgroundColorBinding(scheme: scheme, slot: slot), supportsOpacity: false) {
            Text(localized(titleKey))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
    }

    private func pageBackgroundColorBinding(
        scheme: ColorScheme,
        slot: PageBackgroundColorSlot
    ) -> Binding<Color> {
        Binding(
            get: {
                let config = settings.pageBackgroundConfig(for: pageBackgroundScope)
                let stored = slot == .primary
                    ? config.primaryHex(for: scheme)
                    : config.secondaryHex(for: scheme)
                let hex = stored ?? Self.defaultPageBackgroundHex(scheme: scheme, slot: slot)
                return Color(uiColor: AppearanceThemePreset.hex(hex))
            },
            set: { value in
                guard let hex = UIColor(value).rgbHex else { return }
                var config = settings.pageBackgroundConfig(for: pageBackgroundScope)
                if slot == .primary {
                    config.setPrimaryHex(hex, for: scheme)
                } else {
                    config.setSecondaryHex(hex, for: scheme)
                }
                settings.updatePageBackgroundConfig(config, for: pageBackgroundScope)
            }
        )
    }

    /// Placeholder swatch values shown before the user picks anything; chosen to
    /// match the stock system page look for each appearance.
    private static func defaultPageBackgroundHex(
        scheme: ColorScheme,
        slot: PageBackgroundColorSlot
    ) -> UInt32 {
        if scheme == .dark {
            return slot == .primary ? 0x1C1C1E : 0x2C2C2E
        }
        return slot == .primary ? 0xF2F2F7 : 0xFFFFFF
    }

    private func backgroundImageRow(scheme: ColorScheme) -> some View {
        let titleKey = scheme == .dark ? "深色背景圖" : "亮色背景圖"
        let fileName = settings.pageBackgroundConfig(for: pageBackgroundScope).imageFileName(for: scheme)
        return HStack(spacing: DSSpacing.md) {
            Text(localized(titleKey))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
            Spacer(minLength: DSSpacing.md)
            if let fileName,
               let image = AppearancePageBackgroundImageStore.shared.image(fileName: fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .stroke(DSColor.border, lineWidth: 0.5)
                    )
                    .accessibilityHidden(true)
            }
            Menu {
                Button {
                    backgroundImagePickScheme = scheme
                    showBackgroundPhotosPicker = true
                } label: {
                    Label(localized("從相簿選擇"), systemImage: "photo.on.rectangle")
                }
                Button {
                    backgroundImagePickScheme = scheme
                    isImportingBackgroundFile = true
                } label: {
                    Label(localized("從檔案選擇"), systemImage: "folder")
                }
                if fileName != nil {
                    Button(role: .destructive) {
                        settings.clearPageBackgroundImage(scope: pageBackgroundScope, appearance: scheme)
                    } label: {
                        Label(localized("移除背景圖"), systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: DSSpacing.xs) {
                    Text(localized("選擇"))
                    Image(systemName: "chevron.down")
                        .font(DSFont.caption2.weight(.semibold))
                }
                .font(DSFont.subheadline.weight(.medium))
                .foregroundStyle(DSColor.accent)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm - 2)
                .background(DSColor.accent.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel(localized(titleKey))
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
    }

    /// Live preview of the effective background for the edited scope in the
    /// current appearance (with global fallback), or the stock look when the
    /// scope has nothing configured.
    private var pageBackgroundPreviewCard: some View {
        let slice = settings.resolvedPageBackgroundSlice(
            for: pageBackgroundScope,
            colorScheme: colorScheme
        )
        let modeName = colorScheme == .dark ? localized("深色模式") : localized("亮色模式")
        return ZStack {
            if let slice {
                AppearancePageBackgroundLayerView(slice: slice)
            } else {
                pageBackground
            }
            VStack(spacing: DSSpacing.sm) {
                Text(localized("背景預覽"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                Text("\(pageBackgroundScope.localizedTitle) · \(modeName)")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                Text(localized("弱文字樣例"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary.opacity(0.72))
            }
            .padding(DSSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Theme actions (save / export / import / reset)

    private var themeActionsSection: some View {
        VStack(spacing: 0) {
            themeActionRow(titleKey: "保存為新主題") {
                newThemeName = ""
                showSaveThemeAlert = true
            }
            .alert(localized("保存為新主題"), isPresented: $showSaveThemeAlert) {
                TextField(localized("主題名稱"), text: $newThemeName)
                Button(localized("保存")) {
                    settings.saveCurrentAppearanceAsTheme(named: newThemeName, basedOn: selectedTheme)
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("將當前配色與頁面背景保存為自訂主題。"))
            }

            groupedSectionDivider

            themeActionRow(titleKey: "導出主題") {
                themeExportDocument = AppearanceThemeExportDocument(
                    exportFile: settings.appearanceThemeExportFile(for: selectedTheme)
                )
                showThemeExporter = true
            }
            .fileExporter(
                isPresented: $showThemeExporter,
                document: themeExportDocument,
                contentType: .json,
                defaultFilename: "yuedu-theme-\(selectedTheme.localizedName)"
            ) { _ in
                themeExportDocument = nil
            }

            groupedSectionDivider

            themeActionRow(titleKey: "導入主題") {
                showThemeImporter = true
            }
            .fileImporter(
                isPresented: $showThemeImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: handleThemeImport
            )

            groupedSectionDivider

            themeActionRow(titleKey: "重置為默認") {
                showResetPageBackgroundConfirm = true
            }
            .confirmationDialog(
                localized("重置為默認？"),
                isPresented: $showResetPageBackgroundConfirm,
                titleVisibility: .visible
            ) {
                Button(localized("重置為默認"), role: .destructive) {
                    settings.resetAllPageBackgrounds()
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("將清除所有頁面（含各分頁）的背景顏色與背景圖設定。"))
            }
        }
        .background(
            DSColor.surface,
            in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
        )
    }

    private func themeActionRow(titleKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(localized(titleKey))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Free-user entry: same row shape as the Pro editor's rows, tapping opens
    /// the paywall highlighting theme packs.
    private var pageBackgroundLockedRow: some View {
        Button {
            showPaywall = true
        } label: {
            HStack {
                Text(localized("頁面背景"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(localized("需要 Pro"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Image(systemName: "lock.fill")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Background import handlers

    private func importBackgroundPhoto(_ item: PhotosPickerItem) {
        let scope = pageBackgroundScope
        let scheme = backgroundImagePickScheme
        Task { @MainActor in
            defer { backgroundPhotoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                pageBackgroundAlertMessage = localized("無法讀取圖片。")
                return
            }
            do {
                try settings.importPageBackgroundImage(data: data, scope: scope, appearance: scheme)
            } catch let error as AppearancePageBackgroundImageError {
                pageBackgroundAlertMessage = localized(error.messageKey)
            } catch {
                pageBackgroundAlertMessage = localized("無法讀取圖片。")
            }
        }
    }

    private func handleBackgroundFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            try settings.importPageBackgroundImage(
                from: url,
                scope: pageBackgroundScope,
                appearance: backgroundImagePickScheme
            )
        } catch let error as AppearancePageBackgroundImageError {
            pageBackgroundAlertMessage = localized(error.messageKey)
        } catch {
            pageBackgroundAlertMessage = localized("無法讀取圖片。")
        }
    }

    private func handleThemeImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            try settings.importAppearanceTheme(from: data)
        } catch let error as AppearanceThemeImportError {
            pageBackgroundAlertMessage = localized(error.messageKey)
        } catch {
            pageBackgroundAlertMessage = localized("匯入主題失敗。")
        }
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
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "lock.fill")
                        .foregroundStyle(DSColor.textSecondary)
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.lg)
                .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
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
            Section {
                Picker(selection: $settings.appearanceReaderInterface) {
                    ForEach(AppearanceReaderInterface.allCases) { option in
                        Text(option.localizedTitle)
                            .font(DSFont.body)
                            .tag(option)
                    }
                } label: {
                    Text(localized("閱讀界面"))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                }
                .pickerStyle(.inline)
            } footer: {
                Text(localized("選擇閱讀界面的工具列與控制方式。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .listRowBackground(DSColor.surface)
        }
        .font(DSFont.body)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
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
                Section {
                    TextField(localized("名稱"), text: stringBinding(theme, \.name))
                        .font(DSFont.body)
                    themeColorPicker("主色", selection: colorBinding(theme, \.accentHex))
                    themeColorPicker("背景", selection: colorBinding(theme, \.backgroundHex))
                    themeColorPicker("文字", selection: colorBinding(theme, \.textHex))
                    themeColorPicker("工具列", selection: colorBinding(theme, \.barHex))
                    themeColorPicker("對話高亮", selection: colorBinding(theme, \.dialogueHex))
                } header: {
                    Text(localized("主題自定義"))
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.textPrimary)
                }
                .listRowBackground(DSColor.surface)

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
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .listRowBackground(DSColor.surface)
            }
        }
        .font(DSFont.body)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
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

    private func themeColorPicker(_ titleKey: String, selection: Binding<Color>) -> some View {
        ColorPicker(selection: selection, supportsOpacity: false) {
            Text(localized(titleKey))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
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

/// Which end of the page-background gradient a color row edits.
private enum PageBackgroundColorSlot {
    case primary
    case secondary
}

/// JSON wrapper handed to `fileExporter` for 導出主題.
struct AppearanceThemeExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(exportFile: AppearanceThemeExportFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? encoder.encode(exportFile)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    NavigationStack {
        AppearanceThemeView()
            .environmentObject(SubscriptionStore.shared)
    }
}
