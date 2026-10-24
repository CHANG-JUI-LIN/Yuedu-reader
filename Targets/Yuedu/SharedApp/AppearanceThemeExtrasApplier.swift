import Foundation
import SwiftUI

/// Applies the non-colour half of an appearance theme, keeps it up to date while
/// that theme is selected, and puts the user's own settings back when they leave it.
///
/// Before this existed, importing an appearance pack scattered its contents across
/// a dozen independent `GlobalSettings` keys, so selecting 默認 again reverted the
/// five theme colours and nothing else: the pack's tab icons, font, covers, glass
/// and bookshelf layout stayed put with no way to undo them.
///
/// Two mechanisms, both funnelled through `AppearanceThemeExtras`:
///
/// 1. **A baseline, not a per-setting override**, so no read site has to learn about
///    themes: the first time a custom theme is selected the user's own values are
///    captured, and selecting a theme that speaks for nothing writes that capture
///    back. Switching straight from one theme to another keeps the original
///    baseline, so the way out is always the way in.
/// 2. **Write-back while a theme is selected.** Editing a covered setting records it
///    on the selected theme (`updateActiveThemeExtras`), which is what makes each
///    theme keep its own covers, font and icons instead of leaving the change on
///    whichever theme happens to be selected next. The write is per field, so a
///    pack keeps saying nothing about the settings the user never touched.
extension GlobalSettings {
    private static let extrasBaselineKey = "yd_appearance_extras_baseline"

