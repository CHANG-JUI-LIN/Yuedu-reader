import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppearanceThemeView: View {
    private enum LegacyBackgroundImageAction: Hashable {
        case photos
        case files
    }

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
    @State private var showLegacyBackgroundImageChooser = false
    @State private var legacyBackgroundImageSequence =
        DismissalSequencedPresentation<LegacyBackgroundImageAction>()
    @State private var showSaveThemeAlert = false
    @State private var newThemeName = ""
    @State private var themeExportDocument: AppearanceThemeExportDocument?
    @State private var showThemeExporter = false
    @State private var showThemeImporter = false
    @State private var showResetPageBackgroundConfirm = false
    @State private var pageBackgroundAlertMessage: String?
    /// Appearance slot the theme grid edits, once the user picks one by hand.
    /// nil means "whatever the device is showing", which is also the only
    /// behaviour available while 單獨設定深色主題 is off.
    @State private var themeSlot: ColorScheme?

    private static let backgroundImageContentTypes: [UTType] = [
        UTType(filenameExtension: "webp") ?? .data,
        UTType(filenameExtension: "jpg") ?? .jpeg,
        UTType(filenameExtension: "jpeg") ?? .jpeg,
        .png,
    ]

    /// Appearance the theme grid is editing: the slot picked above the grid when
    /// 單獨設定深色主題 is on, otherwise whatever the device is showing.
    private var editingScheme: ColorScheme {
        guard settings.appearanceUsesSeparateDarkTheme else { return colorScheme }
        return themeSlot ?? colorScheme
    }

    /// Theme selected in the edited slot, as its *identity* — the grid compares
    /// ids and the 新建 / 保存 actions copy from it, so it must not be swapped for
    /// a derived dark palette here.
    private var selectedTheme: AppearanceThemePreset {
        settings.appearanceBaseTheme(
            for: editingScheme,
            isProActive: subscriptionStore.hasAccess(.readerThemePacks)
        )
    }

    /// Theme painting the app right now. Drives this screen's own tint.
    private var activeTheme: AppearanceThemePreset {
        settings.appearanceTheme(
            for: colorScheme,
            isProActive: subscriptionStore.hasAccess(.readerThemePacks)
        )
    }

    /// Appearance forced on the app while a slot is being edited by hand, so the
    /// 深色 tab shows the dark theme *in place* — picking colors you cannot see is
    /// not a review. Flipping the window's scheme is what makes `colorScheme`
    /// (and with it every DSColor surface, which resolves per trait, and this screen's
    /// own tint) resolve to the edited appearance. nil = follow the device, which
    /// is also the only state reachable while 單獨設定深色主題 is off.
    private var previewedAppearance: ColorScheme? {
        guard settings.appearanceUsesSeparateDarkTheme else { return nil }
        return themeSlot
    }

    private var customThemes: [AppearanceThemePreset] {
        settings.customAppearanceThemes.map(AppearanceThemePreset.preset(from:))
    }

    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .compact ? 4 : 5
        return Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: count)
    }

    var body: some View {
        List {
            themeSelectionSection
            themeSwitchingSection
            readingSettingsSection
            interfaceSettingsSection
            launchScreenSection
            pageAndThemeSections
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, DSSpacing.xxl * 2, for: .scrollContent)
        .themedAppSurface(for: .settings)
        .font(DSFont.body)
        .navigationTitle(localized("外觀主題"))
        .toolbarTitleDisplayMode(.inline)
        .tint(activeTheme.isClassic ? nil : activeTheme.accentColor)
        .preferredColorScheme(previewedAppearance)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionStore)
        }
        .navigationDestination(isPresented: $showCustomizer) {
            if let editingCustomThemeID {
                // Opens on the appearance you were editing, so a theme opened
                // from the 深色 tab lands on its dark colors.
                AppearanceThemeCustomizationView(
                    themeID: editingCustomThemeID,
                    initialScheme: editingScheme
                )
            }
        }
        .navigationDestination(isPresented: $showLaunchImageSettings) {
            LaunchImageSettingsView()
        }
        .sheet(isPresented: $showLaunchImagePaywall) {
            PaywallView(highlightedFeature: .launchScreen)
                .environmentObject(subscriptionStore)
        }
        .alert(
            localized("刪除此自訂主題？"),
            isPresented: Binding(
                get: { customThemeToDelete != nil },
                set: { if !$0 { customThemeToDelete = nil } }
            ),
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
        .sheet(
            isPresented: $showLegacyBackgroundImageChooser,
            onDismiss: presentLegacyBackgroundImageActionAfterChooserDismissal
        ) {
            DismissalSequencedActionChooser(
                title: localized("選擇"),
                actions: [
                    DismissalSequencedAction(
                        route: LegacyBackgroundImageAction.photos,
                        title: localized("從相簿選擇"),
                        systemImage: "photo.on.rectangle"
                    ),
                    DismissalSequencedAction(
                        route: LegacyBackgroundImageAction.files,
                        title: localized("從檔案選擇"),
                        systemImage: "folder"
                    ),
                ],
                onSelect: { route in
                    legacyBackgroundImageSequence.select(route)
                }
            )
        }
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

    private var themeSelectionSection: some View {
        Section {
            themeSelectionCard
            if !subscriptionStore.hasAccess(.readerThemePacks) {
                customizationRow
            }
        } header: {
            Text(localized("主題"))
        } footer: {
            if !subscriptionStore.hasAccess(.readerThemePacks) {
                Text(localized("自訂應用配色、閱讀配色與頁面背景需開通會員。"))
            }
        }
        .interfaceSectionSurface()
    }

    private var themeSwitchingSection: some View {
        Section {
            settingsToggleRow(
                title: localized("跟隨系統"),
                isOn: appearanceFollowsSystemBinding
            )
            settingsToggleRow(
                title: localized("單獨設定深色主題"),
                isOn: $settings.appearanceUsesSeparateDarkTheme
            )
            settingsToggleRow(
                title: localized("綁定閱讀主題"),
                isOn: $settings.appearanceBindReaderTheme
            )
            if settings.appearanceBindReaderTheme {
                boundReaderThemeRow(titleKey: "淺色閱讀主題", appearance: .light)
                boundReaderThemeRow(titleKey: "黑色閱讀主題", appearance: .dark)
            }
        } header: {
            Text(localized("主題切換"))
        } footer: {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized(
                    settings.appearanceFollowsSystem
                        ? "App 會依系統的淺色／深色，自動切換外觀。"
                        : "關閉後，切換系統深色模式不會影響 App 外觀。"
                ))
                Text(localized(
                    settings.appearanceBindReaderTheme
                        ? "閱讀器會依系統的淺色／深色，自動套用下面選的閱讀主題。"
                        : "關閉時，切換此外觀主題不會影響閱讀主題。"
                ))
            }
        }
        .interfaceSectionSurface()
        .animation(DSAnimation.standard, value: settings.appearanceBindReaderTheme)
    }

    private var readingSettingsSection: some View {
        Section {
            globalFontRow
            readerInterfaceRow
        } header: {
            Text(localized("閱讀設定"))
        }
        .interfaceSectionSurface()
    }

    private var interfaceSettingsSection: some View {
        Section {
            interfaceEffectsRow
            if ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive).showsBottomTabCustomization {
                rootTabRow
            }
        } header: {
            Text(localized("介面設定"))
        }
        .interfaceSectionSurface()
    }

    private var launchScreenSection: some View {
        Section {
            launchImageRow
        } header: {
            Text(localized("啟動畫面"))
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder
    private var pageAndThemeSections: some View {
        if subscriptionStore.hasAccess(.readerThemePacks) {
            Section {
                editScopeRow
                pageBackgroundColorRow(titleKey: "亮色主色調", scheme: .light, slot: .primary)
                pageBackgroundColorRow(titleKey: "亮色輔色調", scheme: .light, slot: .secondary)
                pageBackgroundColorRow(titleKey: "深色主色調", scheme: .dark, slot: .primary)
                pageBackgroundColorRow(titleKey: "深色輔色調", scheme: .dark, slot: .secondary)
                backgroundImagePickerRow(scheme: .light)
                if hasBackgroundImage(scheme: .light) {
                    backgroundImageOpacityRow(scheme: .light)
                }
                backgroundImagePickerRow(scheme: .dark)
                if hasBackgroundImage(scheme: .dark) {
                    backgroundImageOpacityRow(scheme: .dark)
                }
            } header: {
                Text(localized("頁面與主題"))
            }
            .interfaceSectionSurface()

            Section {
                pageBackgroundPreviewCard
            } header: {
                Text(localized("預覽"))
            }
            .interfaceSectionSurface()

            Section {
                themeActionRows
            } header: {
                Text(localized("主題管理"))
            }
            .interfaceSectionSurface()
        } else {
            Section {
                pageBackgroundLockedRow
            } header: {
                Text(localized("頁面與主題"))
            }
            .interfaceSectionSurface()
        }
    }

    private var themeSelectionCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            if settings.appearanceUsesSeparateDarkTheme {
                themeSlotPicker
            }
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
        .animation(DSAnimation.standard, value: settings.appearanceUsesSeparateDarkTheme)
    }

    /// Chooses which appearance the grid below is picking a theme for, and flips
    /// the app into it (see `previewedAppearance`) so the pick can be judged
    /// against the real thing. 深色 shows each theme's dark version, not one black
    /// theme.
    private var themeSlotPicker: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Picker(
                localized("主題外觀"),
                selection: Binding(
                    get: { editingScheme },
                    set: { themeSlot = $0 }
                )
            ) {
                Text(localized("淺色")).tag(ColorScheme.light)
                Text(localized("深色")).tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(localized("主題外觀"))

            Text(localized("深色分頁會以深色主題預覽整個介面，選的是同一批主題的深色版本。"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
        }
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
        // Preview in the appearance being edited: the dark slot shows this
        // theme's dark palette, which is what selecting it will apply.
        let displayed = preset.palette(for: editingScheme)
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
            settings.setAppearanceTheme(
                preset,
                for: editingScheme,
                activeAppearance: colorScheme
            )
        } label: {
            VStack(spacing: DSSpacing.sm) {
                ThemePreviewTile(
                    preset: displayed,
                    isSelected: selected,
                    isLocked: locked,
                    colorScheme: editingScheme
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
            // Copies the whole theme — both appearances — and lands in the slot
            // being edited, so creating from the 深色 tab does not silently
            // replace the light selection.
            let custom = settings.createCustomAppearanceTheme(
                from: selectedTheme,
                for: editingScheme
            )
            editingCustomThemeID = custom.id
            showCustomizer = true
        } label: {
            VStack(spacing: DSSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                        .fill(DSColor.textSecondary.opacity(0.2))
                    Image(systemName: subscriptionStore.hasAccess(.readerThemePacks) ? "plus" : "lock.fill")
                        .font(DSFont.fixed(size: 24, weight: .semibold))
                        .foregroundStyle(selectedTheme.palette(for: editingScheme).accentColor)
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

    private var appearanceFollowsSystemBinding: Binding<Bool> {
        Binding(
            get: { settings.appearanceFollowsSystem },
            set: {
                settings.setAppearanceFollowsSystem(
                    $0,
                    currentColorScheme: colorScheme
                )
            }
        )
    }

    /// One appearance's reading-theme pick, shown while 綁定閱讀主題 is on.
    private func boundReaderThemeRow(titleKey: String, appearance: ColorScheme) -> some View {
        let choice = settings.boundReaderTheme(for: appearance)
        return HStack {
            Text(localized(titleKey))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
            Spacer(minLength: DSSpacing.md)
            Menu {
                Picker(
                    localized(titleKey),
                    selection: Binding(
                        get: { settings.boundReaderTheme(for: appearance) },
                        set: { settings.setBoundReaderTheme($0, for: appearance) }
                    )
                ) {
                    ForEach(ReaderBoundTheme.menuOptions) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
            } label: {
                HStack(spacing: DSSpacing.xs) {
                    Text(choice.localizedTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(DSFont.caption.weight(.semibold))
                        // Decorative: without this VoiceOver reads the raw symbol
                        // name as its own element (docs/design.md §7.1).
                        .accessibilityHidden(true)
                }
                .font(DSFont.body)
                .foregroundStyle(DSColor.accent)
                // The label is the whole hit region of the menu, so it carries
                // the 44pt minimum rather than the row's padding.
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(localized(titleKey))
            .accessibilityValue(choice.localizedTitle)
        }
    }

    private func settingsToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
        }
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
            }
        }
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
            }
        }
    }

    private var interfaceEffectsRow: some View {
        NavigationLink {
            AppearanceInterfaceEffectsView()
        } label: {
            HStack {
                Text(localized("界面效果"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(interfaceEffectsSummary)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
    }

    /// Names whichever effects are on, so the row says something useful without
    /// opening it. Both off reads 已關閉.
    private var interfaceEffectsSummary: String {
        var parts: [String] = []
        if settings.interfaceGlowIntensity > 0 {
            parts.append(localized("光暈"))
        }
        if settings.interfaceFrostedGlass {
            parts.append(localized("毛玻璃"))
        }
        guard !parts.isEmpty else { return localized("已關閉") }
        // Locale-correct joiner ("光暈、毛玻璃" / "Glow, Frosted Glass") instead of a
        // hardcoded separator that only reads right in one language.
        return parts.formatted(.list(type: .and, width: .narrow))
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
                    .accessibilityHidden(true)
            }
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
            }
        }
    }

    // MARK: - 頁面背景 (page background editor)

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
                if let stored {
                    return Color(uiColor: AppearanceThemePreset.hex(stored))
                }
                if pageBackgroundScope != .global {
                    let globalConfig = settings.pageBackgroundConfig(for: .global)
                    let globalStored = slot == .primary
                        ? globalConfig.primaryHex(for: scheme)
                        : globalConfig.secondaryHex(for: scheme)
                    if let globalStored {
                        return Color(uiColor: AppearanceThemePreset.hex(globalStored))
                    }
                }
                return Color(uiColor: AppearanceThemePreset.hex(
                    Self.defaultPageBackgroundHex(scheme: scheme, slot: slot)
                ))
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

    private func hasBackgroundImage(scheme: ColorScheme) -> Bool {
        settings.pageBackgroundConfig(for: pageBackgroundScope).imageFileName(for: scheme) != nil
    }

    private func backgroundImagePickerRow(scheme: ColorScheme) -> some View {
        let titleKey = scheme == .dark ? "深色背景圖" : "亮色背景圖"
        let config = settings.pageBackgroundConfig(for: pageBackgroundScope)
        let fileName = config.imageFileName(for: scheme)
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
            if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
                HStack(spacing: DSSpacing.sm) {
                    Button {
                        backgroundImagePickScheme = scheme
                        legacyBackgroundImageSequence.cancel()
                        showLegacyBackgroundImageChooser = true
                    } label: {
                        Text(localized("選擇"))
                            .font(DSFont.subheadline.weight(.medium))
                            .foregroundStyle(DSColor.accent)
                            .padding(.horizontal, DSSpacing.md)
                            .padding(.vertical, DSSpacing.xs)
                            .background(DSColor.accent.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel(localized(titleKey))
                    if fileName != nil {
                        Button(role: .destructive) {
                            settings.clearPageBackgroundImage(
                                scope: pageBackgroundScope,
                                appearance: scheme
                            )
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(DSColor.destructive)
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel(localized("移除背景圖"))
                    }
                }
            } else {
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
                            .accessibilityHidden(true)
                    }
                    .font(DSFont.subheadline.weight(.medium))
                    .foregroundStyle(DSColor.accent)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.xs)
                    .background(DSColor.accent.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel(localized(titleKey))
            }
        }
    }

    private func backgroundImageOpacityRow(scheme: ColorScheme) -> some View {
        let titleKey = scheme == .dark ? "深色背景圖" : "亮色背景圖"
        return HStack(spacing: DSSpacing.md) {
            Text(localized("不透明度"))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
            Slider(value: imageOpacityBinding(scheme: scheme), in: 0...1, step: 0.05)
                .tint(DSColor.accent)
                .accessibilityLabel(
                    String(format: localized("%@ 不透明度"), localized(titleKey))
                )
                .accessibilityValue(imageOpacityPercentText(scheme: scheme))
            Text(imageOpacityPercentText(scheme: scheme))
                .font(DSFont.caption)
                .monospacedDigit()
                .foregroundStyle(DSColor.textSecondary)
                .frame(minWidth: DSLayout.minimumTapTarget, alignment: .trailing)
        }
    }

    private func imageOpacityBinding(scheme: ColorScheme) -> Binding<Double> {
        Binding(
            get: {
                let config = settings.pageBackgroundConfig(for: pageBackgroundScope)
                let stored = config.imageOpacity(for: scheme)
                if stored != 1.0 { return stored }
                if pageBackgroundScope != .global {
                    let globalConfig = settings.pageBackgroundConfig(for: .global)
                    let globalStored = globalConfig.imageOpacity(for: scheme)
                    if globalStored != 1.0 { return globalStored }
                }
                return 1.0
            },
            set: { value in
                var config = settings.pageBackgroundConfig(for: pageBackgroundScope)
                config.setImageOpacity(value, for: scheme)
                settings.updatePageBackgroundConfig(config, for: pageBackgroundScope)
            }
        )
    }

    private func presentLegacyBackgroundImageActionAfterChooserDismissal() {
        guard let action = legacyBackgroundImageSequence.consumeAfterDismissal() else {
            return
        }
        switch action {
        case .photos:
            showBackgroundPhotosPicker = true
        case .files:
            isImportingBackgroundFile = true
        }
    }

    private func imageOpacityDisplayValue(scheme: ColorScheme) -> Double {
        imageOpacityBinding(scheme: scheme).wrappedValue
    }

    /// The one source for both the printed percentage and the slider's VoiceOver
    /// value, so what is spoken can never drift from what is shown.
    private func imageOpacityPercentText(scheme: ColorScheme) -> String {
        String(format: "%.0f%%", imageOpacityDisplayValue(scheme: scheme) * 100)
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
                DSColor.groupedBackground
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
        .shadow(color: Color.primary.opacity(0.15), radius: 16, x: 0, y: 6)
        .overlay {
            RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.5),
                            .clear,
                            .black.opacity(0.15)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
                .blur(radius: 2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Theme actions (save / export / import / reset)

    @ViewBuilder
    private var themeActionRows: some View {
        themeActionRow(titleKey: "保存為新主題") {
            newThemeName = ""
            showSaveThemeAlert = true
        }
        .alert(localized("保存為新主題"), isPresented: $showSaveThemeAlert) {
            TextField(localized("主題名稱"), text: $newThemeName)
            Button(localized("保存")) {
                settings.saveCurrentAppearanceAsTheme(
                    named: newThemeName,
                    basedOn: selectedTheme,
                    for: editingScheme
                )
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("將當前配色與頁面背景保存為自訂主題。"))
        }

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

        themeActionRow(titleKey: "導入主題") {
            showThemeImporter = true
        }
        .fileImporter(
            isPresented: $showThemeImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleThemeImport
        )

        themeActionRow(titleKey: "重置為默認") {
            showResetPageBackgroundConfirm = true
        }
        .alert(
            localized("重置為默認？"),
            isPresented: $showResetPageBackgroundConfirm
        ) {
            Button(localized("重置為默認"), role: .destructive) {
                settings.resetAllPageBackgrounds()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("將清除所有頁面（含各分頁）的背景顏色與背景圖設定。"))
        }
    }

    private func themeActionRow(titleKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(localized(titleKey))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Free-user entry: same row shape as the Pro editor's rows.
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
                    .accessibilityHidden(true)
            }
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
    private var customizationRow: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "crown.fill")
                    .font(DSFont.headline)
                    .foregroundStyle(activeTheme.accentColor)
                    .accessibilityHidden(true)
                Text(localized("主題自定義"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
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
            .interfaceSectionSurface()
        }
        .font(DSFont.body)
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("閱讀界面"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }
}

private struct AppearanceThemeCustomizationView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    let themeID: String
    /// Appearance being edited. Unlike the theme grid this is always explicit —
    /// a custom theme owns both palettes, so there is no "follow the device".
    @State private var editingScheme: ColorScheme

    init(themeID: String, initialScheme: ColorScheme = .light) {
        self.themeID = themeID
        _editingScheme = State(initialValue: initialScheme)
    }

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
                    Picker(localized("主題外觀"), selection: $editingScheme) {
                        Text(localized("淺色")).tag(ColorScheme.light)
                        Text(localized("深色")).tag(ColorScheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(localized("主題外觀"))

                    if editingScheme == .light {
                        lightColorPickers(theme)
                    } else {
                        darkColorSection(theme)
                    }
                } header: {
                    Text(localized("主題自定義"))
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.textPrimary)
                }
                .interfaceSectionSurface()

                Section {
                    ThemePreviewTile(
                        preset: AppearanceThemePreset
                            .preset(from: theme.wrappedValue)
                            .palette(for: editingScheme),
                        isSelected: true,
                        isLocked: false,
                        colorScheme: editingScheme
                    )
                    .frame(maxWidth: 180)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Text(localized("找不到主題"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .interfaceSectionSurface()
            }
        }
        .font(DSFont.body)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        // Same rule as the theme grid: the appearance being edited is the
        // appearance shown, so the colors can be judged where they will live.
        .preferredColorScheme(editingScheme)
        .animation(DSAnimation.standard, value: editingScheme)
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

    @ViewBuilder
    private func lightColorPickers(_ theme: Binding<AppearanceCustomTheme>) -> some View {
        themeColorPicker("主色", selection: colorBinding(theme, \.accentHex))
        themeColorPicker("背景", selection: colorBinding(theme, \.backgroundHex))
        themeColorPicker("文字", selection: colorBinding(theme, \.textHex))
        themeColorPicker("工具列", selection: colorBinding(theme, \.barHex))
        themeColorPicker("對話高亮", selection: colorBinding(theme, \.dialogueHex))
    }

    /// Dark tab: automatic by default (colors derived from the light palette),
    /// with the pickers appearing only once the user takes it over. Switching
    /// the toggle off seeds them with what the derivation produced, so the first
    /// thing they see is what they were already looking at.
    @ViewBuilder
    private func darkColorSection(_ theme: Binding<AppearanceCustomTheme>) -> some View {
        Toggle(isOn: automaticDarkBinding(theme)) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized("自動深色配色"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Text(localized("關閉後可單獨指定這個主題的深色配色。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }

        if theme.wrappedValue.dark != nil {
            themeColorPicker("主色", selection: darkColorBinding(theme, \.accentHex))
            themeColorPicker("背景", selection: darkColorBinding(theme, \.backgroundHex))
            themeColorPicker("文字", selection: darkColorBinding(theme, \.textHex))
            themeColorPicker("工具列", selection: darkColorBinding(theme, \.barHex))
            themeColorPicker("對話高亮", selection: darkColorBinding(theme, \.dialogueHex))
        }
    }

    private func automaticDarkBinding(
        _ theme: Binding<AppearanceCustomTheme>
    ) -> Binding<Bool> {
        Binding(
            get: { theme.wrappedValue.dark == nil },
            set: { isAutomatic in
                var copy = theme.wrappedValue
                copy.dark = isAutomatic ? nil : Self.derivedDarkColors(of: copy)
                theme.wrappedValue = copy
            }
        )
    }

    /// What the automatic derivation currently produces for this theme, in
    /// storage form — the seed for hand editing.
    private static func derivedDarkColors(
        of theme: AppearanceCustomTheme
    ) -> AppearanceCustomThemeDarkColors {
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

    /// Same as `colorBinding`, on the optional dark palette. Only reachable
    /// while it exists (the pickers are hidden under 自動深色配色), so a missing
    /// palette reads as the derived value and writes seed one.
    private func darkColorBinding(
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

#Preview("主題自定義 · 深色") {
    let settings = GlobalSettings.shared
    let theme = settings.customAppearanceThemes.first
        ?? settings.createCustomAppearanceTheme(from: AppearanceThemePreset.freeSolidPresets[0])
    return NavigationStack {
        AppearanceThemeCustomizationView(themeID: theme.id, initialScheme: .dark)
    }
}
