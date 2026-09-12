import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One screen-level message alert, so the import-failure and import-summary
/// paths share a presenter instead of competing for one.
struct ThemeScreenAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct AppearanceThemeView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showPaywall = false
    @State private var showCustomizer = false
    @State private var editingCustomThemeID: String?
    @State private var showLaunchImageSettings = false
    @State private var showLaunchImagePaywall = false

    // 頁面背景 editor state.
    @State private var pageBackgroundScope: AppearancePageBackgroundScope = .global
    @State private var showSaveThemeAlert = false
    @State private var newThemeName = ""
    @State private var showThemeImporter = false
    @State private var showResetPageBackgroundConfirm = false
    @State private var screenAlert: ThemeScreenAlert?
    /// A parsed QiReader pack waiting on the user's answer about replacing their
    /// hand-placed header/footer widgets. Held here rather than applied immediately so
    /// the question is asked *after* the file parsed and *before* anything lands — the
    /// same contract 匯入閱讀設定 uses.
    @State private var pendingQiTheme: PendingQiThemeImport?
    /// Appearance slot the theme grid edits, once the user picks one by hand.
    /// nil means "whatever the device is showing", which is also the only
    /// behaviour available while 單獨設定深色主題 is off.
    @State private var themeSlot: ColorScheme?

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
        .navigationTitle(localized("外觀主題"))
        .toolbarTitleDisplayMode(.inline)
        .tint(activeTheme.isClassic ? nil : activeTheme.accentColor)
        .preferredColorScheme(previewedAppearance)
        // The 淺色／深色 slot picker must repaint this screen as the edited
        // appearance so theme picks can be judged where they will live. In
        // practice `.preferredColorScheme` alone does not flip the environment
        // `colorScheme` on pushed List destinations (iOS 18/26 flakiness), and
        // `setAppearanceTheme` guards `slot == activeAppearance` — with the
        // environment still reading the device scheme, every dark-slot pick
        // returned before repainting (the "深色分頁點主題不變色" bug). Overriding
        // the environment value directly is the reliable path; `AudiobookView`
        // uses the same technique for its scoped dark page.
        .environment(\.colorScheme, editingScheme)
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
        // One alert modifier for the whole screen. Stacking several `.alert`s on
        // the same view is how one of them silently stops presenting — they all
        // compete for the same presenter.
        .alert(
            screenAlert?.title ?? "",
            isPresented: Binding(
                get: { screenAlert != nil },
                set: { if !$0 { screenAlert = nil } }
            ),
            presenting: screenAlert
        ) { _ in
            Button(localized("確定"), role: .cancel) {
                screenAlert = nil
            }
        } message: { alert in
            Text(alert.message)
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
                    .dsSectionFooter()
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
            .dsSectionFooter()
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
        } else {
            Section {
                pageBackgroundLockedRow
            } header: {
                Text(localized("頁面與主題"))
            }
            .interfaceSectionSurface()
        }

        // Deliberately outside the Pro gate. An appearance pack — ours or a QiReader
        // `.qitheme` — mostly carries things that are not Pro features at all: page
        // backgrounds, tab icons, default covers, the bundled font, interface effects,
        // reader layout, chapter title and comment bubble. Hiding the importer meant a
        // non-Pro user handed a pack had no way to open it, and no explanation either.
        // The custom theme a pack carries still needs Pro to take effect; `ContentView`'s
        // `resolvedAppTheme` already downgrades it on its own, so nothing here has to.
        Section {
            themeActionRows
        } header: {
            Text(localized("主題管理"))
        }
        .interfaceSectionSurface()
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
                // The screen is repainted as `editingScheme` by the environment
                // override above, so that is the appearance actually on screen —
                // not the device scheme, whose trait sync with the override is
                // not guaranteed to have happened by the time this tap runs.
                activeAppearance: editingScheme
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
        // Plain buttons only. A `ShareLink` placed in here took the menu over —
        // the tile's long-press showed the share item and the system's own
        // suggestion, and 編輯 / 刪除 were never drawn, which is what made custom
        // themes look undeletable. Per-theme export lives in the editor instead.
        .contextMenu {
            if preset.isCustom, !locked {
                Button {
                    editingCustomThemeID = preset.id
                    showCustomizer = true
                } label: {
                    Label(localized("編輯"), systemImage: "slider.horizontal.3")
                }
                // Only for an imported pack that the write-back has since edited;
                // a theme built here has no author's version to return to.
                if settings.canResetCustomAppearanceTheme(id: preset.id) {
                    Menu {
                        Button(role: .destructive) {
                            settings.resetCustomAppearanceTheme(id: preset.id)
                        } label: {
                            Label(
                                localized("還原主題包原始設定"),
                                systemImage: "arrow.uturn.backward"
                            )
                        }
                    } label: {
                        Label(localized("重置此主題"), systemImage: "arrow.uturn.backward")
                    }
                }
                // The confirmation is a nested menu rather than an alert: a modal
                // raised from a context-menu action is launched while the menu's
                // UIKit controller is dismissing, which iOS 17 can drop
                // (Technotes/iOS17MenuModalPresentation.md). A submenu stays
                // inside the one menu presentation and still takes two taps.
                Menu {
                    Button(role: .destructive) {
                        settings.deleteCustomAppearanceTheme(id: preset.id)
                    } label: {
                        Label(
                            String(format: localized("刪除「%@」"), preset.localizedName),
                            systemImage: "trash"
                        )
                    }
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
            ImageSourcePickerButton(
                accessibilityTitle: localized(titleKey),
                extraActions: fileName == nil ? [] : [
                    ImageSourcePickerAction(
                        title: localized("移除背景圖"),
                        systemImage: "trash",
                        isDestructive: true,
                        action: {
                            settings.clearPageBackgroundImage(
                                scope: pageBackgroundScope,
                                appearance: scheme
                            )
                        }
                    )
                ],
                onPick: { result in handleBackgroundPick(result, for: scheme) }
            )
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

        ShareLink(
            item: exportPayload(for: selectedTheme),
            preview: SharePreview(selectedTheme.localizedName)
        ) {
            HStack {
                Text(localized("導出主題"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("導出主題"))

        ShareLink(
            item: fullCustomizationPayload,
            preview: SharePreview(localized("導出全部自定義"))
        ) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized("導出全部自定義"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Text(localized("包含主題、頁面背景圖、Tab 圖示、啟動圖與閱讀背景。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("導出全部自定義"))

        themeActionRow(titleKey: "導入主題") {
            showThemeImporter = true
        }
        .fileImporter(
            isPresented: $showThemeImporter,
            allowedContentTypes: [
                .json,
                .yueduReaderStyle,
                UTType(filenameExtension: "qitheme") ?? .data,
            ],
            allowsMultipleSelection: false,
            onCompletion: handleThemeImport
        )
        .alert(
            localized("套用匯入的頁首頁尾？"),
            isPresented: Binding(
                get: { pendingQiTheme != nil },
                set: { if !$0 { pendingQiTheme = nil } }
            ),
            presenting: pendingQiTheme
        ) { pending in
            Button(localized("套用")) {
                pendingQiTheme = nil
                applyQiTheme(pending.theme, includeOverlayLayout: true)
            }
            Button(localized("略過")) {
                pendingQiTheme = nil
                applyQiTheme(pending.theme, includeOverlayLayout: false)
            }
        } message: { _ in
            Text(localized("這會取代目前的頁首頁尾組件、位置與正文保留空間。選擇「略過」會匯入外觀包的其他部分。"))
        }

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

    /// Cheap to build (colors + background file names), so it is safe to
    /// construct in a menu row — see `AppearanceThemeExportPayload`.
    private func exportPayload(for preset: AppearanceThemePreset) -> AppearanceThemeExportPayload {
        AppearanceThemeExportPayload(
            filename: AppearanceThemeExportPayload.filename(for: preset.localizedName),
            themes: [settings.appearanceThemeExportSnapshot(for: preset)]
        )
    }

    /// Cheap for the same reason: file names now, bytes at share time.
    private var fullCustomizationPayload: AppearanceCustomizationExportPayload {
        AppearanceCustomizationExportPayload(
            filename: AppearanceCustomizationExportPayload.filename(for: localized("全部自定義")),
            snapshot: settings.appearanceCustomizationSnapshot()
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

    private func handleBackgroundPick(
        _ result: Result<PickedImageSource, PickedImageError>,
        for scheme: ColorScheme
    ) {
        let scope = pageBackgroundScope
        do {
            switch result {
            case .success(.data(let data)):
                try settings.importPageBackgroundImage(data: data, scope: scope, appearance: scheme)
            case .success(.file(let url)):
                try settings.importPageBackgroundImage(from: url, scope: scope, appearance: scheme)
            case .failure(let error):
                showImportFailure(localized(error.messageKey))
            }
        } catch let error as AppearancePageBackgroundImageError {
            showImportFailure(localized(error.messageKey))
        } catch {
            showImportFailure(localized("無法讀取圖片。"))
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
            if QiThemeImporter.hasQiThemeExtension(url) {
                handleQiThemeImport(data)
                return
            }
            Task { @MainActor in
                do {
                    let summary = try await settings.importAppearanceCustomizationPackage(from: data)
                    screenAlert = ThemeScreenAlert(
                        title: localized("導入主題"),
                        message: summary.localizedDescription
                    )
                } catch let error as AppearanceThemeImportError {
                    showImportFailure(localized(error.messageKey))
                } catch {
                    showImportFailure(localized("匯入主題失敗。"))
                }
            }
        } catch let error as AppearanceThemeImportError {
            showImportFailure(localized(error.messageKey))
        } catch {
            showImportFailure(localized("匯入主題失敗。"))
        }
    }

    /// QiReader packs are a foreign archive: their manifest lives under a UUID directory,
    /// so `ReaderStylePackage` cannot read them and they get their own parse before any of
    /// the native routes are tried.
    private func handleQiThemeImport(_ data: Data) {
        Task { @MainActor in
            do {
                let theme = try await QiThemeImportService.load(data)
                if theme.overlayLayout != nil {
                    pendingQiTheme = PendingQiThemeImport(theme: theme)
                } else {
                    applyQiTheme(theme, includeOverlayLayout: false)
                }
            } catch let error as QiThemeImportError {
                showImportFailure(error.errorDescription ?? localized("匯入主題失敗。"))
            } catch {
                showImportFailure(localized("匯入主題失敗。"))
            }
        }
    }

    private func applyQiTheme(_ theme: QiThemeImport, includeOverlayLayout: Bool) {
        Task { @MainActor in
            do {
                let outcome = try await QiThemeImportService.apply(
                    theme,
                    includeOverlayLayout: includeOverlayLayout
                )
                screenAlert = ThemeScreenAlert(
                    title: localized("導入主題"),
                    message: outcome.localizedDescription
                )
            } catch {
                showImportFailure(localized("匯入主題失敗。"))
            }
        }
    }

    private func showImportFailure(_ message: String) {
        screenAlert = ThemeScreenAlert(title: localized("匯入失敗"), message: message)
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

    /// The reading background the reader is currently painting with, so the preview
    /// shows the chrome against the surface it will actually sit on. Read once per
    /// body pass: the reading background can only change from inside the reader, which
    /// this page is never on screen for.
    private var previewTheme: ReaderTheme { ReaderTheme.loadPersisted() }

    /// nil for Apple Books, which renders through system toolbars and has no surface
    /// of its own to recolor — that is exactly when the 自定義 section is absent.
    private var customizableInterface: ReaderChromeInterface? {
        ReaderChromeInterface(settings.appearanceReaderInterface)
    }

    private func palette(for interface: ReaderChromeInterface) -> ReaderChromePalette {
        ReaderChromePalette(interface: interface, theme: previewTheme, settings: settings)
    }

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
                // The label repeated the page title one row further down. The section
                // header carries the name now; VoiceOver still hears it because
                // `accessibilityLabel` restates it on the control itself.
                .labelsHidden()
                .accessibilityLabel(localized("閱讀界面"))
            } header: {
                Text(localized("閱讀界面"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
            } footer: {
                Text(localized("選擇閱讀界面的工具列與控制方式。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            if let interface = customizableInterface {
                customizationSection(for: interface)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("閱讀界面"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    /// Only the slots the chosen interface actually paints — 現代's navigation bar is
    /// system glass with no fill of ours, and only 經典 floats circles over the page.
    private func customizationSection(for interface: ReaderChromeInterface) -> some View {
        Section {
            chromePreview(for: interface)

            ForEach(ReaderChromeSlot.slots(for: interface)) { slot in
                colorRow(slot, interface: interface)
            }

            NavigationLink {
                ReaderChromeIconSettingsView()
            } label: {
                HStack {
                    Text(localized("按鈕圖示"))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                    Spacer(minLength: DSSpacing.md)
                    Text(iconSummary)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }

            if settings.hasReaderChromeOverride(interface: interface) {
                Button {
                    settings.resetReaderChrome(interface: interface)
                } label: {
                    Label(localized("跟隨閱讀主題"), systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text(localized("自定義"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
        } footer: {
            Text(localized(interface == .classic
                ? "頂部是返回／書籤那條，底部是進度條與工具列，中間四顆圓鈕是刷新／換源／下載／聽書。強調色用在進度條和「深色」的選中狀態。未調整的部分跟隨目前的閱讀主題。"
                : "現代的頂欄是系統玻璃，只能改圖示顏色；底部是浮動面板，書卡是點封面圓圈之後那張。未調整的部分跟隨目前的閱讀主題。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// 目錄／書籤／深色／設置 and 刷新／換源／下載／聽書 status, so the row says
    /// something without opening it.
    private var iconSummary: String {
        let custom = settings.readerChromeIcons.count
        let hidden = settings.readerChromeHiddenIDs.count
        var parts: [String] = []
        if custom > 0 { parts.append(String(format: localized("已換 %d 個"), custom)) }
        if hidden > 0 { parts.append(String(format: localized("已隱藏 %d 個"), hidden)) }
        guard !parts.isEmpty else { return localized("預設") }
        return parts.formatted(.list(type: .and, width: .narrow))
    }

    private func colorRow(_ slot: ReaderChromeSlot, interface: ReaderChromeInterface) -> some View {
        ColorPicker(selection: colorBinding(slot, interface: interface), supportsOpacity: false) {
            Text(localized(slot.titleKey))
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
        }
    }

    /// Opens on the colour that is on screen right now rather than a blank swatch,
    /// the same contract as the reader's 文字顏色 picker. Writing one stores an
    /// override; clearing every override is the 跟隨閱讀主題 button, not a colour.
    private func colorBinding(
        _ slot: ReaderChromeSlot,
        interface: ReaderChromeInterface
    ) -> Binding<Color> {
        Binding(
            get: { palette(for: interface).color(for: slot) },
            set: { settings.setReaderChromeColor(UIColor($0).rgbHex, interface: interface, slot: slot) }
        )
    }

    /// The real chrome, drawn with the real palette on the real reading background —
    /// the section is about how the reader looks, so swatches would not answer the
    /// only question anyone has here.
    @ViewBuilder
    private func chromePreview(for interface: ReaderChromeInterface) -> some View {
        let palette = palette(for: interface)
        VStack(spacing: 0) {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "chevron.left")
                Spacer(minLength: 0)
                if interface == .modern {
                    Circle()
                        .fill(palette.panelFill)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(palette.topIcon.opacity(0.25), lineWidth: 0.5))
                } else {
                    Image(systemName: "bookmark")
                    Image(systemName: "ellipsis")
                }
            }
            .font(DSFont.fixed(size: 13, weight: .medium))
            .foregroundStyle(palette.topIcon)
            .padding(.horizontal, DSSpacing.md)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(interface == .classic ? palette.topFill : previewTheme.backgroundColor)

            ZStack(alignment: .bottom) {
                previewTheme.backgroundColor
                    .frame(height: interface == .classic ? 44 : 24)

                if interface == .classic {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        ForEach(visiblePreviewActions, id: \.self) { item in
                            previewActionGlyph(item, palette: palette)
                        }
                    }
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.bottom, DSSpacing.sm)
                }
            }

            bottomPreview(interface: interface, palette: palette)
        }
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        // One decorative element: VoiceOver gets the values from the rows below,
        // not from a stack of unlabelled symbols.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bottomPreview(
        interface: ReaderChromeInterface,
        palette: ReaderChromePalette
    ) -> some View {
        let bar = VStack(spacing: DSSpacing.sm) {
            Capsule()
                .fill(palette.bottomAccent)
                .frame(height: 3)
            HStack(spacing: 0) {
                ForEach(settings.visibleReaderChromeToolItems) { item in
                    previewToolGlyph(for: item, palette: palette)
                }
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)

        switch interface {
        case .classic:
            bar
                .frame(maxWidth: .infinity)
                .background(palette.bottomFill)
        case .modern:
            // 現代's bottom bar floats, inset from every edge, over the page.
            bar
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                        .fill(palette.bottomFill)
                )
                .padding(DSSpacing.sm)
                .frame(maxWidth: .infinity)
                .background(previewTheme.backgroundColor)
        }
    }

    /// Only the actions that are both applicable in general and switched on — the
    /// preview should not advertise a button the reader has hidden.
    private var visiblePreviewActions: [ReaderChromeActionItem] {
        ReaderChromeActionItem.allCases.filter { settings.isReaderChromeItemVisible($0) }
    }

    @ViewBuilder
    private func previewActionGlyph(
        _ item: ReaderChromeActionItem,
        palette: ReaderChromePalette
    ) -> some View {
        Group {
            if let image = settings.readerChromeIconImage(for: item) {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: item.defaultSystemImage)
                    .font(DSFont.fixed(size: 11))
                    .foregroundStyle(palette.circleIcon)
            }
        }
        .frame(width: 24, height: 24)
        .background(palette.circleFill, in: Circle())
        .overlay(Circle().stroke(palette.circleBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func previewToolGlyph(
        for item: ReaderChromeToolItem,
        palette: ReaderChromePalette
    ) -> some View {
        Group {
            if let image = settings.readerChromeIconImage(for: item) {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: item.systemImage(isNight: previewTheme == .night))
                    .font(DSFont.fixed(size: 14))
                    .foregroundStyle(palette.bottomIcon)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AppearanceThemeCustomizationView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    let themeID: String
    /// Appearance being edited. Unlike the theme grid this is always explicit —
    /// a custom theme owns both palettes, so there is no "follow the device".
    @State private var editingScheme: ColorScheme
    @State private var showDeleteConfirmation = false

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

                // This theme's own actions. Export is a row rather than a
                // long-press menu item because a `ShareLink` inside a context
                // menu takes the whole menu over (see the theme grid).
                Section {
                    ShareLink(
                        item: AppearanceThemeExportPayload(
                            filename: AppearanceThemeExportPayload.filename(
                                for: theme.wrappedValue.name
                            ),
                            themes: [theme.wrappedValue]
                        ),
                        preview: SharePreview(theme.wrappedValue.name)
                    ) {
                        Label(localized("導出主題"), systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(localized("刪除主題"), systemImage: "trash")
                            .foregroundStyle(DSColor.destructive)
                    }
                } footer: {
                    Text(localized("刪除後，使用此主題的外觀會回到預設。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            } else {
                Text(localized("找不到主題"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .interfaceSectionSurface()
            }
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        // Same rule as the theme grid: the appearance being edited is the
        // appearance shown, so the colors can be judged where they will live.
        // `.preferredColorScheme` alone leaves the environment reading the
        // device scheme on pushed destinations; overriding the environment
        // value is what actually repaints the Form (see the theme grid).
        .preferredColorScheme(editingScheme)
        .environment(\.colorScheme, editingScheme)
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
        // Attached to the Form, not to the delete Section: confirming removes
        // the theme, which removes that Section, and an alert torn down by its
        // own action is a presentation that can be left half-dismissed.
        .alert(
            localized("刪除此自訂主題？"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(localized("刪除"), role: .destructive) {
                settings.deleteCustomAppearanceTheme(id: themeID)
                dismiss()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(themeBinding?.wrappedValue.name ?? "")
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

#Preview {
    NavigationStack {
        AppearanceThemeView()
            .environmentObject(SubscriptionStore.shared)
    }
}

#Preview("閱讀界面") {
    NavigationStack {
        AppearanceReaderInterfaceView()
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

/// A parsed QiReader pack held between the overlay-overwrite question and the apply.
struct PendingQiThemeImport: Identifiable {
    let id = UUID()
    let theme: QiThemeImport
}