    /// The user's own values from before the first theme was applied, or nil when no
    /// custom theme is selected.
    var appearanceExtrasBaseline: AppearanceThemeExtras? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.extrasBaselineKey) else {
                return nil
            }
            return try? JSONDecoder().decode(AppearanceThemeExtras.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: Self.extrasBaselineKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Self.extrasBaselineKey)
        }
    }

    /// The custom theme on screen, if any — see `onScreenAppearanceThemeID`.
    ///
    /// It used to be the light slot's custom theme, else the dark slot's: a built-in in
    /// one slot did not cancel the other. So with 默認 picked for light and a pack for
    /// dark, the pack's page backgrounds, icons, font and reading setup stayed on in
    /// light mode as well — and even after 單獨設定深色主題 was turned off (2026-09-29).
    ///
    /// Deliberately *not* gated on the theme already carrying extras: a colour-only
    /// theme has to be able to acquire its first one when the user edits something.
    var activeExtrasOwnerThemeID: String? {
        let id = onScreenAppearanceThemeID
        return customAppearanceThemes.contains(where: { $0.id == id }) ? id : nil
    }

    /// The theme selected for the appearance on screen: the dark slot's while
    /// 單獨設定深色主題 is on and the app is dark, the light slot's otherwise.
    var onScreenAppearanceThemeID: String {
        appearanceUsesSeparateDarkTheme && appearanceOnScreen == .dark
            ? appearanceDarkThemeID
            : appearanceThemeID
    }

    /// The appearance the scene shows, as it changes and as the scene comes back from the
    /// background. Not in the background, where the light／dark is the app-switcher
    /// snapshots' (`ScenePhase.showsDeviceAppearance`): each snapshot used to wear the other
    /// appearance's theme and reading setup, and lay the open book out for it.
    func noteAppearanceOnScreen(_ scheme: ColorScheme, in phase: ScenePhase) {
        guard phase.showsDeviceAppearance else { return }
        let onScreen = AppearanceColorScheme(scheme)
        guard appearanceOnScreen != onScreen else { return }
        AppLogger.info("⟐ appearance on screen \(appearanceOnScreen.rawValue) → \(onScreen.rawValue) phase=\(phase)")
        appearanceOnScreen = onScreen
    }

    /// The extras in force, or nil when the selected theme speaks for nothing.
    var activeAppearanceThemeExtras: AppearanceThemeExtras? {
        guard let id = activeExtrasOwnerThemeID,
              let extras = customAppearanceThemes.first(where: { $0.id == id })?.extras,
              !extras.isEmpty else {
            return nil
        }
        return extras
    }

    /// Called whenever the selected theme changes, and once at launch so the
    /// invariant "a custom theme is selected ⟹ a baseline exists" holds even for
    /// themes saved before write-back existed. Cheap and idempotent.
    func synchronizeAppearanceThemeExtras() {
        // Every write below lands in a `didSet` that would otherwise write straight
        // back into the theme being applied — restoring the baseline would overwrite
        // the very extras this call is installing.
        let wasApplying = isApplyingAppearanceExtras
        isApplyingAppearanceExtras = true
        defer { isApplyingAppearanceExtras = wasApplying }

        // Read before anything below is written: the first read captures the user's own
        // reading setup, which the baseline may still hold from before 排版生效範圍.
        _ = globalReadingSettings

        if activeExtrasOwnerThemeID != nil {
            if appearanceExtrasBaseline == nil {
                appearanceExtrasBaseline = currentAppearanceExtrasSnapshot()
            }
            // A theme is a sparse override of the user's original settings, not of
            // the preceding theme. Restore first so omitted fields cannot carry
            // another theme's font, icons or effects into this one.
            if let baseline = appearanceExtrasBaseline {
                writeAppearanceExtras(baseline)
            }
            if let extras = activeAppearanceThemeExtras {
                writeAppearanceExtras(extras)
            }
        } else if let baseline = appearanceExtrasBaseline {
            writeAppearanceExtras(baseline)
            appearanceExtrasBaseline = nil
        }

        // Reading settings are not part of the baseline: they have their own shared
        // setup, and 排版生效範圍 decides which of them this theme's values replace.
        synchronizeReadingSettings()
    }

    /// Records one edited setting on the selected theme. Every covered `didSet`
    /// calls this; it is a no-op while a theme is being applied, and while a
    /// built-in preset is selected (there is nothing user-owned to write to).
    ///
    /// Per field rather than a whole snapshot on purpose: an imported pack that says
    /// nothing about, say, covers must keep saying nothing about them after the user
    /// changes the font, or one edit would silently pin every other setting to
    /// whatever the baseline happened to be.
    func updateActiveThemeExtras(_ mutate: (inout AppearanceThemeExtras) -> Void) {
        guard !isApplyingAppearanceExtras,
              let id = activeExtrasOwnerThemeID,
              let index = customAppearanceThemes.firstIndex(where: { $0.id == id }) else {
            return
        }
        var extras = customAppearanceThemes[index].extras ?? AppearanceThemeExtras()
        mutate(&extras)
        guard customAppearanceThemes[index].extras != extras else { return }
        customAppearanceThemes[index].extras = extras
    }

    /// Every field filled in. Used for the baseline (so restoring it sets all of
    /// them back) and by 保存為新主題, where the user is explicitly saying "this whole
    /// look is the theme".
    func currentAppearanceExtrasSnapshot() -> AppearanceThemeExtras {
        var snapshot = AppearanceThemeExtras()
        snapshot.tabIcons = Dictionary(
            uniqueKeysWithValues: rootTabIconAssets.map {
                ("\($0.tabID).\($0.slotRawValue)", $0.fileName)
            }
        )
        snapshot.tabIconSize = rootTabIconSize
        snapshot.hidesTabLabels = rootTabHidesLabels
        snapshot.visibleTabIDs = rootTabVisibleIDs
        snapshot.launchImageEnabled = launchImageEnabled
        snapshot.launchImageLightFileName = launchImageLightFileName ?? ""
        snapshot.launchImageDarkFileName = launchImageDarkFileName ?? ""
        snapshot.defaultCoverLightFileNames = defaultCoverLightFileNames
        snapshot.defaultCoverDarkFileNames = defaultCoverDarkFileNames
        snapshot.forceDefaultCover = useDefaultCoverForAllBooks
        snapshot.globalFontPostScript = selectedGlobalFontPostScript ?? ""
        snapshot.frostedGlass = interfaceFrostedGlass
        snapshot.glassTransparency = interfaceGlassTransparency
        snapshot.glowIntensity = interfaceGlowIntensity
        snapshot.glowColor = interfaceGlowColor
        snapshot.glassCards = interfaceGlassCards
        snapshot.bookshelfGridColumnCount = bookshelfGridColumnCount
        snapshot.bookshelfCoverCornerRadius = bookshelfCoverCornerRadius
        snapshot.cardBackground = appearanceCardBackground
        snapshot.pageBackgrounds = appearancePageBackgrounds
        snapshot.readerChromeColors = readerChromeColors
        snapshot.readerChromeHiddenIDs = readerChromeHiddenIDs
        snapshot.readerChromeIcons = Dictionary(
            readerChromeIcons.map { ($0.itemID, $0.fileName) },
            uniquingKeysWith: { _, last in last }
        )
        return snapshot
    }

    private func writeAppearanceExtras(_ extras: AppearanceThemeExtras) {
        if let icons = extras.tabIcons {
            // Assigned directly rather than through `importRootTabIcon`, which deletes the
            // icon it replaces — that would destroy the user's own artwork the first time a
            // theme was applied and leave the baseline pointing at files that no longer exist.
            rootTabIconAssets = icons.compactMap { key, fileName in
                let parts = key.split(separator: ".", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return RootTabIconAsset(
                    tabID: String(parts[0]),
                    slotRawValue: String(parts[1]),
                    fileName: fileName,
                    originalFileName: fileName,
                    addedAt: Date()
                )
            }
            .sorted { ($0.tabID, $0.slotRawValue) < ($1.tabID, $1.slotRawValue) }
        }
        if let size = extras.tabIconSize { rootTabIconSize = size }
        if let hidden = extras.hidesTabLabels { rootTabHidesLabels = hidden }
        // Assigned raw: the property's own `didSet` sanitizes, so a theme that names a
        // tab this build does not have — or names none — still lands on a usable bar.
        if let visible = extras.visibleTabIDs, !visible.isEmpty { rootTabVisibleIDs = visible }
        if let enabled = extras.launchImageEnabled { launchImageEnabled = enabled }
        if let name = extras.launchImageLightFileName {
            launchImageLightFileName = name.isEmpty ? nil : name
        }
        if let name = extras.launchImageDarkFileName {
            launchImageDarkFileName = name.isEmpty ? nil : name
        }
        if let covers = extras.defaultCoverLightFileNames { defaultCoverLightFileNames = covers }
        if let covers = extras.defaultCoverDarkFileNames { defaultCoverDarkFileNames = covers }
        if let force = extras.forceDefaultCover { useDefaultCoverForAllBooks = force }
        if let font = extras.globalFontPostScript {
            selectedGlobalFontPostScript = font.isEmpty ? nil : font
        }
        if let frosted = extras.frostedGlass { interfaceFrostedGlass = frosted }
        if let transparency = extras.glassTransparency { interfaceGlassTransparency = transparency }
        if let glow = extras.glowIntensity { interfaceGlowIntensity = glow }
        // Unconditional, like `cardBackground`: a theme without a glow colour means its
        // glow follows its own accent, not whatever colour the last theme picked.
        interfaceGlowColor = extras.glowColor
        if let cards = extras.glassCards { interfaceGlassCards = cards }
        if let columns = extras.bookshelfGridColumnCount { bookshelfGridColumnCount = columns }
        if let radius = extras.bookshelfCoverCornerRadius { bookshelfCoverCornerRadius = radius }
        appearanceCardBackground = extras.cardBackground
        if let backgrounds = extras.pageBackgrounds { appearancePageBackgrounds = backgrounds }
        if let colors = extras.readerChromeColors { readerChromeColors = colors }
        if let hidden = extras.readerChromeHiddenIDs { readerChromeHiddenIDs = hidden }
        if let icons = extras.readerChromeIcons {
            // Same reconstruction as `tabIcons`: the theme carries the artwork, the
            // import metadata describes a user action this is not one of.
            readerChromeIcons = icons
                .map {
                    ReaderChromeIconAsset(
                        itemID: $0.key,
                        fileName: $0.value,
                        originalFileName: $0.value,
                        addedAt: Date()
                    )
                }
                .sorted { $0.itemID < $1.itemID }
        }
        // `extras.reading` is worn by `synchronizeReadingSettings`, and only for the
        // settings 排版生效範圍 lets follow the theme.
    }
}
